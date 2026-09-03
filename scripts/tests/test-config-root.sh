#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
FIXTURES="$TEST_DIR/fixtures/device-config"
tmp="$(mktemp -d)"
trap 'find "$tmp" -depth -delete' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_fail() { "$@" >/dev/null 2>&1 && fail "command unexpectedly passed: $*" || true; }

"$SCRIPT_DIR/verify-device-configs.sh" --config-root "$FIXTURES"
"$SCRIPT_DIR/verify-device-configs.sh" --config-root "$FIXTURES" --profile phone
ARCP_CONFIG_ROOT="$FIXTURES" "$SCRIPT_DIR/verify-device-configs.sh" --profile tv32
expect_fail env -u ARCP_CONFIG_ROOT "$SCRIPT_DIR/verify-device-configs.sh"
expect_fail "$SCRIPT_DIR/verify-device-configs.sh" --config-root relative
expect_fail "$SCRIPT_DIR/verify-device-configs.sh" --config-root "$FIXTURES" --profile '../phone'

cp -a "$FIXTURES/." "$tmp/"
node -e '
  const fs=require("fs"), p=process.argv[1], v=JSON.parse(fs.readFileSync(p));
  v.paths.apply="../../outside"; fs.writeFileSync(p,JSON.stringify(v));
' "$tmp/phone/profile.json"
expect_fail "$SCRIPT_DIR/verify-device-configs.sh" --config-root "$tmp" --profile phone

find "$tmp" -depth -delete
mkdir -p "$tmp/phone/android" "$tmp/phone/scripts"
cp "$FIXTURES/phone/profile.json" "$tmp/phone/profile.json"
cp "$FIXTURES/phone/android/config.json" "$tmp/phone/android/config.json"
cp "$FIXTURES/phone/scripts/verify.sh" "$tmp/phone/scripts/verify.sh"
ln -s "$FIXTURES/phone/android/apply-config.sh" "$tmp/phone/android/apply-config.sh"
expect_fail "$SCRIPT_DIR/verify-device-configs.sh" --config-root "$tmp" --profile phone

source "$SCRIPT_DIR/lib/arcp-config-root.sh"
unset ARCP_CONFIG_ROOT
expect_fail arcp_load_profile '' phone
ARCP_CONFIG_ROOT="$FIXTURES" arcp_load_profile '' phone
[[ "$ARCP_PROFILE_ROOT" == "$FIXTURES/phone" ]] || fail 'environment fallback resolved the wrong profile'
ARCP_CONFIG_ROOT="$tmp" arcp_load_profile "$FIXTURES" tv32
[[ "$ARCP_PROFILE_ROOT" == "$FIXTURES/tv32" ]] || fail 'explicit root did not take precedence'

printf 'OK: config-root precedence, fail-closed behavior, traversal and symlink rejection passed.\n'
