#!/usr/bin/env bash
set -euo pipefail

umask 077
unset [REDACTED_DEVICE_ALIAS]_PIN [REDACTED_DEVICE_ALIAS]_PIN NGROK_AUTHTOKEN ANDROID_MCP_BEARER_TOKEN CLOUDFLARE_TUNNEL_TOKEN \
  RELEASE_KEYSTORE_BASE64 RELEASE_KEYSTORE_PASSWORD RELEASE_KEY_ALIAS RELEASE_KEY_PASSWORD GH_TOKEN GITHUB_TOKEN

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PACKAGE_ID="com.danielealbano.androidremotecontrolmcp"
INPUT_DIR=""
OUTPUT_DIR=""
KEYSTORE=""
STORE_PASSWORD_FILE=""
KEY_ALIAS=""
KEY_PASSWORD_FILE=""
EXPECTED_CERTIFICATE_SHA256=""
WORKFLOW_RUN_ID="${GITHUB_RUN_ID:-local}"
WORKFLOW_SOURCE_SHA="${GITHUB_SHA:-$(git -C "$REPO_ROOT" rev-parse HEAD)}"
TEMP_DIR=""

usage() {
  cat <<'EOF'
Usage:
  scripts/sign-upstream-channel-release.sh \
    --input-dir <pre-sign-dir> --output-dir <release-dir> \
    --keystore <jks> --store-password-file <file> --key-alias <alias> \
    --key-password-file <file> --expected-certificate-sha256 <sha256> \
    [--workflow-run-id <id>]
    [--workflow-source-sha <trusted-fork-sha>]

The input directory must contain exactly the gmsRelease and fossRelease pre-sign manifests and
their raw unsigned APKs. Password values are read from mode-0600 files and are never command-line values.
The script executes only trusted local validators and Android SDK tools; it never executes an input artifact.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is unavailable: $1"
}

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
  local file="$1" path="$2"
  node -e '
    const data=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const value=process.argv[2].split(".").reduce((v,k)=>v == null ? undefined : v[k],data);
    if (value === undefined || value === null) process.exit(3);
    process.stdout.write(String(value));
  ' "$file" "$path"
}

normalize_digest() {
  tr '[:upper:]' '[:lower:]' <<<"$1" | tr -d ':[:space:]'
}

assert_private_file() {
  local file="$1" label="$2"
  [[ -f "$file" && -r "$file" ]] || die "$label is not a readable regular file"
  [[ -z "$(find "$file" -perm /077 -print)" ]] || die "$label must not be accessible by group or others"
}

validate_tunnel_payload() {
  local apk="$1" entries abi library
  entries="$(unzip -Z1 "$apk")"
  for abi in arm64-v8a x86_64; do
    for library in libcloudflared.so libngrok_java.so; do
      grep -Fxq "lib/$abi/$library" <<<"$entries" ||
        die "APK is missing required tunnel payload: lib/$abi/$library"
    done
  done
}

apk_package_metadata() {
  local analyzer="$1" apk="$2" app_id version_code version_name
  app_id="$($analyzer manifest application-id "$apk")"
  version_code="$($analyzer manifest version-code "$apk")"
  version_name="$($analyzer manifest version-name "$apk")"
  [[ "$app_id" == "$PACKAGE_ID" && "$version_code" =~ ^[0-9]+$ && -n "$version_name" ]] ||
    die "APK package or version metadata is invalid"
  printf '%s\t%s\t%s\n' "$app_id" "$version_code" "$version_name"
}

verified_single_signer_digest() {
  local signer="$1" apk="$2" output digest
  local -a digests
  output="$($signer verify --verbose --print-certs "$apk")" || die "apksigner verification failed"
  grep -Eq '^Verified using v(2|3|3\.1) scheme .*: true$' <<<"$output" ||
    die "Signed APK does not verify with an APK Signature Scheme v2 or newer"
  mapfile -t digests < <(
    sed -n -E 's/^(Signer #[0-9]+|V[0-9]+ Signer:)[[:space:]]*certificate SHA-256 digest: //p' <<<"$output" |
      tr '[:upper:]' '[:lower:]' | tr -d ':' | sort -u
  )
  ((${#digests[@]} == 1)) || die "Signed APK must contain exactly one unique signer certificate"
  digest="$(normalize_digest "${digests[0]}")"
  [[ "$digest" == "$EXPECTED_CERTIFICATE_SHA256" ]] ||
    die "Signer certificate mismatch: expected $EXPECTED_CERTIFICATE_SHA256, got $digest"
  printf '%s' "$digest"
}

cleanup() {
  [[ -z "$TEMP_DIR" || ! -d "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT INT TERM

while (($#)); do
  case "$1" in
    --input-dir) (($# >= 2)) || die "$1 requires a value"; INPUT_DIR="$2"; shift 2 ;;
    --output-dir) (($# >= 2)) || die "$1 requires a value"; OUTPUT_DIR="$2"; shift 2 ;;
    --keystore) (($# >= 2)) || die "$1 requires a value"; KEYSTORE="$2"; shift 2 ;;
    --store-password-file) (($# >= 2)) || die "$1 requires a value"; STORE_PASSWORD_FILE="$2"; shift 2 ;;
    --key-alias) (($# >= 2)) || die "$1 requires a value"; KEY_ALIAS="$2"; shift 2 ;;
    --key-password-file) (($# >= 2)) || die "$1 requires a value"; KEY_PASSWORD_FILE="$2"; shift 2 ;;
    --expected-certificate-sha256)
      (($# >= 2)) || die "$1 requires a value"
      EXPECTED_CERTIFICATE_SHA256="$(normalize_digest "$2")"
      shift 2
      ;;
    --workflow-run-id) (($# >= 2)) || die "$1 requires a value"; WORKFLOW_RUN_ID="$2"; shift 2 ;;
    --workflow-source-sha) (($# >= 2)) || die "$1 requires a value"; WORKFLOW_SOURCE_SHA="${2,,}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -d "$INPUT_DIR" ]] || die "--input-dir must be an existing directory"
[[ -n "$OUTPUT_DIR" ]] || die "--output-dir is required"
[[ -n "$KEY_ALIAS" && "$KEY_ALIAS" != *$'\n'* ]] || die "--key-alias is required and must be one line"
[[ "$EXPECTED_CERTIFICATE_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
  die "--expected-certificate-sha256 must be a SHA-256 digest"
[[ "$WORKFLOW_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || die "--workflow-source-sha must be a full commit SHA"
assert_private_file "$KEYSTORE" "Keystore"
assert_private_file "$STORE_PASSWORD_FILE" "Store password file"
assert_private_file "$KEY_PASSWORD_FILE" "Key password file"
[[ ! -e "$OUTPUT_DIR" || -d "$OUTPUT_DIR" ]] || die "--output-dir is not a directory"
if [[ -d "$OUTPUT_DIR" ]]; then
  [[ -z "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die "--output-dir must be empty"
else
  mkdir -p "$OUTPUT_DIR"
fi

require_command node
require_command unzip
require_command sha256sum
APKANALYZER="$(resolve_android_tool apkanalyzer)"
APKSIGNER="$(resolve_android_tool apksigner)"
ZIPALIGN="$(resolve_android_tool zipalign)"
TEMP_BASE="${RUNNER_TEMP:-/tmp}"
[[ -d "$TEMP_BASE" ]] || die "Temporary directory base does not exist: $TEMP_BASE"
TEMP_DIR="$(mktemp -d "$TEMP_BASE/arcp-upstream-sign.XXXXXX")"

mapfile -t input_files < <(find "$INPUT_DIR" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
((${#input_files[@]} == 4)) || die "Input directory must contain exactly four files"
mapfile -t manifests < <(find "$INPUT_DIR" -maxdepth 1 -type f -name 'manifest-*-*.json' | sort)
((${#manifests[@]} == 2)) || die "Expected exactly two pre-sign manifests"

CHANNEL=""
SOURCE_LABEL=""
SOURCE_SHA=""
ROWS_FILE="$TEMP_DIR/assets.tsv"
: >"$ROWS_FILE"

for variant in gmsRelease fossRelease; do
  mapfile -t matches < <(find "$INPUT_DIR" -maxdepth 1 -type f -name "manifest-${variant}-*.json" | sort)
  ((${#matches[@]} == 1)) || die "Expected exactly one $variant pre-sign manifest"
  manifest="${matches[0]}"
  [[ "$(json_value "$manifest" schema_version)" == 2 ]] || die "Unsupported pre-sign manifest schema"
  [[ "$(json_value "$manifest" type)" == upstream_channel_pre_sign ]] || die "Unexpected manifest type"
  [[ "$(json_value "$manifest" variant)" == "$variant" ]] || die "Manifest variant mismatch"
  [[ "$(json_value "$manifest" qualified)" == true ]] || die "Pre-sign artifact is not qualified"
  [[ "$(json_value "$manifest" mandatory_gates_skipped)" == false ]] || die "Mandatory gates were skipped"
  [[ "$(json_value "$manifest" signed)" == false ]] || die "Pre-sign artifact unexpectedly claims a signature"
  [[ "$(json_value "$manifest" application_id)" == "$PACKAGE_ID" ]] || die "Manifest package ID mismatch"
  [[ "$(json_value "$manifest" qualification.profile)" == upstream_mirror_secretless ]] ||
    die "Unexpected qualification profile"

  manifest_channel="$(json_value "$manifest" channel)"
  manifest_label="$(json_value "$manifest" source_label)"
  manifest_sha="$(json_value "$manifest" source_sha)"
  [[ "$manifest_channel" == stable || "$manifest_channel" == edge ]] || die "Unknown channel in manifest"
  [[ "$manifest_sha" =~ ^[0-9a-f]{40}$ ]] || die "Invalid source SHA in manifest"
  if [[ -z "$CHANNEL" ]]; then
    CHANNEL="$manifest_channel"
    SOURCE_LABEL="$manifest_label"
    SOURCE_SHA="$manifest_sha"
  else
    [[ "$CHANNEL" == "$manifest_channel" && "$SOURCE_LABEL" == "$manifest_label" &&
       "$SOURCE_SHA" == "$manifest_sha" ]] || die "GMS and FOSS source provenance differs"
  fi

  raw_name="$(json_value "$manifest" apk_asset)"
  [[ "$raw_name" == "$(basename "$raw_name")" && "$raw_name" == *.apk ]] || die "Unsafe APK asset name"
  raw_apk="$INPUT_DIR/$raw_name"
  [[ -f "$raw_apk" ]] || die "Manifest APK asset is missing: $raw_name"
  raw_sha="$(sha256sum "$raw_apk" | awk '{print $1}')"
  [[ "$raw_sha" == "$(json_value "$manifest" raw_unsigned_sha256)" ]] || die "Raw APK digest mismatch"
  raw_metadata="$(apk_package_metadata "$APKANALYZER" "$raw_apk")"
  IFS=$'\t' read -r app_id version_code version_name <<<"$raw_metadata"
  [[ "$version_code" == "$(json_value "$manifest" version_code)" &&
     "$version_name" == "$(json_value "$manifest" version_name)" ]] || die "Raw APK version metadata mismatch"
  validate_tunnel_payload "$raw_apk"

  flavor="${variant%Release}"
  flavor="${flavor,,}"
  aligned_apk="$TEMP_DIR/${flavor}-aligned.apk"
  if [[ "$CHANNEL" == stable ]]; then release_component="$SOURCE_LABEL"; else release_component=edge; fi
  signed_name="android-remote-control-mcp-upstream-${release_component}-${flavor}-release.apk"
  signed_apk="$OUTPUT_DIR/$signed_name"
  "$ZIPALIGN" -f -p 4 "$raw_apk" "$aligned_apk"
  "$ZIPALIGN" -c -p 4 "$aligned_apk"
  aligned_sha="$(sha256sum "$aligned_apk" | awk '{print $1}')"
  "$APKSIGNER" sign --ks "$KEYSTORE" --ks-key-alias "$KEY_ALIAS" \
    --ks-pass "file:$STORE_PASSWORD_FILE" --key-pass "file:$KEY_PASSWORD_FILE" \
    --out "$signed_apk" "$aligned_apk"
  "$ZIPALIGN" -c -p 4 "$signed_apk"
  signer_digest="$(verified_single_signer_digest "$APKSIGNER" "$signed_apk")"
  signed_metadata="$(apk_package_metadata "$APKANALYZER" "$signed_apk")"
  [[ "$signed_metadata" == "$raw_metadata" ]] || die "Signing changed package/version metadata"
  validate_tunnel_payload "$signed_apk"
  signed_sha="$(sha256sum "$signed_apk" | awk '{print $1}')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$variant" "$raw_name" "$raw_sha" "$aligned_sha" "$signed_name" "$signed_sha" \
    "$app_id" "$version_code" "$version_name" "$signer_digest" >>"$ROWS_FILE"
done

if [[ "$CHANNEL" == stable ]]; then
  [[ "$SOURCE_LABEL" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Stable source label is not a strict version tag"
  RELEASE_TAG="upstream-$SOURCE_LABEL"
else
  [[ "$SOURCE_LABEL" == edge ]] || die "Edge source label must be edge"
  RELEASE_TAG="upstream-edge"
fi

node -e '
  const fs=require("fs");
  const [out,rowsFile,channel,label,sourceSha,tag,cert,runId,workflowSourceSha]=process.argv.slice(1);
  const assets=fs.readFileSync(rowsFile,"utf8").trim().split("\n").filter(Boolean).map(line=>{
    const [variant,rawUnsignedAsset,rawUnsignedSha256,zipalignedSha256,signedAsset,signedSha256,
      applicationId,versionCode,versionName,certificateSha256]=line.split("\t");
    return {variant,raw_unsigned_asset:rawUnsignedAsset,raw_unsigned_sha256:rawUnsignedSha256,
      zipaligned_sha256:zipalignedSha256,signed_asset:signedAsset,signed_sha256:signedSha256,
      application_id:applicationId,version_code:Number(versionCode),version_name:versionName,
      certificate_sha256:certificateSha256};
  });
  fs.writeFileSync(out,JSON.stringify({schema_version:2,type:"upstream_channel_release",
    created_at:new Date().toISOString(),channel,release_tag:tag,prerelease:true,
    tag_target_semantics:"trusted_fork_workflow_commit",source_repository:
      "https://github.com/danielealbano/android-remote-control-mcp",source_label:label,source_sha:sourceSha,
    qualification:{profile:"upstream_mirror_secretless",ngrok_live_integration:"not_applicable_untrusted_source",
      mandatory_gates_skipped:false},workflow_run_id:runId,workflow_source_sha:workflowSourceSha,
      certificate_sha256:cert,assets},null,2)+"\n");
' "$OUTPUT_DIR/release-manifest.json" "$ROWS_FILE" "$CHANNEL" "$SOURCE_LABEL" "$SOURCE_SHA" \
  "$RELEASE_TAG" "$EXPECTED_CERTIFICATE_SHA256" "$WORKFLOW_RUN_ID" "$WORKFLOW_SOURCE_SHA"

cat >"$OUTPUT_DIR/release-notes.md" <<EOF
Pure official-upstream **$CHANNEL** mirror built from \
\`danielealbano/android-remote-control-mcp@$SOURCE_SHA\` ($SOURCE_LABEL).

This is always a pre-release in this fork. These APKs do **not** contain the fork-only administrator, Shizuku,
trusted unlock/sleep or origin-recovery extensions.

**Manual-install warning:** the APK keeps package ID \`$PACKAGE_ID\` and is signed with this fork owner's key. It can
replace an installed fork build and thereby remove fork-only features, and it may not be signature-compatible with an
APK signed by the official upstream author.

See \`release-manifest.json\` for source, qualification and SHA-256 provenance. The live ngrok account integration
test is intentionally not applicable to this secretless untrusted-source build profile; it receives no account token.
EOF

printf 'Signed upstream %s bundle: %s (%s)\nRelease tag: %s\nOutput: %s\n' \
  "$CHANNEL" "$SOURCE_LABEL" "$SOURCE_SHA" "$RELEASE_TAG" "$OUTPUT_DIR"
