#!/usr/bin/env bash
# Test matrix for claude-usage-guard. Uses fake usage data + isolated state dir.
set -u
G=/home/ashwani/.local/bin/claude-usage-guard
T=$(mktemp -d)
export CUG_RUN_DIR="$T/run"
FAKE="$T/fake.json"
export CUG_USAGE_FAKE="$FAKE"
SID=test-session-1
deny='.hookSpecificOutput.permissionDecision=="deny"'
stdin_cmd() { jq -nc --arg c "$1" '{session_id:"'"$SID"'",tool_name:"Bash",tool_input:{command:$c}}'; }
STDIN_BASH=$(stdin_cmd 'ls -la')
pass=0; fail=0
ck() { # name expectation('empty'/'nonempty'/jq expr) actual
  local name="$1" expect="$2" out="$3" ok
  case "$expect" in
    empty)    [ -z "$out" ] && ok=1 || ok=0;;
    nonempty) [ -n "$out" ] && ok=1 || ok=0;;
    *)        printf '%s' "$out" | jq -e "$expect" >/dev/null 2>&1 && ok=1 || ok=0;;
  esac
  if [ "$ok" = 1 ]; then pass=$((pass+1)); echo "PASS: $name"
  else fail=$((fail+1)); echo "FAIL: $name"; echo "  got: $out"; fi
}
setpct() { # five week [week_resets]
  printf '{"five_pct":%s,"five_resets":"2026-08-20T00:20:00+00:00","week_pct":%s,"week_resets":"%s"}\n' \
    "$1" "$2" "${3:-2026-08-25T15:00:00+00:00}" > "$FAKE"
}
fresh() { rm -rf "$CUG_RUN_DIR"; }

# --- low usage: hooks silent
fresh; setpct 10 10
ck "pre low silent"  empty "$(printf '%s' "$STDIN_BASH" | "$G" hook pre)"
ck "post low silent" empty "$(printf '%s' "$STDIN_BASH" | "$G" hook post)"
ck "sessionstart low silent" empty "$(printf '%s' "$STDIN_BASH" | "$G" hook sessionstart)"
ck "stop low silent exit0" empty "$(printf '%s' "$STDIN_BASH" | timeout 10 "$G" hook stop 2>&1)"

# --- five 82: warn once
fresh; setpct 82 10
o1=$(printf '%s' "$STDIN_BASH" | "$G" hook post)
o2=$(printf '%s' "$STDIN_BASH" | "$G" hook post)
ck "post five82 warns" '.hookSpecificOutput.additionalContext | test("heads-up")' "$o1"
ck "post five82 once" empty "$o2"
ck "pre five82 allows" empty "$(printf '%s' "$STDIN_BASH" | "$G" hook pre)"

# --- five 91: pause once, no permission-asking language
fresh; setpct 91 10
o1=$(printf '%s' "$STDIN_BASH" | "$G" hook post)
o2=$(printf '%s' "$STDIN_BASH" | "$G" hook post)
ck "post five91 pause" '.hookSpecificOutput.additionalContext | test("5-HOUR PAUSE") and test("Do NOT ask the user for permission")' "$o1"
ck "post five91 once" empty "$o2"
ck "pre five91 allows" empty "$(printf '%s' "$STDIN_BASH" | "$G" hook pre)"

# --- five 96: pre denies; guard cmds allowed; grant prompts
fresh; setpct 96 10
ck "pre five96 denies" '.hookSpecificOutput.permissionDecision=="deny"' "$(printf '%s' "$STDIN_BASH" | "$G" hook pre)"
ck "pre five96 allows wait" empty "$(stdin_cmd "claude-usage-guard wait five $SID" | "$G" hook pre)"
ck "pre five96 allows abs-path wait" empty "$(stdin_cmd "/home/ashwani/.local/bin/claude-usage-guard wait five $SID" | "$G" hook pre)"
ck "pre grant asks" '.hookSpecificOutput.permissionDecision=="ask"' "$(stdin_cmd "claude-usage-guard grant $SID" | "$G" hook pre)"
# Any env prefix (even CUG_*) is denied: no assignment token may precede the binary.
ck "env-prefix CUG_ denied" "$deny" "$(stdin_cmd "CUG_TTL=60 claude-usage-guard status" | "$G" hook pre)"
ck "env-prefix LD_PRELOAD denied" "$deny" "$(stdin_cmd "LD_PRELOAD=/tmp/evil.so claude-usage-guard status" | "$G" hook pre)"
ck "env-prefix PATH denied" "$deny" "$(stdin_cmd "PATH=/attacker/bin claude-usage-guard status" | "$G" hook pre)"
ck "env-prefix BASH_ENV denied" "$deny" "$(stdin_cmd "BASH_ENV=/attacker.sh claude-usage-guard status" | "$G" hook pre)"
ck "env-prefix CUG_FETCH denied" "$deny" "$(stdin_cmd "CUG_FETCH=/attacker.sh claude-usage-guard status" | "$G" hook pre)"

# --- allowlist bypass attempts (all must be DENIED at five 96)
ck "bypass: chained &&" "$deny" "$(stdin_cmd "claude-usage-guard status && rm -rf /x" | "$G" hook pre)"
ck "bypass: multiline guard-first" "$deny" "$(stdin_cmd $'claude-usage-guard status\nrm -rf /x' | "$G" hook pre)"
ck "bypass: multiline guard-second" "$deny" "$(stdin_cmd $'rm -rf /x\nclaude-usage-guard status' | "$G" hook pre)"
ck "bypass: cmd substitution" "$deny" "$(stdin_cmd 'claude-usage-guard status $(rm -rf /x)' | "$G" hook pre)"
ck "bypass: backticks" "$deny" "$(stdin_cmd 'claude-usage-guard status `rm -rf /x`' | "$G" hook pre)"
ck "bypass: prefix binary" "$deny" "$(stdin_cmd 'rm -rf /x claude-usage-guard status' | "$G" hook pre)"
ck "bypass: redirection" "$deny" "$(stdin_cmd 'claude-usage-guard status > /x/f' | "$G" hook pre)"
ck "bypass: semicolon" "$deny" "$(stdin_cmd 'claude-usage-guard status; rm -rf /x' | "$G" hook pre)"

# --- fractional percentages: floored, never fail-open
fresh; setpct 96.5 10.2
ck "float five96.5 denies" "$deny" "$(printf '%s' "$STDIN_BASH" | "$G" hook pre)"
fresh; setpct 89.7 10
ck "float five89.7 warns not pauses" '.hookSpecificOutput.additionalContext | test("heads-up")' "$(printf '%s' "$STDIN_BASH" | "$G" hook post)"
fresh; setpct 10 99.9
ck "float week99.9 denies" "$deny" "$(printf '%s' "$STDIN_BASH" | "$G" hook pre)"

# --- one broken value: other guard stays active (both directions)
fresh
printf '{"five_pct":96,"five_resets":"2026-08-20T00:20:00+00:00","week_pct":null,"week_resets":null}\n' > "$FAKE"
ck "week null, five96 still denies" "$deny" "$(printf '%s' "$STDIN_BASH" | "$G" hook pre)"
fresh
printf '{"five_pct":null,"five_resets":null,"week_pct":86,"week_resets":"2026-08-25T15:00:00+00:00"}\n' > "$FAKE"
ck "five null, week86 still denies" "$deny" "$(printf '%s' "$STDIN_BASH" | "$G" hook pre)"

# --- five reset: flags re-arm
fresh; setpct 91 10; printf '%s' "$STDIN_BASH" | "$G" hook post >/dev/null
setpct 10 10; printf '%s' "$STDIN_BASH" | "$G" hook post >/dev/null
setpct 91 10
ck "five flags re-arm after drop" '.hookSpecificOutput.additionalContext | test("5-HOUR PAUSE")' "$(printf '%s' "$STDIN_BASH" | "$G" hook post)"

# --- week 82: ask once; pre allows (below hard 85)
fresh; setpct 10 82
o1=$(printf '%s' "$STDIN_BASH" | "$G" hook post)
o2=$(printf '%s' "$STDIN_BASH" | "$G" hook post)
ck "post week82 asks" '.hookSpecificOutput.additionalContext | test("WEEKLY LIMIT CHECKPOINT") and test("grant test-session-1")' "$o1"
ck "post week82 once" empty "$o2"
ck "pre week82 allows" empty "$(printf '%s' "$STDIN_BASH" | "$G" hook pre)"

# --- week 86 no grant: deny; grant lifts
fresh; setpct 10 86
ck "pre week86 denies" "$deny" "$(printf '%s' "$STDIN_BASH" | "$G" hook pre)"
"$G" grant "$SID" >/dev/null
ck "pre week86 after grant allows" empty "$(printf '%s' "$STDIN_BASH" | "$G" hook pre)"
ck "post week86 after grant silent" empty "$(printf '%s' "$STDIN_BASH" | "$G" hook post)"

# --- week 96 lvl1 grant: re-ask says --level 2, once; pre allows until 97
setpct 10 96
o1=$(printf '%s' "$STDIN_BASH" | "$G" hook post)
o2=$(printf '%s' "$STDIN_BASH" | "$G" hook post)
ck "post week96 re-asks lvl2" '.hookSpecificOutput.additionalContext | test("grant --level 2")' "$o1"
ck "post week96 re-ask once" empty "$o2"
ck "pre week96 lvl1 allows" empty "$(printf '%s' "$STDIN_BASH" | "$G" hook pre)"

# --- week 96 NO grant: message must demand --level 2 (not plain grant)
fresh; setpct 10 96
ck "post week96 nogrant asks lvl2" '.hookSpecificOutput.additionalContext | test("grant --level 2")' "$(printf '%s' "$STDIN_BASH" | "$G" hook post)"

# --- week 98: lvl1 denied, lvl2 allows
fresh; setpct 10 98
"$G" grant "$SID" >/dev/null
ck "pre week98 lvl1 denies" "$deny" "$(printf '%s' "$STDIN_BASH" | "$G" hook pre)"
"$G" grant --level 2 "$SID" >/dev/null
ck "pre week98 lvl2 allows" empty "$(printf '%s' "$STDIN_BASH" | "$G" hook pre)"

# --- grant expires + flags re-arm on new weekly window
fresh; setpct 10 86
printf '%s' "$STDIN_BASH" | "$G" hook post >/dev/null      # sets asked_week80 in old window
"$G" grant "$SID" >/dev/null
setpct 10 86 "2026-09-01T15:00:00+00:00"                   # window rolls over
ck "grant expires on new window" "$deny" "$(printf '%s' "$STDIN_BASH" | "$G" hook pre)"
ck "flags re-arm on new window" '.hookSpecificOutput.additionalContext | test("WEEKLY LIMIT CHECKPOINT")' "$(printf '%s' "$STDIN_BASH" | "$G" hook post)"

# --- grant refused when reset time unknown
fresh
printf '{"five_pct":10,"five_resets":"2026-08-20T00:20:00+00:00","week_pct":86,"week_resets":null}\n' > "$FAKE"
"$G" grant "$SID" >/dev/null 2>"$T/gerr"; rc=$?
ck "grant refused w/o reset time" nonempty "$( [ $rc -ne 0 ] && grep -q 'reset time unknown' "$T/gerr" && echo ok )"

# --- sessionstart: emits context AND suppresses the duplicate post message
fresh; setpct 10 82
ck "sessionstart week82 context" '.hookSpecificOutput.hookEventName=="SessionStart" and (.hookSpecificOutput.additionalContext | test("WEEKLY LIMIT CHECKPOINT"))' "$(printf '%s' "$STDIN_BASH" | "$G" hook sessionstart)"
ck "post after sessionstart silent" empty "$(printf '%s' "$STDIN_BASH" | "$G" hook post)"

# --- session_id sanitization: no path traversal
fresh; setpct 10 82
jq -nc '{session_id:"../../../../escape-target/boom",tool_name:"Bash",tool_input:{command:"ls"}}' | "$G" hook post >/dev/null
found=$(find "$T" -path "$T/run" -prune -o -type d -name boom -print; find /tmp/escape-target "$T/escape-target" -maxdepth 0 2>/dev/null)
ck "sid traversal contained" empty "$found"
ck "sid traversal stays in sessions dir" nonempty "$(find "$CUG_RUN_DIR/sessions" -maxdepth 1 -mindepth 1 -type d)"

# --- fail-open: garbage / empty stdin
fresh; echo 'garbage' > "$FAKE"
ck "pre fail-open" empty "$(printf '%s' "$STDIN_BASH" | "$G" hook pre)"
ck "post fail-open" empty "$(printf '%s' "$STDIN_BASH" | "$G" hook post)"
setpct 96 10
ck "pre denies with garbage stdin" "$deny" "$(printf 'not json' | "$G" hook pre)"

# --- concurrency: 10 parallel posts, exactly one injection
fresh; setpct 10 82
: > "$T/conc.out"
for i in $(seq 10); do ( printf '%s' "$STDIN_BASH" | "$G" hook post >> "$T/conc.out" ) & done
wait
n=$(grep -c 'WEEKLY LIMIT CHECKPOINT' "$T/conc.out")
ck "concurrent post injects exactly 1 (got $n)" nonempty "$( [ "$n" -eq 1 ] && echo ok )"

# --- wait: exits immediately when below threshold
fresh; setpct 10 10
ck "wait five exits when low" nonempty "$(timeout 10 "$G" wait five "$SID")"

# --- wait week: exits on grant
fresh; setpct 10 85
( sleep 2; "$G" grant "$SID" >/dev/null ) &
ck "wait week exits on grant" nonempty "$(timeout 90 "$G" wait week "$SID" | grep -i 'granted permission')"

# --- hook stop: waiter starts, wakes (exit 2) after usage drops; lock dedups
fresh; setpct 96 10
printf '%s' "$STDIN_BASH" | timeout 150 "$G" hook stop 2>"$T/stop.err" &
stop_pid=$!
sleep 3
ck "stop lock dedups second waiter" empty "$(printf '%s' "$STDIN_BASH" | timeout 10 "$G" hook stop 2>&1)"
setpct 10 10
wait "$stop_pid"; rc=$?
ck "stop waiter exits 2 on reset (rc=$rc)" nonempty "$( [ $rc -eq 2 ] && grep -q 'auto-waiter' "$T/stop.err" && echo ok )"

# --- hook stop week scope: wakes when the user grants mid-wait
fresh; setpct 10 86
printf '%s' "$STDIN_BASH" | timeout 150 "$G" hook stop 2>"$T/stopw.err" &
sp=$!
sleep 2
"$G" grant "$SID" >/dev/null
wait "$sp"; rc=$?
ck "stop week wakes on grant (rc=$rc)" nonempty "$( [ $rc -eq 2 ] && grep -q 'auto-waiter' "$T/stopw.err" && echo ok )"

# --- lock is flock-based: reclaimed after SIGKILL, next waiter can start
fresh; setpct 96 10
printf '%s' "$STDIN_BASH" | "$G" hook stop 2>/dev/null &
k9=$!
sleep 2; kill -9 "$k9" 2>/dev/null; wait "$k9" 2>/dev/null
printf '%s' "$STDIN_BASH" | "$G" hook stop 2>/dev/null &
w2=$!
sleep 4
if kill -0 "$w2" 2>/dev/null; then lock_ok=ok; else lock_ok=; fi
kill "$w2" 2>/dev/null; wait "$w2" 2>/dev/null
ck "lock reclaimed after SIGKILL" nonempty "$lock_ok"

# --- macOS portability: BSD timestamp normalization (pure fn, runs everywhere)
eval "$(sed -n '/^_bsd_norm()/,/^}/p' "$G")"
ck "bsd_norm frac+colon-tz" nonempty "$( [ "$(_bsd_norm '2026-08-20T00:20:00.007756+00:00')" = '2026-08-20T00:20:00+0000' ] && echo ok )"
ck "bsd_norm colon-tz"      nonempty "$( [ "$(_bsd_norm '2026-08-25T15:00:00+00:00')"        = '2026-08-25T15:00:00+0000' ] && echo ok )"
ck "bsd_norm Z"             nonempty "$( [ "$(_bsd_norm '2026-08-25T15:00:00Z')"             = '2026-08-25T15:00:00+0000' ] && echo ok )"
ck "bsd_norm compact-tz"    nonempty "$( [ "$(_bsd_norm '2026-08-25T15:00:00+0530')"         = '2026-08-25T15:00:00+0530' ] && echo ok )"

# --- macOS portability: no-flock lock path (mkdir+PID) reclaims after SIGKILL
export CUG_NO_FLOCK=1
fresh; setpct 96 10
printf '%s' "$STDIN_BASH" | "$G" hook stop 2>/dev/null &
nk=$!
sleep 2; kill -9 "$nk" 2>/dev/null; wait "$nk" 2>/dev/null
printf '%s' "$STDIN_BASH" | "$G" hook stop 2>/dev/null &
nw=$!
sleep 4
if kill -0 "$nw" 2>/dev/null; then nf_ok=ok; else nf_ok=; fi
kill "$nw" 2>/dev/null; wait "$nw" 2>/dev/null
ck "no-flock lock reclaimed after SIGKILL" nonempty "$nf_ok"
# no-flock waiter still wakes (exit 2) on reset
fresh; setpct 96 10
printf '%s' "$STDIN_BASH" | timeout 150 "$G" hook stop 2>"$T/nf.err" &
nsp=$!
sleep 3; setpct 10 10
wait "$nsp"; rc=$?
ck "no-flock stop wakes on reset (rc=$rc)" nonempty "$( [ $rc -eq 2 ] && grep -q 'auto-waiter' "$T/nf.err" && echo ok )"
unset CUG_NO_FLOCK

# --- stale data with reset long past: no instant wake (min-wait + marker)
fresh
printf '{"five_pct":96,"five_resets":"2026-08-19T00:00:00+00:00","week_pct":10,"week_resets":"2026-08-25T15:00:00+00:00"}\n' > "$FAKE"
printf '%s' "$STDIN_BASH" | "$G" hook stop 2>/dev/null &
sw=$!
sleep 5
if kill -0 "$sw" 2>/dev/null; then still=ok; else still=; fi
kill "$sw" 2>/dev/null; wait "$sw" 2>/dev/null
ck "no instant wake on stale past reset" nonempty "$still"

# --- real fetch path (no CUG_USAGE_FAKE): normalization, cache, stale-if-error
cat > "$T/stubfetch.sh" <<'STUB'
#!/usr/bin/env bash
printf '{"five_hour":{"utilization":89.7,"resets_at":"2026-08-20T00:20:00+00:00"},"seven_day":{"utilization":12.4,"resets_at":"2026-08-25T15:00:00+00:00"}}\n'
STUB
out=$(env -u CUG_USAGE_FAKE CUG_FETCH="$T/stubfetch.sh" CUG_RUN_DIR="$T/run2" "$G" state)
ck "real path normalizes and floors" '.five_pct==89 and .week_pct==12' "$out"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/stubfetch.sh"
out=$(env -u CUG_USAGE_FAKE CUG_FETCH="$T/stubfetch.sh" CUG_RUN_DIR="$T/run2" "$G" state)
ck "cache TTL serves cached value" '.five_pct==89' "$out"
out=$(env -u CUG_USAGE_FAKE CUG_FETCH="$T/stubfetch.sh" CUG_RUN_DIR="$T/run2" "$G" state --fresh)
ck "stale-if-error keeps old data" '.five_pct==89' "$out"

# --- macOS portability: run_fetch watchdog fallback (no coreutils timeout)
cat > "$T/qfetch.sh" <<'STUB'
#!/usr/bin/env bash
printf '{"five_hour":{"utilization":40,"resets_at":"2026-08-20T00:20:00+00:00"},"seven_day":{"utilization":20,"resets_at":"2026-08-25T15:00:00+00:00"}}\n'
STUB
t0=$(date +%s)
out=$(env -u CUG_USAGE_FAKE CUG_NO_TIMEOUT=1 CUG_FETCH="$T/qfetch.sh" CUG_RUN_DIR="$T/run3" "$G" state)
t1=$(date +%s)
ck "no-timeout fetch returns data" '.five_pct==40 and .week_pct==20' "$out"
ck "no-timeout fetch not blocked by 10s watchdog" nonempty "$( [ $((t1-t0)) -lt 8 ] && echo ok )"

# --- CLI error handling
ck "grant no sid exit2" nonempty "$("$G" grant 2>&1 >/dev/null; [ $? -eq 2 ] && echo ok)"
ck "wait bad scope exit2" nonempty "$("$G" wait nope 2>&1 >/dev/null; [ $? -eq 2 ] && echo ok)"
ck "help goes to stderr" empty "$("$G" 2>/dev/null)"

echo; echo "passed=$pass failed=$fail"; rm -rf "$T"; exit $(( fail > 0 ))
