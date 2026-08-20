# claude-usage-guard

Pauses long-running Claude Code sessions when token usage limits get close,
and resumes them when the limit resets. Built 2026-08-19; hardened after
adversarial review + black-box testing the same day.

## Install

Works on Linux and macOS. Requires `bash`, `jq`, and `curl` (on macOS:
`brew install jq`), and a Claude Code that has been signed in at least once
(for `~/.claude/.credentials.json`). `flock` and `timeout` are used when
present and have built-in fallbacks when not, so nothing extra is needed on a
stock Mac. Then:

```bash
git clone <this-repo> claude-usage-guard
cd claude-usage-guard
./install.sh            # installs scripts + wires hooks (merges, non-destructive)
```

Restart Claude Code (or open `/hooks` once) so it loads the new hooks. That
is all — the guard reads your usage itself.

- `./install.sh --test` runs the full test suite after installing (a few
  minutes; it waits on real timers).
- `./install.sh --uninstall` removes everything it added and restores your
  settings (a `.cug.bak` backup is written on every change).
- `./install.sh --prefix DIR` installs the scripts somewhere other than
  `~/.local/bin`. `CLAUDE_CONFIG_DIR` overrides `~/.claude`.

The installer edits `~/.claude/settings.json` and `~/.claude/CLAUDE.md` by
merging: existing hooks, permission rules, and notes are preserved.

## Behavior

- **5-hour limit** (never involves the user): warn the agent at 80%, tell it
  to pause at a natural stopping point at 90%, hard-block all tools at 95%.
  Auto-resumes at reset.
- **Weekly limit** (requires the user's explicit permission): at 80% the
  agent must ask the user. Only after a clear yes does it run
  `claude-usage-guard grant <sid>` — and that command itself triggers a
  permission prompt (PreToolUse returns `permissionDecision: "ask"` plus
  `permissions.ask` rules), so the user's approval click is the real gate.
  Without a grant, tools hard-block at 85%. A level-2 grant
  (`grant --level 2`) is needed from 95% (hard block 97%).
- **Auto-resume**: a `Stop` hook with `asyncRewake` runs whenever the agent
  ends its turn. If a pause is active, it becomes the waiter (one per
  session via a lock dir): it polls each minute and exits with code 2 when
  the limit resets or a sufficient grant appears — which wakes the agent.
- **Closed sessions stay closed.** No cron, no external timers. The waiter
  lives inside the session's hook process and dies with the session.

## Components

Repo files (the unit you share — self-contained, no machine-specific deps):

- `claude-usage-guard` — the harness. Installed to `~/.local/bin`.
  Subcommands: `state`, `status`, `grant [--level 2] <sid>`, `revoke <sid>`,
  `wait <five|week> [sid]` (manual fallback), `hook pre|post|sessionstart|stop`.
- `claude-usage-fetch` — the data source. Reads the OAuth token from
  `~/.claude/.credentials.json` and prints the usage API's JSON. Installed to
  `~/.local/bin`. Override the guard's fetcher with `$CUG_FETCH` if you have
  your own (e.g. an existing ccusage script).
- `install.sh` — installer / uninstaller (see above).
- `test-guard.sh` — the test suite.

Installed hooks in `~/.claude/settings.json`: PreToolUse (hard blocks +
grant→ask), PostToolUse (one-shot warn/pause/ask messages), SessionStart
(status if already above a threshold), Stop (auto-waiter, asyncRewake,
700000 s timeout to cover a multi-day weekly wait). Usage is cached 5 min in
`$XDG_RUNTIME_DIR/claude-usage-guard/usage.json` (flock -w 8, fetch under
`timeout 10` so a hung API can never stall tool calls past the 20 s hook
timeout).

## Hardening (from the review/test round)

- Guard-command allowlist is deny-by-default: the command must be exactly
  `claude-usage-guard <sub> [args]` (plain or absolute path). Any env prefix
  (`CUG_FETCH=`, `LD_PRELOAD=`, `PATH=`, …), shell metacharacter, newline, or
  CR rejects — closes multiline / `$()` / prefix-binary / redirection and the
  env-var code-execution vectors. The hook messages only ever tell the agent
  this plain form.
- `session_id` sanitized to `[A-Za-z0-9._-]`, max 64 chars (no path
  traversal out of the state dir).
- Percentages validated per limit and floored; a fractional or missing value
  fails open only for its own limit, never both.
- One-shot flags are atomic `mkdir` (no duplicate injection from parallel
  hook calls); session-start marks its message as delivered so the first
  post-hook does not repeat it.
- `grant` refuses to record when the API gave no weekly reset timestamp
  (grants are tied to that timestamp and expire when the window rolls over).
- Waiter lock is a real flock (kernel-released even on SIGKILL, and the
  sleep children close the lock fd) — a killed waiter can never permanently
  disable auto-resume. The waiter wakes as soon as the current grant
  satisfies what the pre-hook requires at the current percentage.
- The "assume reset" grace fallback (reset time 30+ min past but usage data
  never confirmed) fires at most once per reset target and never before one
  fresh fetch attempt, so stale cache data cannot cause a wake/stop loop.

## Portability (Linux + macOS)

The guard detects GNU vs BSD tooling at startup and adapts:

- **date**: GNU `date -d` on Linux; on macOS it normalizes the ISO timestamp
  and uses BSD `date -j -f`.
- **stat**: `stat -c %Y` (GNU) or `stat -f %m` (BSD) for the cache mtime.
- **flock**: used when present; on macOS the cache lock is skipped (the atomic
  `tmp+mv` write keeps it safe) and the per-session waiter lock falls back to
  an atomic `mkdir` + PID file that is reclaimed if the holder is dead.
- **timeout**: uses `timeout`/`gtimeout` when present, otherwise a built-in
  background-`sleep`+`kill` watchdog caps the fetch.

Test overrides `CUG_NO_FLOCK` and `CUG_NO_TIMEOUT` force the fallback paths so
they can be exercised on Linux too.

## State

`$XDG_RUNTIME_DIR/claude-usage-guard/` (per login, cleared on reboot):
`usage.json` cache; `sessions/<sid>/` with flag dirs, `week_window`,
`grant_week`, `waiter.lock`.

## Manual commands

```bash
claude-usage-guard status        # percentages, thresholds, active grants
claude-usage-guard grant <sid>   # weekly permission (prompts the user)
claude-usage-guard revoke <sid>
```

## Failure behavior

Fail open: unreachable API → hooks silent, nothing blocked. The waiter has a
30-min grace after the scheduled reset and 8 h / 8 d safety caps.
Test env overrides: `CUG_USAGE_FAKE`, `CUG_RUN_DIR`, `CUG_FETCH`, `CUG_TTL`.

## Tests

`test-guard.sh` — 77 cases: thresholds and exact boundaries, all discovered
allowlist bypasses, fractional values, sanitization/traversal, concurrency
(exactly-one injection), grant lifecycle and window rollover, Stop-hook
waiter (wake exit 2 on reset AND on mid-wait grant, lock dedup, SIGKILL
reclaim, no instant wake on stale data), the real fetch path via a CUG_FETCH
stub (normalization/flooring, cache TTL, stale-if-error), the macOS fallbacks
(BSD timestamp normalization, no-flock mkdir lock reclaim, no-timeout fetch
watchdog), and CLI error handling. Uses fake data + temp state dir only.
Run: `bash test-guard.sh`.
