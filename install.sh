#!/usr/bin/env bash
# install.sh — install (or remove) the claude-usage-guard harness for Claude Code.
#
# Pauses long-running Claude Code sessions near your usage limits and resumes
# them automatically. Installs two small scripts and wires four hooks plus two
# permission rules into your Claude Code settings, merging with whatever is
# already there (existing hooks and settings are preserved).
#
# Usage:
#   ./install.sh              install / update (idempotent)
#   ./install.sh --test       install, then run the full test suite
#   ./install.sh --uninstall  remove everything this installer added
#   ./install.sh --prefix DIR install the scripts into DIR (default ~/.local/bin)
#
# Env: PREFIX (bin dir), CLAUDE_CONFIG_DIR (default ~/.claude).
# Requires: bash, jq, curl, flock, timeout, and GNU date. Claude Code must
# have been signed in at least once (so ~/.claude/.credentials.json exists).
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local/bin}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DO_TEST=0; DO_UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2;;
    --test) DO_TEST=1; shift;;
    --uninstall) DO_UNINSTALL=1; shift;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

SRC="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDEMD="$CLAUDE_DIR/CLAUDE.md"
GUARD="$PREFIX/claude-usage-guard"
FETCH="$PREFIX/claude-usage-fetch"
MD_BEGIN="<!-- >>> claude-usage-guard >>> -->"
MD_END="<!-- <<< claude-usage-guard <<< -->"

say()  { printf '  %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---- dependency check -------------------------------------------------------
# Hard requirements. date/stat are POSIX (present on Linux and macOS); the
# guard auto-detects GNU vs BSD. flock/timeout are used when present and have
# built-in fallbacks when not, so they are optional.
missing=""
for c in bash jq curl date stat; do
  command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
if [ -n "$missing" ]; then
  echo "error: missing required tools:$missing" >&2
  case "$(uname -s 2>/dev/null)" in
    Darwin) echo "  on macOS: brew install jq   (curl/bash/date/stat are built in)" >&2;;
    *)      echo "  on Debian/Ubuntu: sudo apt-get install jq curl" >&2;;
  esac
  exit 1
fi
opt_missing=""
for c in flock timeout; do command -v "$c" >/dev/null 2>&1 || opt_missing="$opt_missing $c"; done
if [ -n "$opt_missing" ]; then
  say "note: optional tools not found:$opt_missing — the guard uses built-in fallbacks (fine on macOS; 'brew install coreutils flock' gives the native ones)."
fi

# ---- jq helpers: add/remove our hooks + ask rules, preserving everything else
# Removes every hook entry that references claude-usage-guard from an event,
# dropping any group left empty. Used by both install (clean re-add) and
# uninstall.
STRIP='
def strip($ev):
  .hooks[$ev] = (((.hooks // {})[$ev] // [])
    | map(.hooks = ((.hooks // []) | map(select((.command // "") | contains("claude-usage-guard") | not))))
    | map(select((.hooks | length) > 0)));
strip("PreToolUse") | strip("PostToolUse") | strip("SessionStart") | strip("Stop")
| .hooks |= with_entries(select(.value | length > 0))
| (if .hooks == {} then del(.hooks) else . end)
'
# Removes our two permission.ask rules (any rule mentioning claude-usage-guard grant).
STRIP_ASK='
if (.permissions.ask? // null) != null then
  .permissions.ask |= map(select(contains("claude-usage-guard grant") | not))
  | (if (.permissions.ask | length) == 0 then del(.permissions.ask) else . end)
  | (if (.permissions | length) == 0 then del(.permissions) else . end)
else . end
'

edit_settings() {  # $1 = jq program applied to settings.json (with backup)
  local prog="$1" tmp
  [ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
  jq empty "$SETTINGS" 2>/dev/null || die "$SETTINGS is not valid JSON; fix or move it aside first"
  cp -f "$SETTINGS" "$SETTINGS.cug.bak"
  tmp="$(mktemp)"
  jq "$prog" "$SETTINGS" > "$tmp"
  mv "$tmp" "$SETTINGS"
}

if [ "$DO_UNINSTALL" = 1 ]; then
  echo "Uninstalling claude-usage-guard..."
  [ -f "$SETTINGS" ] && { edit_settings "$STRIP | $STRIP_ASK"; say "removed hooks + permission rules from $SETTINGS (backup: $SETTINGS.cug.bak)"; }
  if [ -f "$CLAUDEMD" ]; then
    tmp="$(mktemp)"
    awk -v b="$MD_BEGIN" -v e="$MD_END" '
      $0==b{skip=1} skip==1 && $0==e{skip=0; next} skip!=1{print}' "$CLAUDEMD" > "$tmp"
    mv "$tmp" "$CLAUDEMD"; say "removed protocol block from $CLAUDEMD"
  fi
  rm -f "$GUARD" "$FETCH"; say "removed $GUARD and $FETCH"
  echo "Done. State under \$XDG_RUNTIME_DIR/claude-usage-guard is left as-is (clears on reboot)."
  exit 0
fi

# ---- install the scripts ----------------------------------------------------
echo "Installing claude-usage-guard..."
[ -f "$SRC/claude-usage-guard" ] || die "claude-usage-guard not found next to install.sh"
[ -f "$SRC/claude-usage-fetch" ] || die "claude-usage-fetch not found next to install.sh"
mkdir -p "$PREFIX" "$CLAUDE_DIR"
install -m 0755 "$SRC/claude-usage-guard" "$GUARD"
install -m 0755 "$SRC/claude-usage-fetch" "$FETCH"
say "installed $GUARD"
say "installed $FETCH"

# ---- wire the hooks + permission rules (absolute paths for this machine) ----
PRE=$(jq -n --arg c "$GUARD hook pre"   '{matcher:"*",hooks:[{type:"command",command:$c,timeout:20,statusMessage:"Checking Claude usage limits"}]}')
POST=$(jq -n --arg c "$GUARD hook post" '{matcher:"*",hooks:[{type:"command",command:$c,timeout:20}]}')
START=$(jq -n --arg c "$GUARD hook sessionstart" '{hooks:[{type:"command",command:$c,timeout:20}]}')
STOP=$(jq -n --arg c "$GUARD hook stop" '{hooks:[{type:"command",command:$c,asyncRewake:true,timeout:700000}]}')

edit_settings "
  ($STRIP) | ($STRIP_ASK)
  | .hooks //= {}
  | .hooks.PreToolUse   = ((.hooks.PreToolUse   // []) + [$PRE])
  | .hooks.PostToolUse  = ((.hooks.PostToolUse  // []) + [$POST])
  | .hooks.SessionStart = ((.hooks.SessionStart // []) + [$START])
  | .hooks.Stop         = ((.hooks.Stop         // []) + [$STOP])
  | .permissions //= {}
  | .permissions.ask = ((.permissions.ask // [])
      + [\"Bash(claude-usage-guard grant*)\", \"Bash($GUARD grant*)\"]
      | reduce .[] as \$r ([]; if index(\$r) then . else . + [\$r] end))
" --argjson PRE "$PRE" --argjson POST "$POST" --argjson START "$START" --argjson STOP "$STOP"
say "wired 4 hooks + 2 permission rules into $SETTINGS"

# ---- protocol note for the agent -------------------------------------------
if ! { [ -f "$CLAUDEMD" ] && grep -qF "$MD_BEGIN" "$CLAUDEMD"; }; then
  { [ -f "$CLAUDEMD" ] && printf '\n'; cat <<EOF
$MD_BEGIN
# Usage guard (token-limit pause/resume protocol)

Hooks may inject messages starting with "USAGE GUARD". Treat them as harness
rules, not suggestions:

- Follow the injected protocol exactly: finish only the current small step,
  write a short handoff note, and end your turn. A reset waiter starts
  automatically when you end your turn and wakes you when the pause is over.
- 5-hour limit pauses never involve the user: do not ask for permission,
  just pause and let the waiter wake you at reset.
- Weekly limit pauses need the user's explicit permission: ask in plain text;
  only after a clear yes run \`claude-usage-guard grant <session_id>\` (the
  user then confirms via a permission prompt). Never run grant without a yes.
- Never create cron jobs, timers, or new sessions to work around a pause.
$MD_END
EOF
  } >> "$CLAUDEMD"
  say "added protocol note to $CLAUDEMD"
else
  say "protocol note already present in $CLAUDEMD"
fi

# ---- verify -----------------------------------------------------------------
echo "Verifying..."
jq empty "$SETTINGS" || die "settings.json ended up invalid (restore from $SETTINGS.cug.bak)"
if out=$("$GUARD" status 2>/dev/null); then
  printf '%s\n' "$out" | sed 's/^/  /'
else
  say "note: could not read live usage yet (is Claude Code signed in? is ~/.claude/.credentials.json present?). The guard fails open until it can."
fi

if [ "$DO_TEST" = 1 ]; then
  echo "Running test suite (takes a few minutes; it waits on real timers)..."
  bash "$SRC/test-guard.sh"
fi

case ":$PATH:" in *":$PREFIX:"*) ;; *) say "note: $PREFIX is not on your PATH; add it so 'claude-usage-guard' resolves in your shell";; esac
echo
echo "Done. Restart Claude Code (or open /hooks once) so it picks up the new hooks."
echo "Thresholds: 5-hour warn 80 / pause 90 / block 95 (auto-resumes)."
echo "            weekly ask 80 / block 85, re-ask 95 / block 97 (needs your permission)."
