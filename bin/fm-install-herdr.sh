#!/usr/bin/env bash
# fm-install-herdr.sh - install CI's pinned, verified Herdr build.
#
# Single owner of the exact Herdr version, official release asset URL, and
# SHA-256 pin used by the required real-Herdr CI lane. Never installs a
# floating package-manager latest.
#
# Usage:
#   fm-install-herdr.sh <destination-directory>
#   fm-install-herdr.sh --print-pin
#
# Pins Herdr v0.9.0 (protocol 22), the suite-verified release.
# Selects the official GitHub Releases asset for the host OS/arch, downloads
# with a bounded max size, verifies SHA-256 before install, then refuses to
# finish unless the binary reports the exact pin version and a client protocol
# at or above the required floor (22 for the real-Herdr family).
#
# `--print-pin` prints the pinned version and protocol floor as shell-safe
# `key=value` lines without downloading or installing anything, so a caller
# that must assert the pin reads it from this owner instead of restating it.
set -eu

# Exact pin - change only with a re-verified real-Herdr matrix.
FM_HERDR_CI_VERSION=0.9.0
FM_HERDR_CI_TAG="v${FM_HERDR_CI_VERSION}"
FM_HERDR_CI_MIN_PROTOCOL=22
# Bounded download ceiling (bytes). The largest official 0.9.0 asset is the
# linux-x86_64 build at 24,644,488 bytes, so this bound clears every pinned
# asset. It is a runaway-transfer guard, not a size pin: the assets below are
# pinned by exact tag and SHA-256 and cannot grow without a re-pin, which
# revisits this constant alongside the checksums.
FM_HERDR_CI_MAX_BYTES=25000000
# Canonical repository after the GitHub organization migration announced in the
# 0.8.0 notes. The old ogulcancelik/herdr path still 301-redirects, but pin the
# name the project publishes under rather than depend on that redirect.
FM_HERDR_CI_REPO=herdrdev/herdr

die() {
  printf 'fm-install-herdr.sh: %s\n' "$*" >&2
  exit 1
}

if [ "${1:-}" = --print-pin ]; then
  printf 'version=%s\n' "$FM_HERDR_CI_VERSION"
  printf 'min_protocol=%s\n' "$FM_HERDR_CI_MIN_PROTOCOL"
  exit 0
fi

DESTINATION=${1:?usage: fm-install-herdr.sh <destination-directory> | --print-pin}

os=$(uname -s)
arch=$(uname -m)
case "${os}-${arch}" in
  Linux-x86_64)
    ASSET=herdr-linux-x86_64
    SHA256=4fa1a01158dd8043da92d31b270780b0dcc10603038d9b61cac4d81ab63fb71f
    ;;
  Linux-aarch64|Linux-arm64)
    ASSET=herdr-linux-aarch64
    SHA256=9c8db20fb7e7427b138d5367113f1621ffd319f2f65d6f009e2594029115f0d2
    ;;
  Darwin-arm64)
    ASSET=herdr-macos-aarch64
    SHA256=32b53df09872628059c789a69f02a6b8e29e14ddf26711421f3463f70c1aef17
    ;;
  Darwin-x86_64)
    ASSET=herdr-macos-x86_64
    SHA256=d0c920b2a126a74809fa1491411c9a097a44786cac9c2ca51b818a995581cf16
    ;;
  *)
    die "unsupported platform ${os}-${arch}; official Herdr assets are linux/macos x86_64 and aarch64"
    ;;
esac

URL="https://github.com/${FM_HERDR_CI_REPO}/releases/download/${FM_HERDR_CI_TAG}/${ASSET}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-herdr.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

printf 'fm-install-herdr.sh: downloading %s from %s\n' "$ASSET" "$URL" >&2
# --fail: HTTP errors; --location: follow redirects; --max-filesize: bound.
curl -fsSL --max-filesize "$FM_HERDR_CI_MAX_BYTES" "$URL" -o "$TMP/$ASSET" \
  || die "download failed for $URL (bounded at $FM_HERDR_CI_MAX_BYTES bytes)"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the Herdr asset"
fi

[ "$ACTUAL_SHA256" = "$SHA256" ] || die "checksum mismatch for $ASSET (expected $SHA256, got $ACTUAL_SHA256)"

mkdir -p "$DESTINATION"
install -m 0755 "$TMP/$ASSET" "$DESTINATION/herdr"

# Post-install version and protocol gates (no floating latest).
installed_version=$("$DESTINATION/herdr" --version 2>/dev/null | awk '{print $2; exit}')
[ "$installed_version" = "$FM_HERDR_CI_VERSION" ] \
  || die "installed herdr version is '${installed_version:-<empty>}', expected exact pin $FM_HERDR_CI_VERSION"

status=$("$DESTINATION/herdr" status --json 2>/dev/null) \
  || die "could not run 'herdr status --json' after install"
protocol=$(printf '%s' "$status" | jq -r '.client.protocol // empty' 2>/dev/null) \
  || die "jq is required to parse herdr status after install"
case "$protocol" in
  ''|*[!0-9]*) die "could not read herdr client protocol from status --json" ;;
esac
[ "$protocol" -ge "$FM_HERDR_CI_MIN_PROTOCOL" ] \
  || die "herdr protocol $protocol is below the required floor $FM_HERDR_CI_MIN_PROTOCOL"

printf 'fm-install-herdr.sh: installed herdr %s (protocol %s) to %s\n' \
  "$installed_version" "$protocol" "$DESTINATION/herdr" >&2
"$DESTINATION/herdr" --version
