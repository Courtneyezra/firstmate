#!/usr/bin/env bash
# Regression tests for the guarantee that no two workers are ever given the
# same working copy, and for telling an exhausted pool apart from a bad slot.
#
# Treehouse hands out no slot that holds a running process and no slot it has
# leased, but a crewmate slot is held by a TASK, not by a process: a task whose
# worker is dead or between incarnations leaves its work in a slot with nothing
# running in it, which Treehouse reads as available. Below the pool's size limit
# that is harmless, because Treehouse creates a fresh slot instead; AT the limit
# that slot is the only one it has, which is why a second worker landing in
# another task's working copy is a failure that appears only at exhaustion.
#
# These tests drive the real spawn path with a fake terminal and a fake pool and
# assert the spawn refuses an occupied slot rather than launching into it,
# replaces only a claim it can prove stale, and reports exhaustion distinguishably.
#
# The two exit codes are spelled literally here because they are the contract a
# caller reads: 75 for an exhausted pool, which asking again cannot help, and 76
# for a slot this home must not use while the pool has another to give.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

POOL_EXHAUSTED_EXIT=75
POOL_BAD_SLOT_EXIT=76

TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-slot-occupancy)

# A `treehouse` stub whose `status --json` answers from FM_FAKE_TREEHOUSE_STATUS,
# standing in for the pool scan the real binary performs. Every other subcommand
# succeeds silently, exactly as the shared spawn fakebin's stub does.
make_pool_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$dir")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = status ]; then
  if [ -n "${FM_FAKE_TREEHOUSE_LIVE_PID_SLOT:-}" ]; then
    # Start a process HERE, mid-spawn, and report it as the slot's occupant:
    # it is younger than the spawn's own start, which is what the occupancy
    # boundary has to tolerate or every real spawn would refuse its own pane.
    # Detached from this command substitution's stdout, or the caller reading
    # the JSON would block until the process exits.
    "$(command -pv sleep)" 60 >/dev/null 2>&1 &
    printf '[{"name":"1","path":"%s","status":"%s","processes":[{"pid":%s,"name":"ours"}]}]\n' \
      "$FM_FAKE_TREEHOUSE_LIVE_PID_SLOT" "${FM_FAKE_TREEHOUSE_LIVE_PID_STATUS:-available}" "$!"
    exit 0
  fi
  cat "${FM_FAKE_TREEHOUSE_STATUS:-/dev/null}"
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  # The endpoint's shell, made real: `treehouse get` typed into the pane starts
  # a process whose working directory is the slot, as the real subshell's is,
  # and closing the window ends it. Its pid is published so a test can ask
  # whether anything this spawn started is still sitting in the slot.
  mv "$fakebin/tmux" "$fakebin/tmux-stub"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
here=$(dirname "$0")
case "${1:-}" in
  send-keys)
    case "$*" in
      *"treehouse get"*)
        if [ -n "${FM_FAKE_ENDPOINT_PID_FILE:-}" ]; then
          (CDPATH='' cd -- "$FM_FAKE_PANE_PATH" && exec "$(command -pv sleep)" 300) >/dev/null 2>&1 &
          printf '%s\n' "$!" > "$FM_FAKE_ENDPOINT_PID_FILE"
        fi
        ;;
    esac
    ;;
  kill-window)
    if [ -n "${FM_FAKE_ENDPOINT_PID_FILE:-}" ] && [ -s "$FM_FAKE_ENDPOINT_PID_FILE" ]; then
      kill "$(cat "$FM_FAKE_ENDPOINT_PID_FILE")" 2>/dev/null || true
    fi
    ;;
esac
exec "$here/tmux-stub" "$@"
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# make_case <name> <id> builds a home, an origin-less project, and a Treehouse-
# shaped pool <pool>/1/<repo> whose slot is a real worktree of that project, so
# fm_treehouse_pool_slot recognizes it and the slot claim lands beside it.
make_case() {
  local name=$1 id=$2 case_dir home project pool slot other fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  pool="$case_dir/pool"
  slot="$pool/1/project"
  other="$case_dir/other-home"
  fakebin=$(make_pool_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$pool"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"
  printf '{"worktrees":[]}\n' > "$pool/treehouse-state.json"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$project" worktree add --quiet --detach "$slot" HEAD

  mkdir -p "$other/state"
  printf '%s\n' "$case_dir|$home|$project|$slot|$other|$fakebin"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR SLOT_DIR OTHER_HOME FAKEBIN_DIR <<REC
$1
REC
}

# write_pool_status [--spare] <status> [pid...] publishes the pool scan the stub
# replays: one slot, in the given state, holding the given pids, plus a second
# available slot when --spare is given, so a refused slot is not the only one.
# The spare is a real directory so its own claim, when a test writes one, can be
# read like any other slot's.
write_pool_status() {
  local spare='' state procs='' pid
  if [ "${1:-}" = --spare ]; then
    mkdir -p "$CASE_DIR/pool/2/project"
    spare=",{\"name\":\"2\",\"path\":\"$CASE_DIR/pool/2/project\",\"status\":\"available\",\"processes\":[]}"
    shift
  fi
  state=$1
  shift
  for pid in "$@"; do
    procs="$procs{\"pid\":$pid,\"name\":\"stray\"},"
  done
  procs=${procs%,}
  cat > "$CASE_DIR/pool-status.json" <<JSON
[{"name":"1","path":"$SLOT_DIR","status":"$state","processes":[$procs]}$spare]
JSON
  export FM_FAKE_TREEHOUSE_STATUS="$CASE_DIR/pool-status.json"
}

# claim_slot <task-id> <home> writes the slot claim a previous holder left.
claim_slot() {
  cat > "$(dirname "$SLOT_DIR")/.fm-slot-owner" <<CLAIM
task=$1
home=$2
CLAIM
}

# run_pool_spawn <id> [pane-path] drives the real spawn; the pane path defaults
# to the pool slot, standing in for the worktree `treehouse get` moved it to.
run_pool_spawn() {
  local id=$1 pane=${2:-$SLOT_DIR}
  fm_test_run_spawn "$HOME_DIR" "$pane" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" --scout
}

# set_max_trees <n> commits a treehouse.toml limiting the project's pool.
set_max_trees() {
  printf 'max_trees = %s\nroot = ""\n' "$1" > "$PROJECT_DIR/treehouse.toml"
  git -C "$PROJECT_DIR" add treehouse.toml
  git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'pool limit'
}

# assert_not_launched <id> <what> proves the refusal stopped before the worker.
assert_not_launched() {
  [ ! -e "$HOME_DIR/state/$1.meta" ] || fail "$2: the refused spawn still published task metadata"
}

# The fault itself: at exhaustion the pool offers a processless slot that another
# task's records still hold, and nothing may put a second worker into it.
test_slot_held_by_a_live_task_is_refused() {
  local rec id out status
  id=pool-occupied-live-a1
  rec=$(make_case occupied-live "$id")
  read_case_record "$rec"
  write_pool_status --spare available
  : > "$OTHER_HOME/state/neighbour-task.meta"
  claim_slot neighbour-task "$OTHER_HOME"

  out=$(run_pool_spawn "$id")
  status=$?
  expect_code "$POOL_BAD_SLOT_EXIT" "$status" \
    "a slot another live task holds must be refused as a bad slot"$'\n'"$out"
  assert_contains "$out" "neighbour-task" \
    "the refusal did not name the task that still holds the slot"
  assert_contains "$out" "not free" \
    "the refusal did not say the working copy was not free"
  assert_not_launched "$id" "an occupied slot"
  assert_grep "task=neighbour-task" "$(dirname "$SLOT_DIR")/.fm-slot-owner" \
    "the refused spawn overwrote the holder's claim"
  pass "a pool slot another live task holds is refused, and its claim survives"
}

# The one claim that may be replaced: its home is still here and holds no record
# for the task it names, which is what a spawn that aborted after claiming left.
test_orphan_claim_is_replaced() {
  local rec id out status
  id=pool-orphan-claim-a2
  rec=$(make_case orphan-claim "$id")
  read_case_record "$rec"
  write_pool_status available
  claim_slot vanished-task "$OTHER_HOME"

  out=$(run_pool_spawn "$id")
  status=$?
  expect_code 0 "$status" \
    "a claim whose home holds no record for it is stale and must be replaceable"$'\n'"$out"
  assert_grep "task=$id" "$(dirname "$SLOT_DIR")/.fm-slot-owner" \
    "the spawn did not take over the orphaned claim"
  pass "an orphaned slot claim is replaced rather than poisoning the slot"
}

# Claimable means proved free, never merely not-proved-busy: a home that is not
# here cannot prove its claim stale, so the slot stays refused.
test_claim_whose_home_is_absent_is_refused() {
  local rec id out status
  id=pool-absent-home-a3
  rec=$(make_case absent-home "$id")
  read_case_record "$rec"
  write_pool_status --spare available
  claim_slot far-task "$CASE_DIR/home-that-is-not-here"

  out=$(run_pool_spawn "$id")
  status=$?
  expect_code "$POOL_BAD_SLOT_EXIT" "$status" \
    "a claim whose home cannot be inspected must not be replaced"$'\n'"$out"
  assert_contains "$out" "home-that-is-not-here" \
    "the refusal did not name the home it could not inspect"
  assert_not_launched "$id" "an unprovable claim"
  pass "a slot claim whose home is gone is refused rather than assumed stale"
}

# The guard that needs no Firstmate record to fire: whatever was already running
# in the slot when the allocation went out was there before the slot was ours.
test_slot_holding_a_stray_process_is_refused() {
  local rec id out status
  id=pool-stray-process-a4
  rec=$(make_case stray-process "$id")
  read_case_record "$rec"
  # pid 1 is real and started long before this spawn asked for a slot, so the
  # age comparison runs against a genuine process rather than a fabricated one.
  write_pool_status --spare available 1

  out=$(run_pool_spawn "$id")
  status=$?
  expect_code "$POOL_BAD_SLOT_EXIT" "$status" \
    "a slot holding a process older than the allocation must be refused"$'\n'"$out"
  assert_contains "$out" "already held" \
    "the refusal did not say the slot was already occupied"
  assert_not_launched "$id" "a slot holding a stray process"
  pass "a pool slot holding a stray process is not accepted as free"
}

# An occupant whose age cannot be read is not an absent occupant.
test_slot_holding_an_unreadable_process_is_refused() {
  local rec id out status
  id=pool-unreadable-process-a5
  rec=$(make_case unreadable-process "$id")
  read_case_record "$rec"
  write_pool_status --spare available 2147483646

  out=$(run_pool_spawn "$id")
  status=$?
  expect_code "$POOL_BAD_SLOT_EXIT" "$status" \
    "a slot occupant whose age cannot be read must be refused, not ignored"$'\n'"$out"
  assert_not_launched "$id" "a slot with an unreadable occupant"
  pass "a slot occupant whose age cannot be read is refused rather than ignored"
}

# The other side of that boundary, and the one a real spawn hits on EVERY
# allocation: the endpoint's own shell is created before `treehouse get` is sent
# and follows the allocation into the slot, so a process younger than this
# spawn's own start must never be read as somebody else's occupant.
test_slot_holding_only_our_own_process_is_accepted() {
  local rec id out status
  id=pool-own-process-a8
  rec=$(make_case own-process "$id")
  read_case_record "$rec"
  export FM_FAKE_TREEHOUSE_LIVE_PID_SLOT="$SLOT_DIR"

  out=$(run_pool_spawn "$id")
  status=$?
  unset FM_FAKE_TREEHOUSE_LIVE_PID_SLOT
  expect_code 0 "$status" \
    "a process started during this spawn must not be read as a prior occupant"$'\n'"$out"
  assert_grep "task=$id" "$(dirname "$SLOT_DIR")/.fm-slot-owner" \
    "the spawn did not claim the slot it was given"
  pass "a slot holding only this spawn's own process is accepted"
}

# A refusal must not leave this spawn's own shell in the refused slot: that is a
# live process parked in another task's working copy, the very occupancy the
# refusal guards against, and it would make every later spawn read the slot as
# occupied by somebody.
test_refused_slot_keeps_no_process_of_ours() {
  local rec id out status pid
  id=pool-refused-no-process-b1
  rec=$(make_case refused-no-process "$id")
  read_case_record "$rec"
  write_pool_status --spare available
  : > "$OTHER_HOME/state/neighbour-task.meta"
  claim_slot neighbour-task "$OTHER_HOME"
  export FM_FAKE_ENDPOINT_PID_FILE="$CASE_DIR/endpoint.pid"

  out=$(run_pool_spawn "$id")
  status=$?
  unset FM_FAKE_ENDPOINT_PID_FILE
  expect_code "$POOL_BAD_SLOT_EXIT" "$status" \
    "a slot another live task holds must be refused as a bad slot"$'\n'"$out"
  [ -s "$CASE_DIR/endpoint.pid" ] || fail "the endpoint's shell never entered the slot"
  pid=$(cat "$CASE_DIR/endpoint.pid")
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    fail "the refused spawn left its shell (pid $pid) running in $SLOT_DIR"
  fi
  assert_contains "$out" "when it has none this is exhaustion" \
    "the refusal still promised that asking again is always safe"
  pass "a refused slot keeps no process of the refusing spawn in it"
}

# When the refused slot is the only one the pool can offer, asking again would
# be handed that same slot, so the refusal is exhaustion rather than a bad slot.
test_refused_only_slot_reports_exhaustion() {
  local rec id out status
  id=pool-refused-only-slot-b2
  rec=$(make_case refused-only-slot "$id")
  read_case_record "$rec"
  write_pool_status in-use
  : > "$OTHER_HOME/state/neighbour-task.meta"
  claim_slot neighbour-task "$OTHER_HOME"

  out=$(run_pool_spawn "$id")
  status=$?
  expect_code "$POOL_EXHAUSTED_EXIT" "$status" \
    "a refused slot that was the pool's only one to offer is exhaustion"$'\n'"$out"
  assert_contains "$out" "is exhausted" \
    "the refusal did not say the pool was exhausted"
  assert_contains "$out" "neighbour-task" \
    "the refusal did not name the task that holds the only slot"
  assert_not_launched "$id" "the pool's only slot"
  pass "refusing the pool's only available slot reports exhaustion"
}

# An available slot another live task holds is no more grantable than the one
# just refused, so it must not turn exhaustion into "ask for another slot".
test_refusal_with_only_held_slots_left_reports_exhaustion() {
  local rec id out status
  id=pool-only-held-left-c1
  rec=$(make_case only-held-left "$id")
  read_case_record "$rec"
  write_pool_status --spare available
  : > "$OTHER_HOME/state/neighbour-task.meta"
  : > "$OTHER_HOME/state/neighbour-two.meta"
  claim_slot neighbour-task "$OTHER_HOME"
  printf 'task=neighbour-two\nhome=%s\n' "$OTHER_HOME" > "$CASE_DIR/pool/2/.fm-slot-owner"

  out=$(run_pool_spawn "$id")
  status=$?
  expect_code "$POOL_EXHAUSTED_EXIT" "$status" \
    "a refusal whose only other available slot is also held is exhaustion"$'\n'"$out"
  assert_contains "$out" "is exhausted" \
    "the refusal did not say the pool was exhausted"
  assert_not_launched "$id" "a pool of held slots"
  pass "a refusal with only other tasks' held slots left reports exhaustion"
}

# Task ids are unique only within one home, and homes share one pool: another
# home's live task with this very id still holds its slot.
test_same_task_id_from_another_home_is_refused() {
  local rec id out status
  id=pool-same-id-b3
  rec=$(make_case same-id-other-home "$id")
  read_case_record "$rec"
  write_pool_status --spare available
  : > "$OTHER_HOME/state/$id.meta"
  claim_slot "$id" "$OTHER_HOME"

  out=$(run_pool_spawn "$id")
  status=$?
  expect_code "$POOL_BAD_SLOT_EXIT" "$status" \
    "another home's live task with the same id must not be read as this task"$'\n'"$out"
  assert_contains "$out" "$OTHER_HOME" \
    "the refusal did not name the claim's home"
  assert_contains "$out" "$(CDPATH='' cd -- "$HOME_DIR" && pwd -P)" \
    "the refusal did not name this home"
  assert_not_launched "$id" "another home's slot"
  assert_grep "home=$OTHER_HOME" "$(dirname "$SLOT_DIR")/.fm-slot-owner" \
    "the refused spawn overwrote the other home's claim"
  pass "a same-id claim from another home is refused rather than taken as this task's"
}

# An exhausted pool and a slot that never arrived used to be one refusal. They
# need opposite responses, so the caller must be able to tell them apart.
test_exhausted_pool_reports_exhaustion() {
  local rec id out status
  id=pool-exhausted-a6
  rec=$(make_case exhausted "$id")
  read_case_record "$rec"
  set_max_trees 1
  write_pool_status in-use
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_pool_spawn "$id" "$PROJECT_DIR")
  status=$?
  expect_code "$POOL_EXHAUSTED_EXIT" "$status" \
    "an exhausted pool must report exhaustion with its own exit code"$'\n'"$out"
  assert_contains "$out" "is exhausted" \
    "the refusal did not say the pool was exhausted"
  assert_contains "$out" "retrying now cannot succeed" \
    "the refusal did not tell the caller that asking again cannot help"
  assert_not_launched "$id" "an exhausted pool"
  pass "an exhausted pool reports exhaustion rather than a generic refused spawn"
}

# The same deadline with a slot still available is NOT exhaustion, so it keeps
# the generic refusal and its ordinary exit code.
test_free_slot_deadline_is_not_reported_as_exhaustion() {
  local rec id out status
  id=pool-not-exhausted-a7
  rec=$(make_case not-exhausted "$id")
  read_case_record "$rec"
  write_pool_status available
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_pool_spawn "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" \
    "a deadline reached while the pool still had a free slot is not exhaustion"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "the refusal lost the reason the worktree never arrived"
  assert_not_contains "$out" "is exhausted" \
    "a pool with a free slot was wrongly reported as exhausted"
  assert_not_launched "$id" "a worktree that never arrived"
  pass "a pool with a free slot is not misreported as exhausted"
}

# Nothing available is not exhaustion on its own: where the pane's path never
# follows `treehouse get`, the slot Treehouse just created reads in-use under
# this spawn's own shell. Below max_trees the pool may still create slots.
test_deadline_below_the_pool_limit_is_not_exhaustion() {
  local rec id out status
  id=pool-below-limit-b4
  rec=$(make_case below-limit "$id")
  read_case_record "$rec"
  set_max_trees 10
  write_pool_status in-use
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_pool_spawn "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" \
    "a deadline reached below max_trees is not exhaustion"$'\n'"$out"
  assert_not_contains "$out" "is exhausted" \
    "a pool below its size limit was wrongly reported as exhausted"
  assert_not_launched "$id" "a worktree that never arrived"
  pass "a pool below its size limit is not misreported as exhausted"
}

# At max_trees with nothing available, a slot holding a process younger than
# this spawn is this spawn's own allocation: the pool gave it a slot and the
# pane's path never showed where, which is not exhaustion.
test_deadline_with_our_own_new_slot_is_not_exhaustion() {
  local rec id out status
  id=pool-own-new-slot-c2
  rec=$(make_case own-new-slot "$id")
  read_case_record "$rec"
  set_max_trees 1
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  export FM_FAKE_TREEHOUSE_LIVE_PID_SLOT="$SLOT_DIR" FM_FAKE_TREEHOUSE_LIVE_PID_STATUS=in-use

  out=$(run_pool_spawn "$id" "$PROJECT_DIR")
  status=$?
  unset FM_FAKE_TREEHOUSE_LIVE_PID_SLOT FM_FAKE_TREEHOUSE_LIVE_PID_STATUS
  expect_code 1 "$status" \
    "a deadline whose pool holds this spawn's own new slot is not exhaustion"$'\n'"$out"
  assert_not_contains "$out" "is exhausted" \
    "the spawn's own allocation was misreported as an exhausted pool"
  assert_not_launched "$id" "a worktree that never arrived"
  pass "a pool at its limit only because of this spawn's own slot is not exhausted"
}

test_slot_held_by_a_live_task_is_refused
test_refused_slot_keeps_no_process_of_ours
test_refused_only_slot_reports_exhaustion
test_same_task_id_from_another_home_is_refused
test_refusal_with_only_held_slots_left_reports_exhaustion
test_orphan_claim_is_replaced
test_claim_whose_home_is_absent_is_refused
test_slot_holding_a_stray_process_is_refused
test_slot_holding_an_unreadable_process_is_refused
test_slot_holding_only_our_own_process_is_accepted
test_exhausted_pool_reports_exhaustion
test_free_slot_deadline_is_not_reported_as_exhaustion
test_deadline_below_the_pool_limit_is_not_exhaustion
test_deadline_with_our_own_new_slot_is_not_exhaustion

echo "# all fm-spawn-pool-slot-occupancy tests passed"
