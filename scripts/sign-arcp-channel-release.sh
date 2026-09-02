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
LEDGER_ENTRY=""
LIVE_TEST_EVIDENCE=""
WORKFLOW_RUN_ID="${GITHUB_RUN_ID:-local}"
WORKFLOW_SOURCE_SHA="${GITHUB_SHA:-$(git -C "$REPO_ROOT" rev-parse HEAD)}"
TEMP_DIR=""

usage() {
  cat <<'EOF'
Usage:
  scripts/sign-arcp-channel-release.sh \
    --input-dir <pre-sign-dir> --output-dir <release-dir> \
    --ledger-entry <entry.json> --live-test-evidence <evidence.json> \
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
  # shellcheck source=lib/native-tunnel-payloads.sh
  source "$SCRIPT_DIR/lib/native-tunnel-payloads.sh"
  validate_native_tunnel_payload "$1"
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
    sed -n -E 's/^.*certificate SHA-256 digest:[[:space:]]*//p' <<<"$output" |
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
    --ledger-entry) (($# >= 2)) || die "$1 requires a value"; LEDGER_ENTRY="$2"; shift 2 ;;
    --live-test-evidence) (($# >= 2)) || die "$1 requires a value"; LIVE_TEST_EVIDENCE="$2"; shift 2 ;;
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
[[ -f "$LEDGER_ENTRY" && ! -L "$LEDGER_ENTRY" ]] || die "--ledger-entry must be a regular file"
[[ -f "$LIVE_TEST_EVIDENCE" && ! -L "$LIVE_TEST_EVIDENCE" ]] ||
  die "--live-test-evidence must be a regular file"
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
TEMP_DIR="$(mktemp -d "$TEMP_BASE/arcp-channel-sign.XXXXXX")"

mapfile -t input_files < <(find "$INPUT_DIR" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
((${#input_files[@]} == 4)) || die "Input directory must contain exactly four files"
mapfile -t manifests < <(find "$INPUT_DIR" -maxdepth 1 -type f -name 'manifest-*-*.json' | sort)
((${#manifests[@]} == 2)) || die "Expected exactly two pre-sign manifests"

CHANNEL=""
UPSTREAM_LABEL=""
UPSTREAM_SHA=""
LOCAL_REF=""
LOCAL_SHA=""
FEATURE_CONTRACT_SHA256=""
SUBMODULES_JSON=""
NATIVE_PAYLOAD_CONTRACT_VERSION=""
NATIVE_PAYLOAD_CONTRACT_SHA256=""
NATIVE_TOOLCHAIN_JSON=""
ROWS_FILE="$TEMP_DIR/assets.tsv"
: >"$ROWS_FILE"

for variant in gmsRelease fossRelease; do
  mapfile -t matches < <(find "$INPUT_DIR" -maxdepth 1 -type f -name "manifest-${variant}-*.json" | sort)
  ((${#matches[@]} == 1)) || die "Expected exactly one $variant pre-sign manifest"
  manifest="${matches[0]}"
  [[ "$(json_value "$manifest" schema_version)" == 4 ]] || die "Unsupported pre-sign manifest schema"
  [[ "$(json_value "$manifest" type)" == arcp_channel_pre_sign ]] || die "Unexpected manifest type"
  [[ "$(json_value "$manifest" variant)" == "$variant" ]] || die "Manifest variant mismatch"
  [[ "$(json_value "$manifest" qualified)" == true ]] || die "Pre-sign artifact is not qualified"
  [[ "$(json_value "$manifest" mandatory_gates_skipped)" == false ]] || die "Mandatory gates were skipped"
  [[ "$(json_value "$manifest" signed)" == false ]] || die "Pre-sign artifact unexpectedly claims a signature"
  [[ "$(json_value "$manifest" application_id)" == "$PACKAGE_ID" ]] || die "Manifest package ID mismatch"
  [[ "$(json_value "$manifest" qualification.profile)" == arcp_fork_static ]] ||
    die "Unexpected qualification profile"
  [[ "$(json_value "$manifest" qualification.ngrok_live_integration)" == pending_protected_job ]] ||
    die "Unexpected live-test state before protected qualification"
  test_retry_occurred="$(json_value "$manifest" qualification.test_retry_occurred)"
  [[ "$test_retry_occurred" == true || "$test_retry_occurred" == false ]] || die "Invalid test retry provenance"

  manifest_channel="$(json_value "$manifest" channel)"
  manifest_label="$(json_value "$manifest" upstream_label)"
  manifest_sha="$(json_value "$manifest" upstream_sha)"
  manifest_local_ref="$(json_value "$manifest" local_ref)"
  manifest_local_sha="$(json_value "$manifest" local_sha)"
  manifest_feature_contract="$(json_value "$manifest" feature_contract_sha256)"
  manifest_native_contract_version="$(json_value "$manifest" native_payload_contract_version)"
  manifest_native_contract_sha="$(json_value "$manifest" native_payload_contract_sha256)"
  manifest_native_toolchain="$(node -e '
    const fs=require("fs"), m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    process.stdout.write(JSON.stringify(m.native_toolchain));
  ' "$manifest")"
  manifest_submodules="$(node -e '
    const fs=require("fs"), m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    process.stdout.write(JSON.stringify(m.submodules));
  ' "$manifest")"
  [[ "$manifest_channel" == stable || "$manifest_channel" == edge ]] || die "Unknown channel in manifest"
  [[ "$manifest_sha" =~ ^[0-9a-f]{40}$ && "$manifest_local_sha" =~ ^[0-9a-f]{40}$ ]] ||
    die "Invalid source SHA in manifest"
  [[ "$manifest_local_ref" == "release/$manifest_channel" ]] || die "Unexpected local integration ref"
  [[ "$manifest_feature_contract" =~ ^[0-9a-f]{64}$ ]] || die "Invalid feature contract digest"
  trusted_native_summary="$(node "$SCRIPT_DIR/native-tunnel-payloads.mjs" "$REPO_ROOT" summary)"
  trusted_native_contract_version="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).contract_version)' "$trusted_native_summary")"
  trusted_native_contract_sha="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).contract_sha256)' "$trusted_native_summary")"
  trusted_native_toolchain="$(node -e 'process.stdout.write(JSON.stringify(JSON.parse(process.argv[1]).toolchain))' "$trusted_native_summary")"
  [[ "$manifest_native_contract_version" == "$trusted_native_contract_version" &&
     "$manifest_native_contract_sha" == "$trusted_native_contract_sha" &&
     "$manifest_native_toolchain" == "$trusted_native_toolchain" ]] ||
    die "Native payload contract provenance differs from trusted automation"
  node -e '
    const value=JSON.parse(process.argv[1]);
    const required=["vendor/cloudflared","vendor/ngrok-java"];
    if (!value || Array.isArray(value) || !required.every(k=>/^[0-9a-f]{40}$/.test(value[k]||""))) process.exit(1);
  ' "$manifest_submodules" || die "Invalid submodule provenance"
  if [[ -z "$CHANNEL" ]]; then
    CHANNEL="$manifest_channel"
    UPSTREAM_LABEL="$manifest_label"
    UPSTREAM_SHA="$manifest_sha"
    LOCAL_REF="$manifest_local_ref"
    LOCAL_SHA="$manifest_local_sha"
    FEATURE_CONTRACT_SHA256="$manifest_feature_contract"
    NATIVE_PAYLOAD_CONTRACT_VERSION="$manifest_native_contract_version"
    NATIVE_PAYLOAD_CONTRACT_SHA256="$manifest_native_contract_sha"
    NATIVE_TOOLCHAIN_JSON="$manifest_native_toolchain"
    SUBMODULES_JSON="$manifest_submodules"
  else
    [[ "$CHANNEL" == "$manifest_channel" && "$UPSTREAM_LABEL" == "$manifest_label" &&
       "$UPSTREAM_SHA" == "$manifest_sha" && "$LOCAL_REF" == "$manifest_local_ref" &&
       "$LOCAL_SHA" == "$manifest_local_sha" && "$FEATURE_CONTRACT_SHA256" == "$manifest_feature_contract" &&
       "$NATIVE_PAYLOAD_CONTRACT_VERSION" == "$manifest_native_contract_version" &&
       "$NATIVE_PAYLOAD_CONTRACT_SHA256" == "$manifest_native_contract_sha" &&
       "$NATIVE_TOOLCHAIN_JSON" == "$manifest_native_toolchain" &&
       "$SUBMODULES_JSON" == "$manifest_submodules" ]] ||
      die "GMS and FOSS source provenance differs"
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
  release_tag="$(json_value "$LEDGER_ENTRY" release_tag)"
  signed_name="android-remote-control-mcp-${release_tag}-${flavor}-release.apk"
  signed_apk="$OUTPUT_DIR/$signed_name"
  "$ZIPALIGN" -f -p 4 "$raw_apk" "$aligned_apk"
  "$ZIPALIGN" -c -p 4 "$aligned_apk"
  aligned_sha="$(sha256sum "$aligned_apk" | awk '{print $1}')"
  "$APKSIGNER" sign --ks "$KEYSTORE" --ks-key-alias "$KEY_ALIAS" \
    --ks-pass "file:$STORE_PASSWORD_FILE" --key-pass "file:$KEY_PASSWORD_FILE" \
    --v4-signing-enabled false --out "$signed_apk" "$aligned_apk"
  "$ZIPALIGN" -c -p 4 "$signed_apk"
  signer_digest="$(verified_single_signer_digest "$APKSIGNER" "$signed_apk")"
  signed_metadata="$(apk_package_metadata "$APKANALYZER" "$signed_apk")"
  [[ "$signed_metadata" == "$raw_metadata" ]] || die "Signing changed package/version metadata"
  validate_tunnel_payload "$signed_apk"
  signed_sha="$(sha256sum "$signed_apk" | awk '{print $1}')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$variant" "$raw_name" "$raw_sha" "$aligned_sha" "$signed_name" "$signed_sha" \
    "$app_id" "$version_code" "$version_name" "$signer_digest" "$test_retry_occurred" >>"$ROWS_FILE"
done

[[ "$(json_value "$LEDGER_ENTRY" channel)" == "$CHANNEL" ]] || die "Ledger channel mismatch"
[[ "$(json_value "$LEDGER_ENTRY" upstream_label)" == "$UPSTREAM_LABEL" ]] || die "Ledger upstream label mismatch"
[[ "$(json_value "$LEDGER_ENTRY" upstream_sha)" == "$UPSTREAM_SHA" ]] || die "Ledger upstream SHA mismatch"
[[ "$(json_value "$LEDGER_ENTRY" local_sha)" == "$LOCAL_SHA" ]] || die "Ledger local SHA mismatch"
RELEASE_TAG="$(json_value "$LEDGER_ENTRY" release_tag)"
ALLOCATED_VERSION_CODE="$(json_value "$LEDGER_ENTRY" version_code)"
[[ "$RELEASE_TAG" =~ ^arcp-(stable|edge)-[A-Za-z0-9._-]+-vc[0-9]+$ ]] || die "Invalid immutable ARCP release tag"
[[ "$ALLOCATED_VERSION_CODE" =~ ^[1-9][0-9]*$ && "$ALLOCATED_VERSION_CODE" -le 2100000000 ]] ||
  die "Invalid allocated version code"
for variant in gmsRelease fossRelease; do
  recorded_code="$(awk -F '\t' -v wanted="$variant" '$1 == wanted {print $8}' "$ROWS_FILE")"
  [[ "$recorded_code" == "$ALLOCATED_VERSION_CODE" ]] || die "$variant is not bound to the ledger version code"
done

[[ "$(json_value "$LIVE_TEST_EVIDENCE" schema_version)" == 1 ]] || die "Unsupported live-test evidence"
[[ "$(json_value "$LIVE_TEST_EVIDENCE" type)" == arcp_live_test ]] || die "Unexpected live-test evidence type"
[[ "$(json_value "$LIVE_TEST_EVIDENCE" passed)" == true ]] || die "Protected live test did not pass"
[[ "$(json_value "$LIVE_TEST_EVIDENCE" channel)" == "$CHANNEL" &&
   "$(json_value "$LIVE_TEST_EVIDENCE" upstream_sha)" == "$UPSTREAM_SHA" &&
   "$(json_value "$LIVE_TEST_EVIDENCE" local_sha)" == "$LOCAL_SHA" ]] || die "Live-test source mismatch"

node -e '
  const fs=require("fs");
  const [out,rowsFile,channel,label,upstreamSha,localRef,localSha,featureContract,nativeVersion,nativeSha,nativeToolchainJson,submodulesJson,tag,cert,runId,workflowSourceSha]=process.argv.slice(1);
  const assets=fs.readFileSync(rowsFile,"utf8").trim().split("\n").filter(Boolean).map(line=>{
    const [variant,rawUnsignedAsset,rawUnsignedSha256,zipalignedSha256,signedAsset,signedSha256,
      applicationId,versionCode,versionName,certificateSha256,testRetryOccurred]=line.split("\t");
    return {variant,raw_unsigned_asset:rawUnsignedAsset,raw_unsigned_sha256:rawUnsignedSha256,
      zipaligned_sha256:zipalignedSha256,signed_asset:signedAsset,signed_sha256:signedSha256,
      application_id:applicationId,version_code:Number(versionCode),version_name:versionName,
      certificate_sha256:certificateSha256,test_retry_occurred:testRetryOccurred==="true"};
  });
  fs.writeFileSync(out,JSON.stringify({schema_version:4,type:"arcp_channel_release",immutable:true,
    created_at:new Date().toISOString(),channel,release_tag:tag,prerelease:channel==="edge",
    tag_target_semantics:"local_integration_commit",source_repository:
      "https://github.com/mwoDevelop/android-remote-control-mcp",upstream_repository:
      "https://github.com/danielealbano/android-remote-control-mcp",upstream_label:label,
    upstream_sha:upstreamSha,local_ref:localRef,local_sha:localSha,feature_contract_sha256:featureContract,
    native_payload_contract_version:nativeVersion,native_payload_contract_sha256:nativeSha,
    native_toolchain:JSON.parse(nativeToolchainJson),
    submodules:JSON.parse(submodulesJson),
    qualification:{profile:"arcp_fork_release",ngrok_live_integration:"passed_protected_job",
      mandatory_gates_skipped:false},workflow_run_id:runId,workflow_source_sha:workflowSourceSha,
      certificate_sha256:cert,assets},null,2)+"\n");
' "$OUTPUT_DIR/release-manifest.json" "$ROWS_FILE" "$CHANNEL" "$UPSTREAM_LABEL" "$UPSTREAM_SHA" \
  "$LOCAL_REF" "$LOCAL_SHA" "$FEATURE_CONTRACT_SHA256" "$NATIVE_PAYLOAD_CONTRACT_VERSION" \
  "$NATIVE_PAYLOAD_CONTRACT_SHA256" "$NATIVE_TOOLCHAIN_JSON" "$SUBMODULES_JSON" "$RELEASE_TAG" "$EXPECTED_CERTIFICATE_SHA256" \
  "$WORKFLOW_RUN_ID" "$WORKFLOW_SOURCE_SHA"

cat >"$OUTPUT_DIR/release-notes.md" <<EOF
ARCP local-fork **$CHANNEL** release built from owner integration \
\`mwoDevelop/android-remote-control-mcp@$LOCAL_SHA\` on top of official upstream \
\`danielealbano/android-remote-control-mcp@$UPSTREAM_SHA\` ($UPSTREAM_LABEL).

This APK **includes** the owner administrator, Shizuku, trusted unlock, remote sleep and tunnel/origin recovery
extensions. The release identity is immutable and its Android version code is allocated in the owner release ledger.

The APK keeps package ID \`$PACKAGE_ID\` and is signed with this fork owner's key. It may not be signature-compatible
with an APK signed by the official upstream author.

See \`release-manifest.json\` for dual-source, feature-contract, qualification, signer and SHA-256 provenance. Static
qualification was secretless; the live ngrok test passed separately with a protected least-privilege credential.
EOF

printf 'Signed ARCP %s bundle: upstream=%s/%s local=%s\nRelease tag: %s\nOutput: %s\n' \
  "$CHANNEL" "$UPSTREAM_LABEL" "$UPSTREAM_SHA" "$LOCAL_SHA" "$RELEASE_TAG" "$OUTPUT_DIR"
