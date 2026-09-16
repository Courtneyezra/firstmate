#!/usr/bin/env bash
# tests/fm-bearings-board-lavish-live-e2e.test.sh - live drift guard proving
# the real lavish-axi still behaves the way bin/fm-bearings-board.sh's session
# liveness check is written against.
#
# Why this file exists: the build's "is this board actually live" verdict comes
# from what lavish-axi emits, which is a surface the vendor controls and changes
# without notice. The defect this guards was exactly that - opening a session
# the captain had ended from the browser EXITS 0 while refusing to reopen, so a
# build that trusted the exit status armed a poll against a dead session and the
# board read "not listening" with nobody watching it. A stubbed lavish-axi can
# only confirm the assumption already written into the stub, so the assumption
# itself needs a run against the real tool.
#
# The captain-ended state is reached through the same server route the browser's
# End session button calls, so no browser is needed and nothing here depends on
# a human. The artifact is a scratch page in a temporary directory, and the
# session it opens is ended again before the guard returns.
#
# The second assumption under guard is this home's Lavish port: two logins on
# one machine contend for one vendor-default port, so the board build resolves
# a port of its own and that only works while lavish-axi still honors it.
#
# Both sections run on a free port and a state directory of their own, stopping
# each server they start. That is what keeps this guard off every server the
# machine's real homes are using - and what keeps its verdict from depending on
# who else happens to hold a port right now, which is the condition the guarded
# behavior exists for in the first place.
#
# Standard CI has no lavish-axi, so this reports a capability skip there. The
# portable counterpart in tests/fm-bearings-board.test.sh pins the build's logic
# in CI against a stub that reproduces these shapes. Run this guard after a
# lavish-axi upgrade and before trusting refreshed evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate default-on FM_BEARINGS_LAVISH_LIVE lavish-axi jq curl

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

LAB=''
LAB_PORT=''
PORT_LAB=''
PORT_PINNED=''
cleanup() {
  [ -z "$LAB" ] || {
    # End the session first so the board's own armed listener returns and exits,
    # then stop the isolated server this guard started.
    [ ! -f "$LAB/.lavish/bearings-board.html" ] \
      || lavish-axi end "$LAB/.lavish/bearings-board.html" >/dev/null 2>&1 || true
    [ -z "${LAB_PORT:-}" ] || lavish-axi stop >/dev/null 2>&1 || true
    rm -rf "$LAB"
  }
  [ -z "$PORT_LAB" ] || {
    # End the session first so the board's own armed listener returns and exits,
    # then stop the isolated server this section started.
    [ -z "$PORT_PINNED" ] || {
      [ ! -f "$PORT_LAB/.lavish/bearings-board.html" ] \
        || LAVISH_AXI_STATE_DIR="$PORT_LAB/lavish-state" LAVISH_AXI_PORT="$PORT_PINNED" \
          lavish-axi end "$PORT_LAB/.lavish/bearings-board.html" >/dev/null 2>&1 || true
      LAVISH_AXI_STATE_DIR="$PORT_LAB/lavish-state" LAVISH_AXI_PORT="$PORT_PINNED" \
        lavish-axi stop >/dev/null 2>&1 || true
    }
    rm -rf "$PORT_LAB"
  }
}
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
trap cleanup EXIT

VERSION=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
note "lavish-axi ${VERSION:-version-unknown}"

# A port nothing holds right now. The vendor keys one server per port, so this
# is half of what keeps the guard's server to itself; its own state directory is
# the other half.
free_port() {
  perl -MIO::Socket::INET -e '
    my $s = IO::Socket::INET->new(Listen => 1, LocalAddr => "127.0.0.1", LocalPort => 0)
      or exit 1;
    print $s->sockport, "\n";
  '
}

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-bearings-lavish-live.XXXXXX") || fail "cannot create the guard lab"
LAB=$(cd -P -- "$LAB" && pwd -P)
mkdir -p "$LAB/state" "$LAB/data" "$LAB/lavish-state"
LAB_PORT=$(free_port) || fail "could not find a free port for the guard server"
export LAVISH_AXI_STATE_DIR="$LAB/lavish-state" LAVISH_AXI_PORT="$LAB_PORT"

cat > "$LAB/payload.json" <<'JSON'
{
  "schema": "fm-bearings-board.v1",
  "home": "lavish-live-guard",
  "generated": "2026-01-01T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "sample-live-guard-call",
      "type": "decision",
      "repo": "sample",
      "title": "Guard placeholder",
      "options": [{ "value": "yes", "label": "Yes" }]
    }
  ],
  "underway": [],
  "landed": [],
  "charted": []
}
JSON

run_board() {
  FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_DATA_OVERRIDE="$LAB/data" \
    FM_PROCEVENT_CLAIM_ROOT="$LAB/procevent-claims" \
    "$ROOT/bin/fm-bearings-board.sh" "$@"
}

BOARD="$LAB/.lavish/bearings-board.html"
run_board build "$LAB/payload.json" >/dev/null 2>&1 || fail "the guard board did not build"
[ -f "$BOARD" ] || fail "the guard board was not published"

url=$(lavish-axi "$BOARD" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"')
case "$url" in
  http://*/session/*) ;;
  *) fail "could not read the guard board session url: $url" ;;
esac
key=${url##*/}
base=${url%/session/*}

# End it exactly as the browser's End session button does.
curl -fsS -X POST "$base/api/$key/end" >/dev/null 2>&1 \
  || fail "could not end the guard board session as the captain"

# ASSUMPTION UNDER GUARD: this exits 0 while reporting the session is not live.
set +e
ended_out=$(lavish-axi "$BOARD" 2>&1)
ended_rc=$?
set -e
[ "$ended_rc" -eq 0 ] \
  || fail "lavish-axi ${VERSION:-version-unknown} now exits $ended_rc on a captain-ended session; the board build's liveness check must be revisited"
ended_status=$(printf '%s\n' "$ended_out" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"')
[ "$ended_status" != opened ] \
  || fail "lavish-axi ${VERSION:-version-unknown} silently reopened a captain-ended session; the board build's liveness check must be revisited"
lavish-axi 2>/dev/null | grep -F "$BOARD," | grep -q ',open,' \
  && fail "lavish-axi ${VERSION:-version-unknown} still lists a captain-ended session as open; the board build's liveness check must be revisited"
pass "lavish-axi ${VERSION:-version-unknown} reports a captain-ended session without reopening it and without failing"

# THE BEHAVIOR UNDER GUARD: the build must not accept that, and must recover.
out=$(run_board build "$LAB/payload.json" 2>&1) \
  || fail "the board build refused a recoverable captain-ended session: $out"
case "$out" in
  *"session: reopened"*) ;;
  *) fail "the board build did not reopen the captain-ended session: $out" ;;
esac
lavish-axi 2>/dev/null | grep -F "$BOARD," | grep -q ',open,' \
  || fail "the board build reported success while the session was still not live"
pass "the board build reopens a captain-ended session against real lavish-axi instead of arming a dead one"

# --- this home's own Lavish port ----------------------------------------------
# ASSUMPTION UNDER GUARD: a resolved port actually moves the server the board is
# served from. Everything that keeps two logins on one machine apart rests on
# that, and it is a vendor behavior, so a stub cannot prove it.
#
# Isolated on both axes the vendor keys a server by: its own free port and its
# own state directory. Nothing this section starts can reach, rewrite, or stop
# the server this machine's real homes are using.
PORT_PINNED=$(free_port) || fail "could not find a free port for the Lavish port guard"

PORT_LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-bearings-lavish-port.XXXXXX") || fail "cannot create the port guard lab"
PORT_LAB=$(cd -P -- "$PORT_LAB" && pwd -P)
mkdir -p "$PORT_LAB/state" "$PORT_LAB/data" "$PORT_LAB/config" "$PORT_LAB/lavish-state"
printf '%s\n' "$PORT_PINNED" > "$PORT_LAB/config/lavish-port"
cp "$LAB/payload.json" "$PORT_LAB/payload.json"

# No ambient port here: the build must reach the pinned one through its own
# home's configuration, which is the path a restarted home actually takes.
PORT_BOARD="$PORT_LAB/.lavish/bearings-board.html"
env -u LAVISH_AXI_PORT LAVISH_AXI_STATE_DIR="$PORT_LAB/lavish-state" \
  FM_HOME="$PORT_LAB" FM_STATE_OVERRIDE="$PORT_LAB/state" FM_DATA_OVERRIDE="$PORT_LAB/data" \
  FM_PROCEVENT_CLAIM_ROOT="$PORT_LAB/procevent-claims" \
  "$ROOT/bin/fm-bearings-board.sh" build "$PORT_LAB/payload.json" >/dev/null 2>&1 \
  || fail "the board build could not raise a session on the port this home pinned ($PORT_PINNED)"

port_url=$(LAVISH_AXI_STATE_DIR="$PORT_LAB/lavish-state" LAVISH_AXI_PORT="$PORT_PINNED" \
  lavish-axi "$PORT_BOARD" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"')
case "$port_url" in
  *":$PORT_PINNED/session/"*) ;;
  *) fail "lavish-axi ${VERSION:-version-unknown} did not serve the board on the port this home resolved ($PORT_PINNED): $port_url" ;;
esac
pass "lavish-axi ${VERSION:-version-unknown} serves a board on the port this home resolved"
