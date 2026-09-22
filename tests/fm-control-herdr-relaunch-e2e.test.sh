#!/usr/bin/env bash
# shellcheck disable=SC2016 # adapter snippets expand in the child shell they are passed to
# Real-Herdr regression: a ship task whose Herdr endpoint is gone can be
# relaunched into its own recorded worktree once nothing runs there.
#
# Two ways the endpoint disappears are pinned against the real binary:
#   1. The pane is closed by hand. Recovery reads the endpoint `missing`, a
#      process still sitting in the worktree refuses the relaunch without
#      changing anything, and once that process is gone `relaunch` creates a
#      fresh pane in the same worktree and republishes the record.
#   2. The agent's own exit closes the pane (an `exec`-launched agent). `exit`
#      reports the stop with the endpoint gone instead of failing, a repeated
#      `exit` names relaunch as the way forward, and `relaunch` then succeeds;
#      a single `relaunch` of a live agent of that shape succeeds too.
#
# No real harness runs. A script named `claude` is the agent process the
# adapter attributes, it registers itself through Herdr's own agent registry,
# draws an empty composer, and then runs as a process named `claude` that exits
# on the first submitted line.
#
# Every Herdr call goes through bin/fm-herdr-lab.sh on a named lab session:
# a PATH shim routes the adapter's own `--session <lab>` calls through the
# helper and rejects any other session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane
fm_live_gate default-on FM_HERDR_CONTROL_RELAUNCH_E2E herdr jq lsof awk

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: live: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-control-herdr-relaunch)
FAKEBIN="$TMP_ROOT/fakebin"
AGENTBIN="$TMP_ROOT/agentbin"
REALBIN="$TMP_ROOT/realbin"
MARKERS="$TMP_ROOT/markers"
HOME_DIR="$TMP_ROOT/home"
USER_HOME="$TMP_ROOT/user-home"
mkdir -p "$FAKEBIN" "$AGENTBIN" "$REALBIN" "$MARKERS" "$HOME_DIR/state" "$USER_HOME"
: > "$MARKERS/launches"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-ctl-relaunch)
# The lab server's panes inherit this PATH, so the stand-in agent resolves by
# name exactly as a real one would. AGENTBIN holds nothing else.
HERDR_ORIGINAL_PATH="$AGENTBIN:$PATH"
HERDR_ORIGINAL_HOME=$HOME
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH HERDR_ORIGINAL_HOME

OCCUPANT_PID=
cleanup() {
  local status=$?
  if [ -n "$OCCUPANT_PID" ]; then
    kill "$OCCUPANT_PID" 2>/dev/null || true
    wait "$OCCUPANT_PID" 2>/dev/null || true
  fi
  env PATH="$HERDR_ORIGINAL_PATH" HOME="$HERDR_ORIGINAL_HOME" \
    "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT

cat > "$AGENTBIN/claude" <<SH
#!/usr/bin/env bash
# Inert stand-in agent for tests/fm-control-herdr-relaunch-e2e.test.sh.
printf '%s\n' "\$PWD" >> '$MARKERS/launches'
env PATH='$HERDR_ORIGINAL_PATH' HOME='$HERDR_ORIGINAL_HOME' '$HERDR_LAB_HELPER' run '$HERDR_LAB_SESSION' \\
  pane report-agent "\$HERDR_PANE_ID" --source fm-relaunch-e2e --agent claude --state idle >> '$MARKERS/report.log' 2>&1
printf '╭──────────────╮\n│ >            │\n╰──────────────╯\n'
# The process the adapter attributes must itself be named claude, so the wait
# for the exit command is a real binary run under that name: it returns on
# the first submitted line.
exec '$REALBIN/claude' 'NR == 1 { exit }' >/dev/null
SH
chmod +x "$AGENTBIN/claude"
# awk, not a coreutils tool: a multi-call coreutils build dispatches on the
# invoked name and would refuse to run as claude.
ln -s "$(command -v awk)" "$REALBIN/claude" || fail "could not name the stand-in agent process"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" HOME="$HERDR_ORIGINAL_HOME" \
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab session"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

# Runs a snippet with the adapter sourced against the lab session.
adapter() {  # <snippet> [args...]
  local snippet=$1
  shift
  env PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" HERDR_SESSION="$HERDR_LAB_SESSION" FM_HOME="$HOME_DIR" \
    bash -c '
      set -u
      . "$FM_TEST_ROOT/bin/fm-backend.sh"
      fm_backend_source herdr || exit 1
      '"$snippet" _ "$@"
}

run_fm() {  # <script> <args...>
  local script=$1
  shift
  env PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_HOME="$HOME_DIR" HOME="$USER_HOME" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=10 FM_CONTROL_LAUNCH_WAIT=30 \
    "$ROOT/bin/$script" "$@" 2>&1
}

export FM_TEST_ROOT=$ROOT

meta_field() {  # <id> <key>
  sed -n "s/^$2=//p" "$HOME_DIR/state/$1.meta" | tail -1
}

journal_field() {  # <id> <key>
  sed -n "s/^$2=//p" "$HOME_DIR/state/$1.control-relaunch" | tail -1
}

recovery_state() {  # <target>
  adapter 'fm_backend_agent_state herdr "$1"' "$1"
}

wait_recovery_state() {  # <target> <want> [tries]
  local i=0 tries=${3:-100}
  while [ "$i" -lt "$tries" ]; do
    [ "$(recovery_state "$1")" != "$2" ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

pane_screen() {  # <id>
  adapter 'fm_backend_herdr_capture "$1" 40' "$(meta_field "$1" window)" 2>&1
}

launch_count() {
  wc -l < "$MARKERS/launches" | tr -d ' '
}

wait_launch_count() {  # <count>
  local i=0
  while [ "$i" -lt 100 ]; do
    [ "$(launch_count)" -lt "$1" ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# new_task <id>: a real worktree, instructions, and a task tab created through
# the adapter itself; echoes the endpoint target.
new_task() {
  local id=$1 proj="$TMP_ROOT/proj-$1" wt="$TMP_ROOT/wt-$1" raw container seeded ids tab pane
  fm_git_worktree "$proj" "$wt" "task-$id" >/dev/null 2>&1 || fail "could not create the $id worktree"
  mkdir -p "$HOME_DIR/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nRelaunch %s.\n\n## Firstmate spec\nKeep the worktree.\n\n# Definition of done\nDelivery contract: mode=local-only\n' "$id" \
    > "$HOME_DIR/data/$id/brief.md"
  raw=$(adapter 'fm_backend_herdr_container_ensure "$1"' "$proj") || fail "container_ensure failed for $id"
  container=${raw%%$'\t'*}
  seeded=${raw#*$'\t'}
  ids=$(adapter 'fm_backend_herdr_create_task "$1" "$2" "$3" "$4"' "$container" "fm-$id" "$wt" "$seeded") \
    || fail "create_task failed for $id"
  read -r tab pane <<EOF
$ids
EOF
  [ -n "$tab" ] && [ -n "$pane" ] || fail "create_task returned no ids for $id"
  {
    echo "window=$HERDR_LAB_SESSION:$pane"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=local-only"
    echo "yolo=off"
    echo "tasktmp=$TMP_ROOT/tasktmp-$id"
    echo "model=default"
    echo "effort=default"
    echo "backend=herdr"
    echo "herdr_session=$HERDR_LAB_SESSION"
    echo "herdr_workspace_id=${container#*:}"
    echo "herdr_tab_id=$tab"
    echo "herdr_pane_id=$pane"
  } > "$HOME_DIR/state/$id.meta"
  printf '%s' "$HERDR_LAB_SESSION:$pane"
}

# start_exec_agent <target>: replace the pane's shell with the stand-in agent,
# so the agent's exit closes the pane.
start_exec_agent() {  # <target>
  local pane=${1#*:} before
  before=$(launch_count)
  lab pane run "$pane" "exec $AGENTBIN/claude" >/dev/null || fail "could not start the stand-in agent in $pane"
  wait_launch_count $((before + 1)) || fail "the stand-in agent never started in $pane"
  wait_recovery_state "$1" alive || fail "the stand-in agent in $pane reads '$(recovery_state "$1")', not alive"
}

assert_relaunched_fresh() {  # <id> <old-target> <label>
  local id=$1 old=$2 label=$3 new wt_real
  new=$(meta_field "$id" window)
  [ -n "$new" ] && [ "$new" != "$old" ] || fail "$label: the record still names the vanished endpoint '$old'"
  [ "$new" = "$HERDR_LAB_SESSION:$(meta_field "$id" herdr_pane_id)" ] \
    || fail "$label: the republished window and pane id disagree"
  lab pane get "$(meta_field "$id" herdr_pane_id)" >/dev/null 2>&1 \
    || fail "$label: the replacement pane does not exist"
  wait_recovery_state "$new" alive || fail "$label: the replacement endpoint reads '$(recovery_state "$new")', not alive"
  wt_real=$(cd "$(meta_field "$id" worktree)" && pwd -P)
  [ "$(tail -1 "$MARKERS/launches")" = "$wt_real" ] \
    || fail "$label: the replacement agent started in '$(tail -1 "$MARKERS/launches")', not the recorded worktree"
  [ "$(journal_field "$id" phase)" = complete ] || fail "$label: the relaunch journal did not complete"
  # The vanished endpoint is deliberately NOT asserted here: the relaunch
  # journal is one current record replaced at each phase, not a log, so after a
  # completed reclaim it carries the endpoint the task now has and nothing about
  # the one it replaced.
  [ "$(journal_field "$id" endpoint)" = "$new" ] \
    || fail "$label: the relaunch journal does not record the replacement endpoint"
}

# --- 1. a hand-closed pane --------------------------------------------------

T1=$(new_task hand); [ -n "$T1" ] || fail "could not create the hand task"
# Every relaunch below types the bare harness name into a fresh pane, so the
# lab's pane shell must resolve it to the stand-in, never to an installed agent.
lab pane run "${T1#*:}" "command -v claude > '$MARKERS/resolved'" >/dev/null \
  || fail "could not ask the lab pane how it resolves the harness name"
for _ in $(seq 1 50); do
  [ ! -s "$MARKERS/resolved" ] || break
  sleep 0.1
done
[ "$(cat "$MARKERS/resolved" 2>/dev/null)" = "$AGENTBIN/claude" ] \
  || fail "refusing to continue: lab panes resolve claude to '$(cat "$MARKERS/resolved" 2>/dev/null)', not the stand-in, so a relaunch could start a real agent"
lab pane close "${T1#*:}" >/dev/null || fail "could not close the task pane by hand"
wait_recovery_state "$T1" missing || fail "a hand-closed pane reads '$(recovery_state "$T1")', not missing"

WT1=$(meta_field hand worktree)
BRIEF_BEFORE=$(cat "$HOME_DIR/data/hand/brief.md")
(cd "$WT1" && exec sleep 300) &
OCCUPANT_PID=$!
for _ in $(seq 1 50); do
  lsof -a -p "$OCCUPANT_PID" -d cwd >/dev/null 2>&1 && break
  sleep 0.1
done

if OUT=$(run_fm fm-control.sh hand relaunch --note "pane was closed by hand"); then
  fail "relaunch must refuse while a process still runs in the worktree: $OUT"
fi
assert_contains "$OUT" "not proven agent-free" "the refusal should name the unproven worktree"
assert_contains "$OUT" "$OCCUPANT_PID" "the refusal should name the occupying process"
[ "$(meta_field hand window)" = "$T1" ] || fail "a refused relaunch must not change the record"
[ "$(cat "$HOME_DIR/data/hand/brief.md")" = "$BRIEF_BEFORE" ] || fail "a refused relaunch must not change the instructions"
[ "$(launch_count)" = 0 ] || fail "a refused relaunch must not launch anything"

if OUT=$(run_fm fm-spawn.sh hand --relaunch); then
  fail "a direct launch-owner relaunch must refuse while a process still runs in the worktree: $OUT"
fi
assert_contains "$OUT" "not proven agent-free" "the launch owner should refuse on its own"
[ "$(meta_field hand window)" = "$T1" ] || fail "a refused launch-owner relaunch must not change the record"
pass "real herdr: a hand-closed pane with a process still in its worktree refuses relaunch and changes nothing"

kill "$OCCUPANT_PID" 2>/dev/null || true
wait "$OCCUPANT_PID" 2>/dev/null || true
OCCUPANT_PID=

OUT=$(run_fm fm-control.sh hand relaunch --note "pane was closed by hand") \
  || fail "a hand-closed pane with an agent-free worktree should relaunch: $OUT"$'\n'"$(pane_screen hand)"$'\n'"report: $(cat "$MARKERS/report.log")"$'\n'"agent: $(lab agent get "$(meta_field hand herdr_pane_id)" 2>&1)"$'\n'"proc: $(lab pane process-info --pane "$(meta_field hand herdr_pane_id)" 2>&1)"
assert_contains "$OUT" "relaunched hand harness=claude" "the relaunch should report its outcome"
assert_relaunched_fresh hand "$T1" "hand-closed"
assert_grep "pane was closed by hand" "$HOME_DIR/data/hand/brief.md" "the progress note should reach the replacement"
pass "real herdr: a hand-closed pane is relaunched into a fresh pane in its own worktree"

# --- 2. exit closes the pane, then relaunch ---------------------------------

T2=$(new_task exited); [ -n "$T2" ] || fail "could not create the exited task"
start_exec_agent "$T2"
OUT=$(run_fm fm-control.sh exited exit) || fail "exit of an agent whose pane closes with it should succeed: $OUT"
case "$OUT" in
  "endpoint-gone exited"*) : ;;
  *) fail "exit should report the stop with the endpoint gone, got: $OUT" ;;
esac
[ "$(recovery_state "$T2")" = missing ] || fail "the exited agent's pane should be gone"

# A repeated exit is idempotent rather than a refusal: the verb's postcondition
# already holds, so it reports the same proven-gone endpoint again and changes
# nothing. Relaunch is what re-creates that endpoint, and it is exercised next.
OUT=$(run_fm fm-control.sh exited exit) \
  || fail "a repeated exit on a proven-gone endpoint should stay idempotent: $OUT"
case "$OUT" in
  "endpoint-gone exited"*) : ;;
  *) fail "a repeated exit should report the endpoint gone again, got: $OUT" ;;
esac
[ "$(recovery_state "$T2")" = missing ] || fail "a repeated exit must not resurrect the endpoint"

OUT=$(run_fm fm-control.sh exited relaunch --note "exited cleanly earlier") \
  || fail "a cleanly exited task should relaunch into its own worktree: $OUT"
assert_relaunched_fresh exited "$T2" "exit-then-relaunch"
[ "$(journal_field exited exit_result)" = endpoint-gone ] \
  || fail "the relaunch should record that it found the endpoint already gone"
pass "real herdr: exit that closes its pane reports it, and a later relaunch uses the recorded worktree"

T3=$(new_task inline); [ -n "$T3" ] || fail "could not create the inline task"
start_exec_agent "$T3"
OUT=$(run_fm fm-control.sh inline relaunch --note "replace a live agent whose pane closes on exit") \
  || fail "relaunch of a live agent whose pane closes on exit should succeed: $OUT"
assert_relaunched_fresh inline "$T3" "inline relaunch"
[ "$(journal_field inline exit_result)" = endpoint-gone ] \
  || fail "the relaunch should record that the exit closed the endpoint"
pass "real herdr: relaunch of a live agent whose pane closes on exit lands in a fresh pane"
