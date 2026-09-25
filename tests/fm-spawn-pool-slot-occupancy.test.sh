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
# for a slot this home must not use, where asking again usually can.
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
    sleep 60 >/dev/null 2>&1 &
    printf '[{"name":"1","path":"%s","status":"available","processes":[{"pid":%s,"name":"ours"}]}]\n' \
      "$FM_FAKE_TREEHOUSE_LIVE_PID_SLOT" "$!"
    exit 0
  fi
  cat "${FM_FAKE_TREEHOUSE_STATUS:-/dev/null}"
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
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

# write_pool_status <status> [pid...] publishes the pool scan the stub replays:
# one slot, in the given state, holding the given pids.
write_pool_status() {
  local state=$1 procs='' pid
  shift
  for pid in "$@"; do
    procs="$procs{\"pid\":$pid,\"name\":\"stray\"},"
  done
  procs=${procs%,}
  cat > "$CASE_DIR/pool-status.json" <<JSON
[{"name":"1","path":"$SLOT_DIR","status":"$state","processes":[$procs]}]
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
  write_pool_status available
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
  write_pool_status available
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
  write_pool_status available 1

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
  write_pool_status available 2147483646

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

# An exhausted pool and a slot that never arrived used to be one refusal. They
# need opposite responses, so the caller must be able to tell them apart.
test_exhausted_pool_reports_exhaustion() {
  local rec id out status
  id=pool-exhausted-a6
  rec=$(make_case exhausted "$id")
  read_case_record "$rec"
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

test_slot_held_by_a_live_task_is_refused
test_orphan_claim_is_replaced
test_claim_whose_home_is_absent_is_refused
test_slot_holding_a_stray_process_is_refused
test_slot_holding_an_unreadable_process_is_refused
test_slot_holding_only_our_own_process_is_accepted
test_exhausted_pool_reports_exhaustion
test_free_slot_deadline_is_not_reported_as_exhaustion

echo "# all fm-spawn-pool-slot-occupancy tests passed"
