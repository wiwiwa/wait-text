#!/bin/sh
# wait-text - block until expected text appears in a stream, file, or command output.
#
# POSIX sh (#!/bin/sh), bash-compatible, no bashisms. See README.md.

VERSION="0.1.0"

# Exit codes
EXIT_FOUND=0    # pattern found (base) / normal completion (-r)
EXIT_NOTFOUND=1 # not found, timeout, or source ended without a match (base)
EXIT_USAGE=2    # usage or runtime error

# Options (defaults)
TIMEOUT=30
REGEX=0
REPEAT=0
FILE=''
COMMAND=''
PATTERN=''

# Runtime state (globals)
FIFO=''
MARKER=''
PRODUCER=''
WATCHDOG=''

# shellcheck disable=SC2317
# cleanup: reached via the EXIT/INT/TERM/HUP traps below.
cleanup() {
	disarm_watchdog
	[ -n "$PRODUCER" ] && kill "$PRODUCER" 2>/dev/null
	[ -n "$FIFO" ] && rm -f "$FIFO"
	[ -n "$MARKER" ] && rm -f "$MARKER"
}

die_usage() {
	printf 'wait-text: %s\n' "$1" >&2
	printf "Try 'wait-text --help' for usage.\n" >&2
	exit "$EXIT_USAGE"
}

print_usage() {
	cat <<EOF
Usage: wait-text [-r] [--file PATH | --command CMD] [--timeout N] [--regex] PATTERN
       wait-text [-r] [-f PATH | -c CMD] [-t N] [-e] PATTERN
       wait-text --help | --version

Block until PATTERN appears in the input, then exit.

Options:
   -h, --help             Show this help and exit.
   -V, --version          Show version and exit.
   -r                     Repeat mode: keep watching; reset the timer on each
                          match; exit 0 when the pattern stops appearing for
                          the timeout.
   -t, --timeout N        Maximum seconds to wait (default 30). Must be > 0.
   -e, --regex            Treat PATTERN as a regular expression.
   -f, --file PATH        Watch PATH instead of standard input.
   -c, --command CMD      Run CMD and watch its standard output.

Exit codes (default): 0 = found; 1 = not found/timeout; 2 = usage/runtime error.
Exit codes (-r):      0 = quiet/source ended; 2 = usage/runtime error.
EOF
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--help | -h)
			print_usage
			exit "$EXIT_FOUND"
			;;
		--version | -V)
			printf '%s\n' "$VERSION"
			exit "$EXIT_FOUND"
			;;
		-r)
			REPEAT=1
			shift
			;;
		--regex | -e)
			REGEX=1
			shift
			;;
		--timeout | -t)
			[ $# -ge 2 ] || die_usage "--timeout requires a value"
			TIMEOUT="$2"
			shift 2
			;;
		--timeout=*)
			TIMEOUT="${1#--timeout=}"
			shift
			;;
		--file | -f)
			[ $# -ge 2 ] || die_usage "--file requires a value"
			FILE="$2"
			shift 2
			;;
		--file=*)
			FILE="${1#--file=}"
			shift
			;;
		--command | -c)
			[ $# -ge 2 ] || die_usage "--command requires a value"
			COMMAND="$2"
			shift 2
			;;
		--command=*)
			COMMAND="${1#--command=}"
			shift
			;;
		--)
			shift
			break
			;;
		-*) die_usage "unknown option: $1" ;;
		*)
			PATTERN="$1"
			shift
			;;
		esac
	done
	# remaining positionals (after --): at most one, the PATTERN
	while [ $# -gt 0 ]; do
		[ -z "$PATTERN" ] || die_usage "only one PATTERN is allowed"
		PATTERN="$1"
		shift
	done
}

validate() {
	[ -n "$PATTERN" ] || die_usage "missing PATTERN"
	case "$TIMEOUT" in
	'' | *[!0-9]*) die_usage "invalid --timeout: $TIMEOUT (must be a positive integer)" ;;
	esac
	[ "$TIMEOUT" -gt 0 ] || die_usage "--timeout must be greater than 0"
	if [ -n "$FILE" ] && [ -n "$COMMAND" ]; then
		die_usage "--file and --command are mutually exclusive"
	fi
}

# match_in <text>: return 0 if PATTERN found in <text>, else 1.
match_in() {
	if [ "$REGEX" -eq 1 ]; then
		printf '%s' "$1" | grep -qE -- "$PATTERN"
	else
		printf '%s' "$1" | grep -qF -- "$PATTERN"
	fi
}

start_producer() {
	# Writes the watched stream into $FIFO. Sets PRODUCER pid.
	if [ -n "$FILE" ]; then
		tail -n 0 -f -- "$FILE" 2>/dev/null >"$FIFO" &
	elif [ -n "$COMMAND" ]; then
		sh -c "$COMMAND" >"$FIFO" 2>/dev/null &
	else
		# NOTE: bash redirects background jobs' stdin from /dev/null when job
		# control is off (non-interactive). fd 3 holds the real stdin (saved in
		# main), so feed it explicitly to the producer.
		cat <&3 >"$FIFO" &
	fi
	PRODUCER=$!
}

start_watchdog() {
	# After $TIMEOUT seconds: drop a marker and kill the producer so the reader
	# sees EOF. Data-driven timeout (works under bash-as-sh without trapping the
	# main shell). The TERM trap kills the sleep child on disarm so it does not
	# orphan, and exits before the post-sleep actions run.
	rm -f "$MARKER"
	(
		trap 'kill "$sleeppid" 2>/dev/null; exit 0' TERM
		sleep "$TIMEOUT" 2>/dev/null &
		sleeppid=$!
		wait "$sleeppid" 2>/dev/null
		# Sleep completed naturally (timeout): fire the timeout.
		: >"$MARKER"
		kill "$PRODUCER" 2>/dev/null
	) &
	WATCHDOG=$!
}

disarm_watchdog() {
	[ -n "$WATCHDOG" ] || return 0
	kill "$WATCHDOG" 2>/dev/null
	wait "$WATCHDOG" 2>/dev/null
	WATCHDOG=''
}

# read_chunk: read up to 4096 bytes from fd 0 into $chunk; return 0 if bytes,
# 1 on EOF. Trailing newlines are preserved via the printf-X sentinel.
read_chunk() {
	chunk=$(
		dd bs=4096 count=1 2>/dev/null
		printf X
	)
	chunk=${chunk%X}
	[ -n "$chunk" ]
}

# trim_buffer: keep only the last $keep bytes of $buffer (sliding window so a
# match straddling chunk boundaries is still found). Operates directly on the
# global to avoid eval (which is fragile when $buffer contains newlines).
trim_buffer() {
	if [ "$keep" -gt 0 ]; then
		buffer=$(printf '%s' "$buffer" | tail -c "$keep")
	else
		buffer=''
	fi
}

watch() {
	plen=${#PATTERN}
	keep=$((plen - 1))
	[ "$keep" -lt 0 ] && keep=0
	buffer=''
	while read_chunk; do
		buffer=$buffer$chunk
		if match_in "$buffer"; then
			if [ "$REPEAT" -eq 1 ]; then
				# consume matched bytes (keep tail), re-arm watchdog, continue
				trim_buffer
				disarm_watchdog
				start_watchdog
				continue
			fi
			exit "$EXIT_FOUND"
		fi
		trim_buffer
	done
	# EOF: distinguish timeout (marker set) from natural source end.
	if [ -e "$MARKER" ]; then
		if [ "$REPEAT" -eq 1 ]; then
			printf 'wait-text: idle-timeout after %ss without a match\n' "$TIMEOUT" >&2
			exit "$EXIT_FOUND"
		else
			printf 'wait-text: timeout after %ss without a match\n' "$TIMEOUT" >&2
			exit "$EXIT_NOTFOUND"
		fi
	else
		if [ "$REPEAT" -eq 1 ]; then
			printf 'wait-text: source ended\n' >&2
			exit "$EXIT_FOUND"
		else
			printf 'wait-text: source ended without a match\n' >&2
			exit "$EXIT_NOTFOUND"
		fi
	fi
}

main() {
	parse_args "$@"
	validate

	# Temp fifo + timeout marker
	tmpdir=${TMPDIR:-/tmp}
	FIFO=$(mktemp -u "$tmpdir/wait-text.fifo.XXXXXX") || {
		printf 'wait-text: cannot stage fifo\n' >&2
		exit "$EXIT_USAGE"
	}
	MARKER=$(mktemp "$tmpdir/wait-text.marker.XXXXXX") || {
		printf 'wait-text: cannot stage marker\n' >&2
		exit "$EXIT_USAGE"
	}
	rm -f "$MARKER"
	if ! mkfifo "$FIFO" 2>/dev/null; then
		printf 'wait-text: cannot create fifo\n' >&2
		rm -f "$MARKER"
		exit "$EXIT_USAGE"
	fi
	trap 'cleanup' EXIT INT TERM HUP

	# File source: must be readable; check pre-existing content for an instant hit.
	if [ -n "$FILE" ]; then
		[ -r "$FILE" ] || {
			printf 'wait-text: cannot read file: %s\n' "$FILE" >&2
			exit "$EXIT_USAGE"
		}
		if match_in_file; then
			exit "$EXIT_FOUND"
		fi
	fi

	# Save the real stdin on fd 3 so the background producer (cat) can read it
	# even though bash redirects bg-job stdin from /dev/null (see start_producer).
	exec 3<&0

	start_producer
	start_watchdog
	watch <"$FIFO"
}

match_in_file() {
	if [ "$REGEX" -eq 1 ]; then
		grep -qE -- "$PATTERN" "$FILE"
	else
		grep -qF -- "$PATTERN" "$FILE"
	fi
}

main "$@"
