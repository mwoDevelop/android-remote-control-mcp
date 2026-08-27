#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PACKAGE_ID="com.danielealbano.androidremotecontrolmcp.gms.debug"
ARTIFACT="$REPO_ROOT/app/build/outputs/apk/gms/debug/app-gms-debug.apk"
SECRETS_FILE="$REPO_ROOT/myconf/[REDACTED_DEVICE_ALIAS]/.env.secrets"
SERIAL=""
APPLY=false

usage() {
  printf '%s\n' \
    'Usage: scripts/deploy-[REDACTED_DEVICE_ALIAS]-debug-poc.sh --serial <adb-serial> [--artifact <apk>] [--apply]' \
    '' \
    'Without --apply this is a non-mutating preview. The POC is installed beside production,' \
    'binds only to 127.0.0.1:8081, disables OAuth/tunnels and reuses the local administrator' \
    'bearer from ignored myconf/[REDACTED_DEVICE_ALIAS]/.env.secrets. It never grants Shizuku permission.'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --serial) (($# >= 2)) || die '--serial requires a value'; SERIAL="$2"; shift 2 ;;
    --artifact) (($# >= 2)) || die '--artifact requires a value'; ARTIFACT="$2"; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$SERIAL" ]] || die '--serial is required; automatic device selection is prohibited'

if [[ "$APPLY" == false ]]; then
  printf 'PREVIEW: validate [REDACTED_DEVICE_ALIAS] identity and debug APK, install %s beside production, configure loopback 8081, start it, create adb forward and verify its listener.\n' "$PACKAGE_ID"
  exit 0
fi

resolve_android_tool() {
  local name="$1" found=""
  if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return; fi
  if [[ -n "${ANDROID_HOME:-}" ]]; then
    found="$(find "$ANDROID_HOME" -type f -name "$name" -perm -u+x 2>/dev/null | sort -V | tail -1)"
  fi
  [[ -n "$found" ]] || die "Cannot find $name; add it to PATH or set ANDROID_HOME"
  printf '%s' "$found"
}

ADB_BIN="$(resolve_android_tool adb)"
AAPT_BIN="$(resolve_android_tool aapt)"
[[ -r "$ARTIFACT" ]] || die "Debug APK is unavailable: $ARTIFACT"
[[ -r "$SECRETS_FILE" ]] || die "Secrets file is unavailable: $SECRETS_FILE"
[[ "$(stat -c '%a' "$SECRETS_FILE")" == 600 ]] || die '[REDACTED_DEVICE_ALIAS] secrets file must have mode 0600'

# shellcheck disable=SC1090
source "$SECRETS_FILE"
[[ -n "${ANDROID_MCP_BEARER_TOKEN:-}" ]] || die 'ANDROID_MCP_BEARER_TOKEN is empty'

ADB=("$ADB_BIN" -s "$SERIAL")
[[ "$("${ADB[@]}" shell getprop ro.product.manufacturer | tr -d '\r' | tr '[:upper:]' '[:lower:]')" == samsung ]] || die 'Target manufacturer is not Samsung'
[[ "$("${ADB[@]}" shell getprop ro.product.model | tr -d '\r')" == [REDACTED_OWNER_VALUE] ]] || die 'Target model is not [REDACTED_OWNER_VALUE]'
[[ "$("${ADB[@]}" shell getprop ro.product.device | tr -d '\r')" == a34x ]] || die 'Target device codename is not a34x'

candidate_package="$("$AAPT_BIN" dump badging "$ARTIFACT" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -1)"
[[ "$candidate_package" == "$PACKAGE_ID" ]] || die "APK application ID is not $PACKAGE_ID"

"${ADB[@]}" install -r "$ARTIFACT"
[[ "$("${ADB[@]}" shell pm path "$PACKAGE_ID" | tr -d '\r')" == package:* ]] || die 'Debug package is absent after install'

receiver="$PACKAGE_ID/com.danielealbano.androidremotecontrolmcp.debug.E2EConfigReceiver"
"${ADB[@]}" shell am broadcast \
  -a com.danielealbano.androidremotecontrolmcp.debug.E2E_CONFIGURE \
  -n "$receiver" \
  --es bearer_token "$ANDROID_MCP_BEARER_TOKEN" \
  --ez bearer_token_enabled true \
  --ez oauth_enabled false \
  --es binding_address 127.0.0.1 \
  --ei port 8081 \
  --ez auto_start_on_boot true \
  --ez hide_from_recents false >/dev/null
"${ADB[@]}" shell am broadcast \
  -a com.danielealbano.androidremotecontrolmcp.debug.E2E_START_SERVER \
  -n "$receiver" >/dev/null

"$ADB_BIN" -s "$SERIAL" forward tcp:8081 tcp:8081 >/dev/null
listeners=""
for _ in {1..30}; do
  listeners="$("${ADB[@]}" shell ss -ltn 2>/dev/null | tr -d '\r' || true)"
  if grep -Eq '(\[::ffff:)?127\.0\.0\.1\]?:8081([[:space:]]|$)' <<<"$listeners"; then
    break
  fi
  sleep 0.5
done
grep -Eq '(\[::ffff:)?127\.0\.0\.1\]?:8081([[:space:]]|$)' <<<"$listeners" || \
  die 'POC server is not listening on loopback port 8081'
[[ "$listeners" != *'0.0.0.0:8081'* && "$listeners" != *'[::]:8081'* ]] || die 'POC server is exposed beyond loopback'

shizuku_processes="$("${ADB[@]}" shell ps -A | tr -d '\r')"
if [[ "$("${ADB[@]}" shell pm path moe.shizuku.privileged.api | tr -d '\r')" != package:* ]]; then
  printf 'MANUAL_GATE: Shizuku is not installed for Android user 0.\n' >&2
elif ! grep -q '[s]hizuku' <<<"$shizuku_processes"; then
  printf 'MANUAL_GATE: Shizuku is installed but its service is not running.\n' >&2
else
  printf 'Shizuku package and running process detected; use admin_request_shizuku_permission for the visible grant.\n'
fi

printf '[REDACTED_DEVICE_ALIAS] debug POC is running at host-forwarded http://127.0.0.1:8081/mcp; production was not replaced.\n'
