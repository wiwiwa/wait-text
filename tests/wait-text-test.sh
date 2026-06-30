#!/bin/sh
# Basic functional tests for wait-text.
#
# POSIX sh, no external deps beyond the tool's own requirements
# (grep, sleep, tail, kill, mktemp). Exit-code driven: each case runs
# wait-text with known input and asserts the exit code.
#
# Run from anywhere:
#   sh tests/wait-text-test.sh
# or, after `chmod +x`:
#   ./tests/wait-text-test.sh
#
# Exits 0 if every case passes, 1 otherwise.

# Locate the script under test: tests/.. /wait-text
TEST_DIR=$(dirname "$0")
ROOT=$(cd "$TEST_DIR/.." 2>/dev/null && pwd) || ROOT=''
WT="$ROOT/wait-text"
[ -f "$WT" ] || WT='./wait-text'	# fallback: run from repo root
if [ ! -f "$WT" ]; then
	printf 'wait-text-test: cannot find wait-text\n' >&2
	exit 2
fi

PASS=0
FAIL=0
WORK=$(mktemp -d 2>/dev/null) || {
	printf 'wait-text-test: cannot create temp dir\n' >&2
	exit 2
}
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

# expect_code <description> <expected_code> <actual_code>
expect_code() {
	if [ "$3" = "$2" ]; then
		PASS=$((PASS + 1))
		printf 'ok   - %s (exit %s)\n' "$1" "$3"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL - %s (expected exit %s, got %s)\n' "$1" "$2" "$3" >&2
	fi
}

# Silence the tool's diagnostics; functional tests check exit codes only.

printf '== wait-text functional tests ==\n'

# --- stdin: base mode ------------------------------------------------------
printf 'hello world\n' | sh "$WT" "hello" >/dev/null 2>&1
expect_code "stdin: pattern present -> 0" 0 $?

printf 'hello world\n' | sh "$WT" "nope" >/dev/null 2>&1
expect_code "stdin: pattern absent, source ends -> 1" 1 $?

# empty stdin ends without a match
sh "$WT" "anything" </dev/null >/dev/null 2>&1
expect_code "stdin: empty source -> 1" 1 $?

# --- usage / validation ----------------------------------------------------
sh "$WT" </dev/null >/dev/null 2>&1
expect_code "missing PATTERN -> 2" 2 $?

sh "$WT" --timeout abc "x" </dev/null >/dev/null 2>&1
expect_code "--timeout non-integer -> 2" 2 $?

sh "$WT" --timeout -1 "x" </dev/null >/dev/null 2>&1
expect_code "--timeout negative -> 2" 2 $?

# 0 is valid and means "wait forever"; here the empty source just ends -> exit 1.
sh "$WT" --timeout 0 "x" </dev/null >/dev/null 2>&1
expect_code "--timeout 0 = wait forever, source ends -> 1" 1 $?

sh "$WT" -x "x" </dev/null >/dev/null 2>&1
expect_code "unknown option -x -> 2" 2 $?

# --- timeout ---------------------------------------------------------------
# Live but silent source: producer holds the pipe open, watchdog fires at 1s.
sh "$WT" -c 'sleep 5' -t 1 "never" >/dev/null 2>&1
expect_code "timeout on silent live source -> 1" 1 $?

# --- --file / -f -----------------------------------------------------------
printf 'pre\nMARKER\n' >"$WORK/f.txt"
sh "$WT" -f "$WORK/f.txt" "MARKER" >/dev/null 2>&1
expect_code "-f: instant hit on existing content -> 0" 0 $?

printf 'pre\n' >"$WORK/f2.txt"
sh "$WT" -f "$WORK/f2.txt" -t 1 "MISSING" >/dev/null 2>&1
expect_code "-f: timeout when pattern never appears -> 1" 1 $?

# --- --command / -c --------------------------------------------------------
sh "$WT" -c 'echo READY' "READY" >/dev/null 2>&1
expect_code "-c: match on command output -> 0" 0 $?

sh "$WT" -c 'echo ready' "READY" >/dev/null 2>&1
expect_code "-c: no match (case-sensitive) -> 1" 1 $?

# --- --regex / -e ----------------------------------------------------------
printf 'listening on port 8080\n' | sh "$WT" -e 'port [0-9]+' >/dev/null 2>&1
expect_code "-e: regex match -> 0" 0 $?

printf 'listening on port 8080\n' | sh "$WT" 'port [0-9]+' >/dev/null 2>&1
expect_code "plain text does not match regex-shaped pattern -> 1" 1 $?

# --- repeat mode (-r) ------------------------------------------------------
# Source contains the pattern then ends: match resets timer, EOF -> exit 0.
printf 'beat\n' | sh "$WT" -r -t 1 "beat" >/dev/null 2>&1
expect_code "-r: exits 0 when source ends -> 0" 0 $?

# --- mutual exclusion ------------------------------------------------------
sh "$WT" -f "$WORK/f.txt" -c 'echo y' "pat" >/dev/null 2>&1
expect_code "-f and -c mutually exclusive -> 2" 2 $?

sh "$WT" --file "$WORK/f.txt" --command 'echo y' "pat" >/dev/null 2>&1
expect_code "--file and --command mutually exclusive -> 2" 2 $?

# --- short-flag value handling --------------------------------------------
sh "$WT" -t </dev/null >/dev/null 2>&1
expect_code "-t without value -> 2" 2 $?

sh "$WT" -f </dev/null >/dev/null 2>&1
expect_code "-f without value -> 2" 2 $?

sh "$WT" -c </dev/null >/dev/null 2>&1
expect_code "-c without value -> 2" 2 $?

# --- short/long equivalence ------------------------------------------------
sh "$WT" -t 1 "nope" </dev/null >/dev/null 2>&1
expect_code "-t equivalent to --timeout -> 1" 1 $?

sh "$WT" --timeout 1 "nope" </dev/null >/dev/null 2>&1
expect_code "--timeout baseline -> 1" 1 $?

# --- help / version --------------------------------------------------------
sh "$WT" -h >/dev/null 2>&1
expect_code "-h -> 0" 0 $?

sh "$WT" --help >/dev/null 2>&1
expect_code "--help -> 0" 0 $?

sh "$WT" -V >/dev/null 2>&1
expect_code "-V -> 0" 0 $?

sh "$WT" --version >/dev/null 2>&1
expect_code "--version -> 0" 0 $?

# --- tmux source (--tmux / -m) --------------------------------------------
# These are guarded: basic arg checks run when tmux is installed; the bad-pane
# and end-to-end match cases additionally need a reachable tmux server. The
# suite passes cleanly (skips) where tmux is unavailable.

if command -v tmux >/dev/null 2>&1; then
	# Missing value (parse error - no server needed).
	sh "$WT" --tmux </dev/null >/dev/null 2>&1
	expect_code "--tmux without value -> 2" 2 $?

	sh "$WT" -m </dev/null >/dev/null 2>&1
	expect_code "-m without value -> 2" 2 $?

	# Mutual exclusion (checked in validate before tmux is consulted).
	sh "$WT" --tmux %1 --file a "pat" >/dev/null 2>&1
	expect_code "--tmux + --file mutually exclusive -> 2" 2 $?

	sh "$WT" -m %1 -c 'echo x' "pat" >/dev/null 2>&1
	expect_code "-m + -c mutually exclusive -> 2" 2 $?

	if tmux info >/dev/null 2>&1; then
		# Slash in pane id (rejected in validate).
		sh "$WT" --tmux ../x "pat" </dev/null >/dev/null 2>&1
		expect_code "--tmux pane id with slash -> 2" 2 $?

		# Non-existent pane.
		sh "$WT" --tmux %999999 "pat" </dev/null >/dev/null 2>&1
		expect_code "--tmux non-existent pane -> 2" 2 $?

		# End-to-end match against a throwaway detached session.
		SESS="wt_test_$$"
		if tmux new-session -d -s "$SESS" 2>/dev/null; then
			TPANE=$(tmux list-panes -s -t "$SESS" -F '#{pane_id}' | head -1)
			sh "$WT" --tmux "$TPANE" -t 8 "WTTESTMARK" >/dev/null 2>&1 &
			wtpid=$!
			sleep 1
			tmux send-keys -t "$TPANE" 'echo WTTESTMARK' Enter
			wait "$wtpid" 2>/dev/null
			expect_code "--tmux end-to-end match -> 0" 0 $?
			tmux kill-session -t "$SESS" 2>/dev/null
		fi
	fi
fi

# No-tmux path: hide tmux from PATH (script runs via absolute /bin/sh, so it
# doesn't need PATH; inside, `command -v tmux` fails). Skip if /bin/sh or the
# empty staging dir can't be created.
if [ -x /bin/sh ]; then
	notmux_dir=$(mktemp -d "${TMPDIR:-/tmp}/wt-notmux.XXXXXX" 2>/dev/null) || notmux_dir=''
	if [ -n "$notmux_dir" ]; then
		env PATH="$notmux_dir" /bin/sh "$WT" --tmux %1 "x" </dev/null >/dev/null 2>&1
		expect_code "--tmux when tmux absent from PATH -> 2" 2 $?
		rmdir "$notmux_dir" 2>/dev/null
	fi
fi

# --- summary ---------------------------------------------------------------
printf -- '--------------------\n'
printf 'pass=%d fail=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
	printf 'ALL TESTS PASSED\n'
	exit 0
else
	printf '%d TEST(S) FAILED\n' "$FAIL" >&2
	exit 1
fi
