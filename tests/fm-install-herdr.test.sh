#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for `bin/fm-install-herdr.sh --print-pin`.
#
# The installer is the single owner of the exact Herdr version and the protocol
# floor the required real-Herdr lane gates on, and `.github/workflows/ci.yml`
# reads both from `--print-pin` instead of restating them. That makes the mode's
# stdout a consumed contract, so this suite drives the script's executable
# interface only and asserts what a caller can observe: the exact key set, a
# version in the dotted release shape its consumer extracts, a protocol floor
# that is a positive integer, and the offline promise that the mode downloads
# nothing and writes nowhere. The download and install path is not exercised
# here; it needs the network and a real release asset, and the required lane is
# its evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-install-herdr)
INSTALLER="$ROOT/bin/fm-install-herdr.sh"

# A PATH front where every transfer and install primitive the download path uses
# records its own invocation and then fails. --print-pin has to return before any
# of them, so an absent log is positive evidence the mode stayed offline rather
# than a mere absence of proof.
STUB_BIN="$TMP_ROOT/stub-bin"
INVOKED="$TMP_ROOT/invoked"
mkdir -p "$STUB_BIN"
for stub in curl wget sha256sum shasum install; do
  cat > "$STUB_BIN/$stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$stub" >> "$INVOKED"
exit 1
EOF
  chmod +x "$STUB_BIN/$stub"
done

# Two directories the mode must leave untouched: the working directory it runs
# in, and the temp base it would carve its download directory out of.
SANDBOX="$TMP_ROOT/cwd"
SCRATCH_TMP="$TMP_ROOT/scratch-tmp"
mkdir -p "$SANDBOX" "$SCRATCH_TMP"

OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"
STATUS=""

run_installer() {
  (
    cd "$SANDBOX" || exit 127
    PATH="$STUB_BIN:$PATH" TMPDIR="$SCRATCH_TMP" RUNNER_TEMP='' "$INSTALLER" "$@"
  ) >"$OUT" 2>"$ERR"
  STATUS=$?
}

dir_is_empty() {
  [ -z "$(ls -A "$1" 2>/dev/null)" ]
}

test_print_pin_exits_zero_with_exactly_the_two_keys() {
  local keys
  run_installer --print-pin
  [ "$STATUS" -eq 0 ] || fail "--print-pin exited $STATUS: $(cat "$ERR")"
  [ ! -s "$ERR" ] || fail "--print-pin wrote to stderr: $(cat "$ERR")"
  keys=$(cut -d= -f1 <"$OUT")
  [ "$keys" = "version
min_protocol" ] || fail "--print-pin printed keys '$keys', expected exactly version then min_protocol"
  pass "--print-pin exits 0 and prints exactly the version and min_protocol keys"
}

test_pin_values_are_usable_by_the_ci_consumer() {
  local version protocol
  run_installer --print-pin
  [ "$STATUS" -eq 0 ] || fail "--print-pin exited $STATUS: $(cat "$ERR")"
  # The same extraction the CI step performs on this output.
  version=$(sed -n 's/^version=//p' <"$OUT")
  protocol=$(sed -n 's/^min_protocol=//p' <"$OUT")
  [ -n "$version" ] || fail "--print-pin printed an empty version"
  case "$version" in
    [0-9]*.[0-9]*) : ;;
    *) fail "--print-pin printed version '$version', expected a dotted release" ;;
  esac
  case "$protocol" in
    ''|*[!0-9]*) fail "--print-pin printed min_protocol '$protocol', expected a positive integer" ;;
  esac
  [ "$protocol" -gt 0 ] || fail "--print-pin printed min_protocol '$protocol', expected it above zero"
  pass "--print-pin prints a dotted release version and a positive integer protocol floor"
}

test_print_pin_downloads_nothing_and_writes_nowhere() {
  run_installer --print-pin
  [ "$STATUS" -eq 0 ] || fail "--print-pin exited $STATUS: $(cat "$ERR")"
  [ ! -e "$INVOKED" ] || fail "--print-pin invoked $(tr '\n' ' ' <"$INVOKED")"
  dir_is_empty "$SANDBOX" || fail "--print-pin wrote into its working directory: $(ls -A "$SANDBOX")"
  dir_is_empty "$SCRATCH_TMP" || fail "--print-pin created a temp directory: $(ls -A "$SCRATCH_TMP")"
  pass "--print-pin is offline: no transfer, no install, no destination or temp directory"
}

test_missing_argument_still_fails_with_usage() {
  run_installer
  [ "$STATUS" -ne 0 ] || fail "the installer accepted a missing destination"
  grep -q 'usage' "$ERR" || fail "a missing destination printed no usage: $(cat "$ERR")"
  grep -q -- '--print-pin' "$ERR" || fail "the usage text omits --print-pin: $(cat "$ERR")"
  [ ! -e "$INVOKED" ] || fail "a missing destination still invoked $(tr '\n' ' ' <"$INVOKED")"
  dir_is_empty "$SCRATCH_TMP" || fail "a missing destination created a temp directory"
  pass "a missing destination fails with a usage that names --print-pin, before any transfer"
}

test_print_pin_exits_zero_with_exactly_the_two_keys
test_pin_values_are_usable_by_the_ci_consumer
test_print_pin_downloads_nothing_and_writes_nowhere
test_missing_argument_still_fails_with_usage
