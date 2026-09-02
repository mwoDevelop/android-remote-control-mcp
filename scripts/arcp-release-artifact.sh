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
FIRST_INSTALL_ROLLBACK=false
FIRST_INSTALL_SERIAL=""

usage() {
  cat <<'EOF'
Usage:
  scripts/arcp-release-artifact.sh download --tag <immutable-tag> --dir <empty-dir> [--repo owner/repo]
  scripts/arcp-release-artifact.sh verify   --tag <immutable-tag> --dir <dir> [--repo owner/repo]
  scripts/arcp-release-artifact.sh deploy   --tag <immutable-tag> --dir <dir> --device <[REDACTED_DEVICE_ALIAS]|bedroom-tv> \
    [--serial <adb-serial>] [--variant gmsRelease|fossRelease] [--repo owner/repo] [--apply]

download always verifies the downloaded closed asset set. deploy is a preview unless --apply is present and never
clears application data. The Bedroom TV path is a strict first install and rolls back only a package installed by
the same failed invocation when its verified pre-state was absent.
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
    const value=process.argv[2].split(".").reduce((v,k)=>v==null?undefined:v[k],require(process.argv[1]));
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
  # shellcheck source=lib/native-tunnel-payloads.sh
  source "$SCRIPT_DIR/lib/native-tunnel-payloads.sh"
  validate_native_tunnel_payload "$1"
}

cleanup() {
  if [[ "$FIRST_INSTALL_ROLLBACK" == true && -n "$FIRST_INSTALL_SERIAL" ]]; then
    printf 'ROLLBACK: removing the failed Bedroom TV first installation\n' >&2
    "${ADB[@]}" -s "$FIRST_INSTALL_SERIAL" uninstall "$PACKAGE_ID" >/dev/null 2>&1 || true
  fi
  [[ -z "$TEMP_DIR" || ! -d "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
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
  [[ "$DEVICE" == [REDACTED_DEVICE_ALIAS] || "$DEVICE" == bedroom-tv ]] ||
    die "This promotion path accepts only --device [REDACTED_DEVICE_ALIAS] or --device bedroom-tv"
  [[ "$DEVICE" != bedroom-tv || "$VARIANT" == gmsRelease ]] || die "Bedroom TV accepts only gmsRelease"
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

MANIFEST="$RELEASE_DIR/release-manifest.json"
[[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || die "Missing regular release-manifest.json"
node -e '
  const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")), tag=process.argv[2];
  if (m.schema_version!==4 || m.type!=="arcp_channel_release" || m.immutable!==true || m.release_tag!==tag ||
      m.local_ref!==`release/${m.channel}` || !["stable","edge"].includes(m.channel) ||
      m.prerelease!==(m.channel==="edge") || !/^[0-9a-f]{40}$/.test(m.local_sha) ||
      !/^[0-9a-f]{40}$/.test(m.upstream_sha) || !/^[0-9a-f]{64}$/.test(m.feature_contract_sha256) ||
      m.native_payload_contract_version!=="android-tunnels-v2" ||
      !/^[0-9a-f]{64}$/.test(m.native_payload_contract_sha256) ||
      m.native_toolchain?.go_version!=="1.26.7" ||
      m.native_toolchain?.android_ndk_version!=="27.2.12479018" || m.native_toolchain?.android_api!==21 ||
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
  const m=require(process.argv[1]); console.log("release-manifest.json"); for (const a of m.assets) console.log(a.signed_asset);
' "$MANIFEST" | sort)
mapfile -t actual_files < <(find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
[[ "${actual_files[*]}" == "${expected_files[*]}" ]] || die "Release directory has missing or extra files"
[[ -z "$(find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]] ||
  die "Release directory contains a link or non-regular entry"

for variant in gmsRelease fossRelease; do
  asset="$(node -e 'const a=require(process.argv[1]).assets.find(v=>v.variant===process.argv[2]);if(!a)process.exit(1);process.stdout.write(a.signed_asset)' "$MANIFEST" "$variant")"
  apk="$RELEASE_DIR/$asset"
  expected_sha="$(node -e 'process.stdout.write(require(process.argv[1]).assets.find(v=>v.variant===process.argv[2]).signed_sha256)' "$MANIFEST" "$variant")"
  [[ "$(sha256sum "$apk" | awk '{print $1}')" == "$expected_sha" ]] || die "$variant digest mismatch"
  [[ "$(single_signer "$apk")" == "$CERTIFICATE" ]] || die "$variant signer mismatch"
  [[ "$($APKANALYZER manifest application-id "$apk")" == "$PACKAGE_ID" ]] || die "$variant package mismatch"
  expected_code="$(node -e 'process.stdout.write(String(require(process.argv[1]).assets.find(v=>v.variant===process.argv[2]).version_code))' "$MANIFEST" "$variant")"
  expected_name="$(node -e 'process.stdout.write(require(process.argv[1]).assets.find(v=>v.variant===process.argv[2]).version_name)' "$MANIFEST" "$variant")"
  [[ "$($APKANALYZER manifest version-code "$apk")" == "$expected_code" &&
     "$($APKANALYZER manifest version-name "$apk")" == "$expected_name" ]] || die "$variant version mismatch"
  validate_payload "$apk"
done

remote_json="$(gh release view "$TAG" --repo "$REPOSITORY" --json tagName,targetCommitish,isPrerelease)"
node -e '
  const r=JSON.parse(process.argv[1]), m=require(process.argv[2]);
  if (r.tagName!==m.release_tag || r.targetCommitish!==m.local_sha || r.isPrerelease!==m.prerelease) process.exit(1);
' "$remote_json" "$MANIFEST" || die "Remote release identity differs from the manifest"

git -C "$REPO_ROOT" fetch --no-tags origin "+refs/heads/release/version-ledger:refs/arcp-version-ledger/verify" \
  "+$LOCAL_SHA:refs/arcp-release-sources/$LOCAL_SHA" >/dev/null
git -C "$REPO_ROOT" show refs/arcp-version-ledger/verify:ledger.json > "$RELEASE_DIR/.ledger.verify"
node -e '
  const ledger=require(process.argv[1]), m=require(process.argv[2]);
  const e=ledger.entries.find(v=>v.release_tag===m.release_tag);
  if (!e || e.channel!==m.channel || e.upstream_sha!==m.upstream_sha || e.local_sha!==m.local_sha ||
      !m.assets.every(a=>a.version_code===e.version_code)) process.exit(1);
' "$RELEASE_DIR/.ledger.verify" "$MANIFEST" || die "Release is not bound to the version ledger"
rm -f "$RELEASE_DIR/.ledger.verify"

TEMP_DIR="$(mktemp -d /tmp/arcp-release-verify.XXXXXX)"
git -C "$REPO_ROOT" archive "$LOCAL_SHA" | tar -x -C "$TEMP_DIR"
actual_feature_contract="$(node "$SCRIPT_DIR/verify-arcp-channel-features.mjs" "$TEMP_DIR" "$CHANNEL" hash)"
expected_feature_contract="$(json_value "$MANIFEST" feature_contract_sha256)"
[[ "$actual_feature_contract" == "$expected_feature_contract" ]] || die "Feature contract mismatch"
actual_native_summary="$(node "$TEMP_DIR/scripts/native-tunnel-payloads.mjs" "$TEMP_DIR" summary)"
expected_native_version="$(json_value "$MANIFEST" native_payload_contract_version)"
expected_native_sha="$(json_value "$MANIFEST" native_payload_contract_sha256)"
expected_native_toolchain="$(node -e '
  const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  process.stdout.write(JSON.stringify(m.native_toolchain));
' "$MANIFEST")"
actual_native_version="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).contract_version)' "$actual_native_summary")"
actual_native_sha="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).contract_sha256)' "$actual_native_summary")"
actual_native_toolchain="$(node -e 'process.stdout.write(JSON.stringify(JSON.parse(process.argv[1]).toolchain))' "$actual_native_summary")"
[[ "$actual_native_version" == "$expected_native_version" ]] || die "Native payload contract version mismatch"
[[ "$actual_native_sha" == "$expected_native_sha" ]] || die "Native payload contract digest mismatch"
[[ "$actual_native_toolchain" == "$expected_native_toolchain" ]] || die "Native toolchain provenance mismatch"
for path in vendor/cloudflared vendor/ngrok-java; do
  actual_submodule_sha="$(git -C "$REPO_ROOT" ls-tree "$LOCAL_SHA" "$path" | awk '{print $3}')"
  expected_submodule_sha="$(node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(m.submodules[process.argv[2]])' "$MANIFEST" "$path")"
  [[ "$actual_submodule_sha" == "$expected_submodule_sha" ]] ||
    die "Submodule provenance mismatch for $path"
done

printf 'VERIFIED: %s channel=%s local=%s upstream=%s\n' "$TAG" "$CHANNEL" "$LOCAL_SHA" "$UPSTREAM_SHA"
[[ "$COMMAND" != verify && "$COMMAND" != download ]] || exit 0

asset="$(node -e 'process.stdout.write(require(process.argv[1]).assets.find(v=>v.variant===process.argv[2]).signed_asset)' "$MANIFEST" "$VARIANT")"
APK="$RELEASE_DIR/$asset"
CANDIDATE_CODE="$($APKANALYZER manifest version-code "$APK")"
if [[ "$APPLY" == false ]]; then
  printf 'PREVIEW: would install verified %s (%s, versionCode=%s) on %s without clearing data\n' \
    "$TAG" "$VARIANT" "$CANDIDATE_CODE" "$DEVICE"
  exit 0
fi

if command -v adb >/dev/null 2>&1; then ADB=(adb); elif command -v adb.exe >/dev/null 2>&1; then ADB=(adb.exe); else die "adb is unavailable"; fi
if [[ -z "$SERIAL" && "$DEVICE" == [REDACTED_DEVICE_ALIAS] ]]; then
  secret_file="$REPO_ROOT/myconf/[REDACTED_DEVICE_ALIAS]/.env.secrets"
  [[ -r "$secret_file" ]] || die "--serial is required"
  SERIAL="$(awk -F= '$1=="ADB_SERIAL" {sub(/^[^=]*=/,""); print; count++} END {if(count!=1) exit 2}' "$secret_file")" ||
    die "Cannot read one ADB_SERIAL assignment"
fi
if [[ -z "$SERIAL" && "$DEVICE" == bedroom-tv ]]; then SERIAL="[REDACTED_PRIVATE_ENDPOINT]"; fi
[[ -n "$SERIAL" && "$SERIAL" != *$'\n'* ]] || die "Invalid ADB serial"
if [[ "$SERIAL" == *:* ]]; then "${ADB[@]}" connect "$SERIAL" >/dev/null; fi
[[ "$("${ADB[@]}" -s "$SERIAL" get-state 2>/dev/null)" == device ]] ||
  die "$DEVICE is not an authorized ADB device"

if [[ "$DEVICE" == bedroom-tv ]]; then
  manufacturer="$("${ADB[@]}" -s "$SERIAL" shell getprop ro.product.manufacturer | tr -d '\r')"
  model="$("${ADB[@]}" -s "$SERIAL" shell getprop ro.product.model | tr -d '\r')"
  device_name="$("${ADB[@]}" -s "$SERIAL" shell getprop ro.product.device | tr -d '\r')"
  sdk="$("${ADB[@]}" -s "$SERIAL" shell getprop ro.build.version.sdk | tr -d '\r')"
  abi_list="$("${ADB[@]}" -s "$SERIAL" shell getprop ro.product.cpu.abilist | tr -d '\r')"
  [[ "$manufacturer" == Google && "$model" == "[REDACTED_OWNER_VALUE]" && "$device_name" == kirkwood &&
     "$sdk" == 34 && "$abi_list" == "armeabi-v7a,armeabi" ]] ||
    die "Bedroom TV identity or 32-bit userspace contract mismatch"
  installed_path="$("${ADB[@]}" -s "$SERIAL" shell pm path "$PACKAGE_ID" 2>/dev/null | tr -d '\r')"
  [[ -z "$installed_path" ]] || die "Bedroom TV first-install path requires the package to be absent"
  FIRST_INSTALL_SERIAL="$SERIAL"
  FIRST_INSTALL_ROLLBACK=true
  "${ADB[@]}" -s "$SERIAL" install "$APK"
  new_code="$("${ADB[@]}" -s "$SERIAL" shell dumpsys package "$PACKAGE_ID" |
    sed -n -E 's/.*versionCode=([0-9]+).*/\1/p' | head -1 | tr -d '\r')"
  [[ "$new_code" == "$CANDIDATE_CODE" ]] || die "Installed versionCode does not match released APK"
  installed_path="$("${ADB[@]}" -s "$SERIAL" shell pm path "$PACKAGE_ID" |
    sed -n 's/^package://p' | head -1 | tr -d '\r')"
  [[ "$installed_path" == /*.apk ]] || die "Cannot locate installed Bedroom TV APK"
  "${ADB[@]}" -s "$SERIAL" pull "$installed_path" "$TEMP_DIR/bedroom-tv-installed.apk" >/dev/null
  [[ "$(single_signer "$TEMP_DIR/bedroom-tv-installed.apk")" == "$CERTIFICATE" ]] ||
    die "Installed Bedroom TV signer differs from the immutable release"
  primary_abi="$("${ADB[@]}" -s "$SERIAL" shell dumpsys package "$PACKAGE_ID" |
    sed -n -E 's/.*primaryCpuAbi=([^[:space:]]+).*/\1/p' | head -1 | tr -d '\r')"
  [[ "$primary_abi" == armeabi-v7a ]] || die "Bedroom TV did not select armeabi-v7a"
  evidence="$REPO_ROOT/build/device-deployments/bedroom-tv/$(date -u +%Y%m%dT%H%M%SZ).json"
  mkdir -p "$(dirname "$evidence")"
  node -e '
    const fs=require("fs"); const [out,tag,serial,code,cert]=process.argv.slice(1);
    fs.writeFileSync(out,JSON.stringify({schema_version:1,type:"verified_first_install",device:"bedroom-tv",
      adb_serial:serial,package_pre_state:"absent",package_id:"com.danielealbano.androidremotecontrolmcp",
      release_tag:tag,version_code:Number(code),certificate_sha256:cert,primary_cpu_abi:"armeabi-v7a",
      installed_at:new Date().toISOString()},null,2)+"\n");
  ' "$evidence" "$TAG" "$SERIAL" "$CANDIDATE_CODE" "$CERTIFICATE"
  FIRST_INSTALL_ROLLBACK=false
  printf 'INSTALLED: %s on Bedroom TV; verified first-install evidence: %s\n' "$TAG" "$evidence"
  exit 0
fi

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
