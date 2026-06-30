# wait-text

Block until expected text appears — in a stream, a file, or a command's output.

`wait-text` watches a source and exits as soon as the text you're waiting for
shows up. It's a small, dependency-free shell tool that slots into pipelines and
scripts: **return code tells you what happened**, so you can branch on it without
parsing output.

```sh
# Wait for a build to finish, then run the next step:
make 2>&1 | wait-text "BUILD SUCCESSFUL" && deploy.sh

# Wait for a log file to show a completion marker:
wait-text --file app.log "Server started"

# Wait for a subprocess to print "READY":
wait-text --command "start-server.sh" "READY"
```

---

## Why

Scripts often need to **wait until something finishes** — a server boots, a log
prints "done", a file gets a marker line. Polling with `sleep` loops is noisy and
imprecise. `wait-text` does one thing: block until the text appears (or give up
after a timeout), then report the result via its exit code.

It pairs naturally with `make`, `docker logs`, CI steps, and shell pipelines.

---

## Install

`wait-text` is a single self-contained script. There is no build step and no
runtime to install.

```sh
# Install straight from GitHub to somewhere on your PATH, e.g.:
curl -fsSL https://raw.githubusercontent.com/wiwiwa/wait-text/master/wait-text \
  -o ~/.local/bin/wait-text
chmod +x ~/.local/bin/wait-text
```

Or, from a checkout / release archive:

```sh
cp wait-text ~/.local/bin/wait-text && chmod +x ~/.local/bin/wait-text
```

Check it runs:

```sh
wait-text --version
```

**Requirements:** a POSIX `sh` and standard utilities (`grep`, `sleep`, `tail`,
`kill`). Works natively on **Linux** and **macOS**. On **Windows**, run it under
WSL, Git Bash, or MSYS2.

---

## Usage

```text
wait-text [-r] [--file PATH | --command CMD | --tmux PANE] [--timeout SECONDS] [--regex] PATTERN
wait-text [-r] [-f PATH | -c CMD | -m PANE] [-t SECONDS] [-e] PATTERN
wait-text --help
wait-text --version
```

`PATTERN` is the text to wait for. By default `wait-text` reads **standard input**.

### Options

Most options have a short alias shown in parentheses.

| Option | Description |
|--------|-------------|
| `PATTERN` | The text to watch for (required). Plain text by default; a regex with `--regex` (`-e`). |
| `--file PATH` (`-f`) | Watch `PATH` instead of standard input. Checks existing content, then follows new content. |
| `--command CMD` (`-c`) | Run `CMD` and watch its standard output instead of standard input. |
| `--tmux PANE` (`-m`) | Watch the tmux pane `PANE` (e.g. `%5` or `session:0.1`). Captures **new** output via `tmux pipe-pane`; the pane is restored when the tool exits. |
| `--timeout N` (`-t`) | Give up after `N` seconds (default: 30). Must be greater than 0. |
| `--regex` (`-e`) | Treat `PATTERN` as a regular expression. |
| `-r` | **Repeat mode** — see below. |
| `--help` (`-h`) | Show usage and exit. |
| `--version` (`-V`) | Show version and exit. |

`--file`, `--command`, and `--tmux` are mutually exclusive; if none is given,
standard input is watched.

---

## Exit codes

`wait-text` communicates through its exit code. It prints diagnostics to standard
error and keeps standard output empty, so it composes cleanly in pipelines.

### Default mode

| Code | Meaning |
|------|---------|
| `0` | Text found. |
| `1` | Text not found within the timeout, or the source ended without a match. |
| `2` | Invalid usage (missing pattern, bad timeout) or a runtime error (e.g., unreadable file). |

```sh
if wait-text --timeout 10 "ready" < stream; then
  echo "ready, proceeding"
else
  echo "gave up"
fi
```

### Repeat mode (`-r`)

`-r` changes the behavior: instead of exiting on the **first** match, `wait-text`
keeps watching. **Each match resets the timeout**, and the tool exits **0** when
the text stops appearing for a full timeout window — the stream has "gone quiet".

Use it to wait until activity settles: drain a busy log, wait for a heartbeat to
stop, or proceed once a service goes idle.

| Code | Meaning |
|--------|---------|
| `0` | The text stopped appearing for the full timeout (quiet), or the source ended. |
| `2` | Invalid usage or a runtime error. |

```sh
# Proceed once the server stops logging "handling request":
tail -f app.log | wait-text -r --timeout 5 "handling request" && take-snapshot.sh
```

---

## Examples

**Wait for the first match on stdin, then continue:**
```sh
./build.sh 2>&1 | wait-text "BUILD SUCCESSFUL" && echo "build OK"
```

**Timeout after 10 seconds:**
```sh
wait-text --timeout 10 "ready" < slow.log || echo "timed out"
# same thing with the short alias:
wait-text -t 10 "ready" < slow.log || echo "timed out"
```

**Watch a file for a marker (even if it appears later):**
```sh
wait-text --file deploy.log "Deployment complete"
```

**Run a command and wait for its output:**
```sh
wait-text --command "./serve.sh" "Listening on"
```

**Watch a tmux pane** (e.g. a server running in another window):
```sh
# %5 is tmux's unique pane id; `tmux list-panes -a` shows them.
wait-text --tmux %5 "Listening on"
# or equivalently:
wait-text -m %5 "Listening on"
```

**Match a regex:**
```sh
wait-text --regex 'listening on port [0-9]+' < server.log
```

**Match text that contains escape sequences** (e.g., ANSI color): `wait-text`
matches raw bytes — nothing is stripped, so include the escape bytes in your
pattern, or use a regex.

**Stream with no newlines** (progress bars, spinners): `wait-text` detects the
pattern anywhere in the live byte stream — a trailing newline is not required.

---

## Behavior notes

- **No whole-input buffering.** Input is read incrementally, so it works on
  streams of any size with constant memory.
- **Raw matching.** Control/escape sequences are matched as-is; they are never
  stripped or normalized.
- **Never hangs.** A finite timeout always applies, so the tool cannot block
  forever silently.
- **Exit-code driven.** Standard output stays empty during normal operation,
  making the tool safe to chain.

### tmux source (`--tmux` / `-m`)

- **New output only.** Capture starts when `wait-text` attaches; output already
  visible in the pane (scrollback/current screen) is not replayed. A pattern
  already on screen is matched only if it appears again in subsequent output.
- **Pane is restored on exit.** `wait-text` stops its own `tmux pipe-pane`
  redirection when it finishes (match, timeout, interrupt). It does not restore
  a redirection that was active before it started.
- **SIGKILL leaves a pane piping.** An uncatchable `kill -9` can't run the
  cleanup trap. Clear a leftover pipe manually:
  ```sh
  tmux pipe-pane -t %5        # no command = disable pipe-pane
  rm -f /tmp/tmux.pane.%5.log
  ```

---

## License

See the project repository for license information.
