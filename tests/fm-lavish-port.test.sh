#!/usr/bin/env bash
# Behavior tests for this home's Lavish port: how bin/fm-lavish-lib.sh resolves
# it, and - the part the incident turned on - that a listener the supervision
# cycle relaunches later still reaches the same server.
#
# The relaunch case is the whole point. A registered Lavish listener is executed
# from whatever environment the watcher carries, so a fix that only works while
# an operator happens to export LAVISH_AXI_PORT by hand is not a fix. These
# cases therefore run the published poll command with a HOSTILE environment -
# no home, or a different port exported - and assert what lavish-axi was
# actually invoked with.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-lavish-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-lavish-lib.sh"

POLL="$ROOT/bin/fm-procevent-lavish.sh"
TMP_ROOT=$(fm_test_tmproot fm-lavish-port)

# A lavish-axi stub that records the port it was invoked with and returns an
# ended session at once, so no case here blocks on a real long poll.
make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/config" "$home/state"
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "${LAVISH_AXI_PORT-unset}" >> "${LAVISH_PORT_LOG:?}"
case "${1-}" in
  --version) printf '0.1.67\n' ;;
  poll) printf 'session:\n  status: ended\n' ;;
  *) printf 'session:\n  status: opened\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

H=$(make_home home-a)
export LAVISH_PORT_LOG="$H/port.log"
: > "$LAVISH_PORT_LOG"

# --- resolution ---------------------------------------------------------------

UID_NOW=$(id -u)
DERIVED=$(FM_HOME="$H" LAVISH_AXI_PORT='' fm_lavish_port) \
  || fail "the derived port could not be resolved"
assert_equals "$((FM_LAVISH_PORT_BASE + UID_NOW % FM_LAVISH_PORT_SPAN))" "$DERIVED" \
  "the derived port is this login's own slot"
assert_equals "$DERIVED" "$(FM_HOME="$H" LAVISH_AXI_PORT='' fm_lavish_port)" \
  "the derived port is the same on a later call, so a board URL keeps its port"

# Two logins on one machine are what collided, so the derivation must separate
# them. Proven by deriving the mapping for a second uid rather than by becoming
# another user, which a test cannot do.
assert_not_equals \
  "$((FM_LAVISH_PORT_BASE + UID_NOW % FM_LAVISH_PORT_SPAN))" \
  "$((FM_LAVISH_PORT_BASE + (UID_NOW + 1) % FM_LAVISH_PORT_SPAN))" \
  "two neighbouring logins derive different ports"
pass "the port derives per login and stays put across calls"

printf '4599\n' > "$H/config/lavish-port"
assert_equals 4599 "$(FM_HOME="$H" LAVISH_AXI_PORT='' fm_lavish_port)" \
  "a pinned port is honored"
assert_equals 4601 "$(FM_HOME="$H" LAVISH_AXI_PORT=4601 fm_lavish_port)" \
  "an explicit ambient port outranks the pin"

for bad in nonsense 80 99999 '4387 4388' '' '04387'; do
  printf '%s\n' "$bad" > "$H/config/lavish-port"
  if out=$(FM_HOME="$H" LAVISH_AXI_PORT='' fm_lavish_port 2>&1); then
    fail "a malformed pin ('$bad') resolved to $out instead of refusing"
  fi
  assert_contains "$out" "lavish-port must hold one port" \
    "a malformed pin ('$bad') names the file it came from"
done
if out=$(FM_HOME="$H" LAVISH_AXI_PORT=hello fm_lavish_port 2>&1); then
  fail "a malformed ambient port resolved to $out instead of refusing"
fi
assert_contains "$out" "LAVISH_AXI_PORT must be a port" \
  "a malformed ambient port is refused rather than silently defaulted"
pass "a pin is honored and a malformed port refuses instead of falling back"

rm -f "$H/config/lavish-port"

# --- the registered listener --------------------------------------------------
#
# Armed against a PINNED port, so the assertions below discriminate: the pin
# lives in this home's configuration, and the relaunch below runs with no home
# to read it from. Only a port the registration itself carries can survive that.

ART="$H/board.html"
printf '<html></html>\n' > "$ART"
printf '4599\n' > "$H/config/lavish-port"

: > "$LAVISH_PORT_LOG"
armed=$(PATH="$H/fakebin:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" \
  FM_PROCEVENT_CLAIM_ROOT="$H/procevent-claims" "$POLL" arm "$ART") \
  || fail "arming the Lavish source failed"
assert_contains "$armed" "port: 4599" "arm reports the port it published"

sid=$(PATH="$H/fakebin:$PATH" FM_HOME="$H" "$POLL" source-id "$ART")
registered=$(cat "$H/state/procevent/$sid.source" 2>/dev/null) \
  || fail "the registration for $sid is unreadable"
assert_contains "$registered" "--port" \
  "the registration carries the port rather than leaving it to the environment"
assert_contains "$registered" "4599" "the registration carries this home's port"
pass "arm publishes this home's port inside the registered listener command"

# The relaunch case: run the published listener command exactly as the runner
# would, from an environment that knows nothing about this home and exports a
# DIFFERENT port. The registered port must still be what lavish-axi sees.
: > "$LAVISH_PORT_LOG"
argv=()
while IFS= read -r line; do
  argv+=("$line")
done < <(sed -n '/^argv:$/,$p' "$H/state/procevent/$sid.source" | tail -n +2)
[ "${#argv[@]}" -ge 3 ] || fail "the stored listener argv is unreadable"
PATH="$H/fakebin:$PATH" \
  env -u FM_HOME -u FM_STATE_OVERRIDE LAVISH_AXI_PORT=4999 FM_ROOT_OVERRIDE="$ROOT" \
  "${argv[@]}" >/dev/null 2>&1 || fail "the registered listener command failed"
assert_equals 4599 "$(head -1 "$LAVISH_PORT_LOG")" \
  "a relaunched listener uses its registered port, not the ambient one"
pass "a relaunched listener reaches this home's server with no environment to help it"

PATH="$H/fakebin:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" \
  FM_PROCEVENT_CLAIM_ROOT="$H/procevent-claims" "$POLL" retire "$ART" >/dev/null \
  || fail "retiring the Lavish source failed"
rm -f "$H/config/lavish-port"

# A registration armed before the port travelled in the argv still exists in
# every home that armed one, so a poll with no --port must resolve the port the
# same way every other path does rather than falling back to the vendor default.
: > "$LAVISH_PORT_LOG"
PATH="$H/fakebin:$PATH" FM_HOME="$H" LAVISH_AXI_PORT='' "$POLL" poll "$ART" >/dev/null \
  || fail "a poll with no registered port failed"
assert_equals "$DERIVED" "$(head -1 "$LAVISH_PORT_LOG")" \
  "a poll with no registered port resolves this home's port"

: > "$LAVISH_PORT_LOG"
if out=$(PATH="$H/fakebin:$PATH" FM_HOME="$H" "$POLL" poll --port 42 "$ART" 2>&1); then
  fail "poll accepted a privileged port: $out"
fi
assert_contains "$out" "--port must be a port" "poll refuses a malformed registered port"
pass "a listener with no registered port still resolves this home's port"
