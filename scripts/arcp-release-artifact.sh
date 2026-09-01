#!/usr/bin/env bash
set -euo pipefail

umask 077
unset [REDACTED_DEVICE_ALIAS]_PIN [REDACTED_DEVICE_ALIAS]_PIN NGROK_AUTHTOKEN ANDROID_MCP_BEARER_TOKEN CLOUDFLARE_TUNNEL_TOKEN \
  RELEASE_KEYSTORE_BASE64 RELEASE_KEYSTORE_PASSWORD RELEASE_KEY_ALIAS RELEASE_KEY_PASSWORD

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PACKAGE_ID="com.danielealbano.androidremotecontrolmcp"
REPOSITORY="mwoDevelop/android-remote-control-mcp"
COMMAND="${1:-}"
shift || true
TAG=""
RELEASE_DIR=""
DEVICE=""
SERIAL=""
VARIANT="gmsRelease"
APPLY=false
TEMP_DIR=""
LEDGER_VERIFY=""

usage() {
  cat <<'EOF'
Usage:
  scripts/arcp-release-artifact.sh download --tag <immutable-tag> --dir <empty-dir> [--repo owner/repo]
  scripts/arcp-release-artifact.sh verify   --tag <immutable-tag> --dir <dir> [--repo owner/repo]
  scripts/arcp-release-artifact.sh deploy   --tag <immutable-tag> --dir <dir> --device [REDACTED_DEVICE_ALIAS] \
    [--serial <adb-serial>] [--variant gmsRelease|fossRelease] [--repo owner/repo] [--apply]

download always verifies the downloaded closed asset set. deploy is a preview unless --apply is present and never
uninstalls the package or clears application data.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command is unavailable: $1"; }

resolve_android_tool() {
  local name="$1" found=""
  if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return; fi
  if [[ -n "${ANDROID_HOME:-}" ]]; then
    found="$(find "$ANDROID_HOME" -type f -name "$name" -perm -u+x 2>/dev/null | sort -V | tail -1)"
  fi
  [[ -n "$found" ]] || die "Cannot find $name; add it to PATH or set ANDROID_HOME"
  printf '%s' "$found"
}

json_value() {
  node -e '
    const data=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const value=process.argv[2].split(".").reduce((v,k)=>v==null?undefined:v[k],data);
    if (value===undefined || value===null) process.exit(2); process.stdout.write(String(value));
  ' "$1" "$2"
}

single_signer() {
  local output
  output="$($APKSIGNER verify --verbose --print-certs "$1")" || die "APK signature verification failed"
  grep -Eq '^Verified using v(2|3|3\.1) scheme .*: true$' <<<"$output" || die "APK lacks a v2+ signature"
  mapfile -t digests < <(sed -n -E 's/^.*certificate SHA-256 digest:[[:space:]]*//p' <<<"$output" |
    tr '[:upper:]' '[:lower:]' | tr -d ':' | sort -u)
  ((${#digests[@]} == 1)) || die "APK must have exactly one signer"
  printf '%s' "${digests[0]}"
}

validate_payload() {
  local entries abi library
  entries="$(unzip -Z1 "$1")"
  for abi in arm64-v8a x86_64; do
    for library in libcloudflared.so libngrok_java.so; do
      grep -Fxq "lib/$abi/$library" <<<"$entries" || die "APK lacks lib/$abi/$library"
    done
  done
}

cleanup() {
  [[ -z "$TEMP_DIR" || ! -d "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
  [[ -z "$LEDGER_VERIFY" || ! -f "$LEDGER_VERIFY" ]] || rm -f -- "$LEDGER_VERIFY"
}
trap cleanup EXIT INT TERM

while (($#)); do
  case "$1" in
    --tag) (($# >= 2)) || die "$1 requires a value"; TAG="$2"; shift 2 ;;
    --dir) (($# >= 2)) || die "$1 requires a value"; RELEASE_DIR="$2"; shift 2 ;;
    --repo) (($# >= 2)) || die "$1 requires a value"; REPOSITORY="$2"; shift 2 ;;
    --device) (($# >= 2)) || die "$1 requires a value"; DEVICE="$2"; shift 2 ;;
    --serial) (($# >= 2)) || die "$1 requires a value"; SERIAL="$2"; shift 2 ;;
    --variant) (($# >= 2)) || die "$1 requires a value"; VARIANT="$2"; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "$COMMAND" == download || "$COMMAND" == verify || "$COMMAND" == deploy ]] || { usage; die "Unknown command"; }
[[ "$TAG" =~ ^arcp-(stable|edge)-[A-Za-z0-9._-]+-vc[0-9]+$ ]] || die "Expected an immutable ARCP tag"
[[ -n "$RELEASE_DIR" ]] || die "--dir is required"
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "Invalid repository"
[[ "$VARIANT" == gmsRelease || "$VARIANT" == fossRelease ]] || die "Invalid variant"
if [[ "$COMMAND" != deploy ]]; then
  [[ -z "$DEVICE" && -z "$SERIAL" && "$APPLY" == false && "$VARIANT" == gmsRelease ]] ||
    die "Device options belong only to deploy"
else
  [[ "$DEVICE" == [REDACTED_DEVICE_ALIAS] ]] || die "This promotion path currently accepts only --device [REDACTED_DEVICE_ALIAS]"
fi

require_command gh
require_command git
require_command node
require_command sha256sum
require_command unzip
APKSIGNER="$(resolve_android_tool apksigner)"
APKANALYZER="$(resolve_android_tool apkanalyzer)"

if [[ "$COMMAND" == download ]]; then
  [[ ! -e "$RELEASE_DIR" || -d "$RELEASE_DIR" ]] || die "--dir is not a directory"
  if [[ -d "$RELEASE_DIR" ]]; then
    [[ -z "$(find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die "Download directory must be empty"
  else
    mkdir -p "$RELEASE_DIR"
  fi
  gh release download "$TAG" --repo "$REPOSITORY" --dir "$RELEASE_DIR"
fi

[[ -d "$RELEASE_DIR" ]] || die "--dir must be an existing directory"
RELEASE_DIR="$(cd -- "$RELEASE_DIR" && pwd -P)"

MANIFEST="$RELEASE_DIR/release-manifest.json"
[[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || die "Missing regular release-manifest.json"
node -e '
  const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")), tag=process.argv[2];
  if (m.schema_version!==3 || m.type!=="arcp_channel_release" || m.immutable!==true || m.release_tag!==tag ||
      m.local_ref!==`release/${m.channel}` || !["stable","edge"].includes(m.channel) ||
      m.prerelease!==(m.channel==="edge") || !/^[0-9a-f]{40}$/.test(m.local_sha) ||
      !/^[0-9a-f]{40}$/.test(m.upstream_sha) || !/^[0-9a-f]{64}$/.test(m.feature_contract_sha256) ||
      m.qualification?.profile!=="arcp_fork_release" ||
      m.qualification?.ngrok_live_integration!=="passed_protected_job" ||
      m.qualification?.mandatory_gates_skipped!==false || !Array.isArray(m.assets) || m.assets.length!==2 ||
      new Set(m.assets.map(a=>a.variant)).size!==2 ||
      !["vendor/cloudflared","vendor/ngrok-java"].every(k=>/^[0-9a-f]{40}$/.test(m.submodules?.[k]||""))) process.exit(1);
' "$MANIFEST" "$TAG" || die "Invalid release manifest contract"

CHANNEL="$(json_value "$MANIFEST" channel)"
LOCAL_SHA="$(json_value "$MANIFEST" local_sha)"
UPSTREAM_SHA="$(json_value "$MANIFEST" upstream_sha)"
CERTIFICATE="$(json_value "$MANIFEST" certificate_sha256)"
mapfile -t expected_files < <(node -e '
  const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  console.log("release-manifest.json"); for (const a of m.assets) console.log(a.signed_asset);
' "$MANIFEST" | sort)
mapfile -t actual_files < <(find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
[[ "${actual_files[*]}" == "${expected_files[*]}" ]] || die "Release directory has missing or extra files"
[[ -z "$(find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]] ||
  die "Release directory contains a link or non-regular entry"

for variant in gmsRelease fossRelease; do
  asset="$(node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const a=m.assets.find(v=>v.variant===process.argv[2]);if(!a)process.exit(1);process.stdout.write(a.signed_asset)' "$MANIFEST" "$variant")"
  apk="$RELEASE_DIR/$asset"
  expected_sha="$(node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(m.assets.find(v=>v.variant===process.argv[2]).signed_sha256)' "$MANIFEST" "$variant")"
  [[ "$(sha256sum "$apk" | awk '{print $1}')" == "$expected_sha" ]] || die "$variant digest mismatch"
  [[ "$(single_signer "$apk")" == "$CERTIFICATE" ]] || die "$variant signer mismatch"
  [[ "$($APKANALYZER manifest application-id "$apk")" == "$PACKAGE_ID" ]] || die "$variant package mismatch"
  expected_code="$(node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(m.assets.find(v=>v.variant===process.argv[2]).version_code))' "$MANIFEST" "$variant")"
  expected_name="$(node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(m.assets.find(v=>v.variant===process.argv[2]).version_name)' "$MANIFEST" "$variant")"
  [[ "$($APKANALYZER manifest version-code "$apk")" == "$expected_code" &&
     "$($APKANALYZER manifest version-name "$apk")" == "$expected_name" ]] || die "$variant version mismatch"
  validate_payload "$apk"
done

remote_json="$(gh release view "$TAG" --repo "$REPOSITORY" --json tagName,targetCommitish,isPrerelease)"
node -e '
  const r=JSON.parse(process.argv[1]);
  const m=JSON.parse(require("fs").readFileSync(process.argv[2],"utf8"));
  if (r.tagName!==m.release_tag || r.targetCommitish!==m.local_sha || r.isPrerelease!==m.prerelease) process.exit(1);
' "$remote_json" "$MANIFEST" || die "Remote release identity differs from the manifest"

git -C "$REPO_ROOT" fetch --no-tags origin "+refs/heads/release/version-ledger:refs/arcp-version-ledger/verify" \
  "+$LOCAL_SHA:refs/arcp-release-sources/$LOCAL_SHA" >/dev/null
LEDGER_VERIFY="$(mktemp /tmp/arcp-release-ledger.XXXXXX.json)"
git -C "$REPO_ROOT" show refs/arcp-version-ledger/verify:ledger.json > "$LEDGER_VERIFY"
node -e '
  const fs=require("fs");
  const ledger=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  const m=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
  const e=ledger.entries.find(v=>v.release_tag===m.release_tag);
  if (!e || e.channel!==m.channel || e.upstream_sha!==m.upstream_sha || e.local_sha!==m.local_sha ||
      !m.assets.every(a=>a.version_code===e.version_code)) process.exit(1);
' "$LEDGER_VERIFY" "$MANIFEST" || die "Release is not bound to the version ledger"
rm -f -- "$LEDGER_VERIFY"
LEDGER_VERIFY=""

TEMP_DIR="$(mktemp -d /tmp/arcp-release-verify.XXXXXX)"
git -C "$REPO_ROOT" archive "$LOCAL_SHA" | tar -x -C "$TEMP_DIR"
actual_feature_contract="$(node "$SCRIPT_DIR/verify-arcp-channel-features.mjs" "$TEMP_DIR" "$CHANNEL" hash)"
expected_feature_contract="$(json_value "$MANIFEST" feature_contract_sha256)"
[[ "$actual_feature_contract" == "$expected_feature_contract" ]] || die "Feature contract mismatch"
for path in vendor/cloudflared vendor/ngrok-java; do
  actual_submodule_sha="$(git -C "$REPO_ROOT" ls-tree "$LOCAL_SHA" "$path" | awk '{print $3}')"
  expected_submodule_sha="$(node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(m.submodules[process.argv[2]])' "$MANIFEST" "$path")"
  [[ "$actual_submodule_sha" == "$expected_submodule_sha" ]] ||
    die "Submodule provenance mismatch for $path"
done

printf 'VERIFIED: %s channel=%s local=%s upstream=%s\n' "$TAG" "$CHANNEL" "$LOCAL_SHA" "$UPSTREAM_SHA"
[[ "$COMMAND" != verify && "$COMMAND" != download ]] || exit 0

asset="$(node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(m.assets.find(v=>v.variant===process.argv[2]).signed_asset)' "$MANIFEST" "$VARIANT")"
APK="$RELEASE_DIR/$asset"
CANDIDATE_CODE="$($APKANALYZER manifest version-code "$APK")"
if [[ "$APPLY" == false ]]; then
  printf 'PREVIEW: would install verified %s (%s, versionCode=%s) on [REDACTED_DEVICE_ALIAS] without clearing data\n' \
    "$TAG" "$VARIANT" "$CANDIDATE_CODE"
  exit 0
fi

if command -v adb >/dev/null 2>&1; then ADB=(adb); elif command -v adb.exe >/dev/null 2>&1; then ADB=(adb.exe); else die "adb is unavailable"; fi
if [[ -z "$SERIAL" ]]; then
  secret_file="$REPO_ROOT/myconf/[REDACTED_DEVICE_ALIAS]/.env.secrets"
  [[ -r "$secret_file" ]] || die "--serial is required"
  SERIAL="$(awk -F= '$1=="ADB_SERIAL" {sub(/^[^=]*=/,""); print; count++} END {if(count!=1) exit 2}' "$secret_file")" ||
    die "Cannot read one ADB_SERIAL assignment"
fi
[[ -n "$SERIAL" && "$SERIAL" != *$'\n'* ]] || die "Invalid ADB serial"
[[ "$("${ADB[@]}" -s "$SERIAL" get-state 2>/dev/null)" == device ]] || die "[REDACTED_DEVICE_ALIAS] is not an authorized ADB device"
installed_code="$("${ADB[@]}" -s "$SERIAL" shell dumpsys package "$PACKAGE_ID" | sed -n -E 's/.*versionCode=([0-9]+).*/\1/p' | head -1 | tr -d '\r')"
[[ "$installed_code" =~ ^[0-9]+$ ]] || die "Cannot read installed [REDACTED_DEVICE_ALIAS] versionCode"
(( CANDIDATE_CODE > installed_code )) || die "Candidate versionCode must be greater than installed versionCode"
backup="$REPO_ROOT/build/device-backups/[REDACTED_DEVICE_ALIAS]/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$backup"
installed_path="$("${ADB[@]}" -s "$SERIAL" shell pm path "$PACKAGE_ID" | sed -n 's/^package://p' | head -1 | tr -d '\r')"
[[ "$installed_path" == /*.apk ]] || die "Cannot locate installed base APK"
"${ADB[@]}" -s "$SERIAL" pull "$installed_path" "$backup/previous.apk" >/dev/null
printf '{"package_id":"%s","version_code":%s,"candidate_tag":"%s"}\n' \
  "$PACKAGE_ID" "$installed_code" "$TAG" > "$backup/rollback-context.json"
"${ADB[@]}" -s "$SERIAL" install -r "$APK"
new_code="$("${ADB[@]}" -s "$SERIAL" shell dumpsys package "$PACKAGE_ID" | sed -n -E 's/.*versionCode=([0-9]+).*/\1/p' | head -1 | tr -d '\r')"
[[ "$new_code" == "$CANDIDATE_CODE" ]] || die "Installed versionCode does not match released APK"
printf 'INSTALLED: %s on [REDACTED_DEVICE_ALIAS]; data retained; rollback evidence: %s\n' "$TAG" "$backup"
