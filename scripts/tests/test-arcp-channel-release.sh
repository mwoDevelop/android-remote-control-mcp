#!/usr/bin/env bash
set -euo pipefail

umask 077
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/../.." && pwd)"
SIGN_SCRIPT="$REPO_ROOT/scripts/sign-arcp-channel-release.sh"
PUBLISH_SCRIPT="$REPO_ROOT/scripts/publish-arcp-channel-release.sh"
WORK_ROOT="$(mktemp -d)"
FAKE_BIN="$WORK_ROOT/bin"
CERTIFICATE_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
FEATURE_SHA256="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
NATIVE_SHA256="$(node "$REPO_ROOT/scripts/native-tunnel-payloads.mjs" "$REPO_ROOT" hash)"
UPSTREAM_SHA="2222222222222222222222222222222222222222"
LOCAL_SHA="3333333333333333333333333333333333333333"
VERSION_CODE=21000000
PASSED=0

cleanup() { [[ ! -d "$WORK_ROOT" ]] || rm -rf -- "$WORK_ROOT"; }
trap cleanup EXIT

pass() { PASSED=$((PASSED + 1)); printf 'ok %d - %s\n' "$PASSED" "$1"; }

expect_failure() {
  local name="$1" pattern="$2" output status
  shift 2
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 && "$output" == *"$pattern"* ]] || {
    printf 'not ok - %s\n%s\n' "$name" "$output" >&2
    exit 1
  }
  pass "$name"
}

make_fake_tools() {
  mkdir -p "$FAKE_BIN"
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$2" in' \
    ' application-id) printf "com.danielealbano.androidremotecontrolmcp\\n" ;;' \
    ' version-code) printf "21000000\\n" ;;' \
    ' version-name) printf "arcp.edge.1.12.0.333333333333.r1\\n" ;;' \
    ' *) exit 1 ;;' \
    'esac' > "$FAKE_BIN/apkanalyzer"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'case "$1" in' \
    ' sign)' \
    '  output=""' \
    '  for ((i=1;i<=$#;i++)); do if [[ "${!i}" == --out ]]; then j=$((i+1)); output="${!j}"; fi; done' \
    '  cp "${!#}" "$output" ;;' \
    ' verify)' \
    '  printf "Verified using v2 scheme (APK Signature Scheme v2): true\\n"' \
    '  printf "Signer #1 certificate SHA-256 digest: %s\\n" "${FAKE_CERTIFICATE_SHA256:?}" ;;' \
    ' *) exit 1 ;;' \
    'esac' > "$FAKE_BIN/apksigner"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '[[ "$1" != -c ]] || exit 0' \
    'args=("$@")' \
    'cp "${args[${#args[@]}-2]}" "${args[${#args[@]}-1]}"' > "$FAKE_BIN/zipalign"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\\n" lib/arm64-v8a/libcloudflared.so lib/armeabi-v7a/libcloudflared.so lib/x86_64/libcloudflared.so lib/arm64-v8a/libngrok_java.so lib/x86_64/libngrok_java.so' \
    > "$FAKE_BIN/unzip"
  chmod +x "$FAKE_BIN"/*
}

make_inputs() {
  local directory="$1" raw variant raw_sha
  mkdir -p "$directory"
  for variant in gmsRelease fossRelease; do
    raw="android-remote-control-mcp-arcp-edge-${variant}-${UPSTREAM_SHA:0:12}-${LOCAL_SHA:0:12}-unsigned.apk"
    printf 'unsigned-%s\n' "$variant" > "$directory/$raw"
    raw_sha="$(sha256sum "$directory/$raw" | awk '{print $1}')"
    node -e '
      const fs=require("fs");
      const [out,variant,asset,sha,upstreamSha,localSha,featureSha,nativeSha]=process.argv.slice(1);
      fs.writeFileSync(out,JSON.stringify({schema_version:4,type:"arcp_channel_pre_sign",channel:"edge",
        upstream_label:"edge",upstream_sha:upstreamSha,local_ref:"release/edge",local_sha:localSha,
        feature_contract_sha256:featureSha,native_payload_contract_version:"android-tunnels-v2",
        native_payload_contract_sha256:nativeSha,
        native_toolchain:{go_version:"1.26.7",android_ndk_version:"27.2.12479018",android_api:21},
        submodules:{"vendor/cloudflared":"4444444444444444444444444444444444444444",
          "vendor/ngrok-java":"5555555555555555555555555555555555555555"},variant,
        source_repository:"https://github.com/mwoDevelop/android-remote-control-mcp",
        upstream_repository:"https://github.com/danielealbano/android-remote-control-mcp",
        qualified:true,mandatory_gates_skipped:false,
        qualification:{profile:"arcp_fork_static",ngrok_live_integration:"pending_protected_job",
          test_retry_occurred:false},signed:false,apk_asset:asset,raw_unsigned_sha256:sha,sha256:sha,
        application_id:"com.danielealbano.androidremotecontrolmcp",version_code:21000000,
        version_name:"arcp.edge.1.12.0.333333333333.r1",certificate_sha256:null},null,2)+"\n");
    ' "$directory/manifest-${variant}-${UPSTREAM_SHA:0:12}-${LOCAL_SHA:0:12}.json" "$variant" "$raw" \
      "$raw_sha" "$UPSTREAM_SHA" "$LOCAL_SHA" "$FEATURE_SHA256" "$NATIVE_SHA256"
  done
  node -e '
    const fs=require("fs"), [out,u,l]=process.argv.slice(1);
    fs.writeFileSync(out,JSON.stringify({identity:`edge:edge:${u}:${l}:r1`,channel:"edge",upstream_label:"edge",
      upstream_sha:u,local_sha:l,revision:1,version_code:21000000,
      release_tag:`arcp-edge-${u.slice(0,12)}-${l.slice(0,12)}-vc21000000`})+"\n");
  ' "$WORK_ROOT/ledger.json" "$UPSTREAM_SHA" "$LOCAL_SHA"
  node -e '
    const fs=require("fs"), [out,u,l]=process.argv.slice(1);
    fs.writeFileSync(out,JSON.stringify({schema_version:1,type:"arcp_live_test",passed:true,channel:"edge",
      upstream_sha:u,local_sha:l})+"\n");
  ' "$WORK_ROOT/live.json" "$UPSTREAM_SHA" "$LOCAL_SHA"
}

sign_bundle() {
  local input="$1" output="$2" certificate="${3:-$CERTIFICATE_SHA256}"
  PATH="$FAKE_BIN:$PATH" FAKE_CERTIFICATE_SHA256="$CERTIFICATE_SHA256" \
    "$SIGN_SCRIPT" --input-dir "$input" --output-dir "$output" \
      --ledger-entry "$WORK_ROOT/ledger.json" --live-test-evidence "$WORK_ROOT/live.json" \
      --keystore "$WORK_ROOT/release.jks" --store-password-file "$WORK_ROOT/store-password" \
      --key-alias release --key-password-file "$WORK_ROOT/key-password" \
      --expected-certificate-sha256 "$certificate" --workflow-run-id test-run \
      --workflow-source-sha 1111111111111111111111111111111111111111
}

test_workflow_contract() {
  local workflow="$REPO_ROOT/.github/workflows/arcp-channel-release.yml"
  [[ -f "$workflow" ]]
  ! grep -Eq '^  schedule:' "$workflow"
  grep -Fq 'group: arcp-channel-publication' "$workflow"
  grep -Fq 'environment: arcp-live-tests' "$workflow"
  grep -Fq 'environment: upstream-releases' "$workflow"
  grep -Fq 'scripts/arcp-version-ledger.sh' "$workflow"
  grep -Fq 'scripts/sign-arcp-channel-release.sh' "$workflow"
  grep -Fq 'scripts/publish-arcp-channel-release.sh' "$workflow"
  ! grep -Fq 'sign-upstream-channel-release.sh' "$workflow"
  pass 'workflow separates static, live and signing trust boundaries'
}

test_artifact_json_loading_contract() {
  local artifact_script="$REPO_ROOT/scripts/arcp-release-artifact.sh"
  [[ -f "$artifact_script" ]]
  ! grep -Eq 'require\(process\.argv\[[12]\]\)' "$artifact_script"
  grep -Fq 'JSON.parse(fs.readFileSync(process.argv[1],"utf8"))' "$artifact_script"
  grep -Fq 'deployment_mode)" == first_install' "$artifact_script"
  grep -Fq 'package_pre_state:"absent"' "$artifact_script"
  grep -Fq 'FIRST_INSTALL_ROLLBACK=true' "$artifact_script"
  pass 'release verification parses JSON content independently of filename extension'
}

test_first_install_absent_package_probe() {
  local artifact_script="$REPO_ROOT/scripts/arcp-release-artifact.sh" output
  eval "$(sed -n '/^package_path_or_empty() {/,/^}/p' "$artifact_script")"

  fake_adb() { return 1; }
  ADB=(fake_adb)
  SERIAL=first-install-test
  PACKAGE_ID=com.example.absent

  output="$(package_path_or_empty)"
  [[ -z "$output" ]]
  pass 'generic first-install treats an absent package as the expected empty pre-state'
}

test_sign_and_dry_run() {
  local input="$WORK_ROOT/input" output="$WORK_ROOT/output" dry
  make_inputs "$input"
  sign_bundle "$input" "$output" >/dev/null
  [[ "$(node -e 'process.stdout.write(require(process.argv[1]).type)' "$output/release-manifest.json")" == arcp_channel_release ]]
  [[ "$(node -e 'process.stdout.write(require(process.argv[1]).release_tag)' "$output/release-manifest.json")" == \
     "arcp-edge-${UPSTREAM_SHA:0:12}-${LOCAL_SHA:0:12}-vc$VERSION_CODE" ]]
  dry="$(PATH="$FAKE_BIN:$PATH" FAKE_CERTIFICATE_SHA256="$CERTIFICATE_SHA256" \
    "$PUBLISH_SCRIPT" --release-dir "$output" --repo example/project)"
  [[ "$dry" == *'DRY RUN: would publish immutable ARCP release'* ]]
  [[ "$dry" == *"local=release/edge/$LOCAL_SHA"* ]]
  pass 'dual-source bundle signs and dry-run is non-mutating'
}

test_relative_signing_paths() {
  make_inputs "$WORK_ROOT/relative-input"
  (
    cd "$WORK_ROOT"
    sign_bundle relative-input relative-output >/dev/null
  )
  [[ -f "$WORK_ROOT/relative-output/release-manifest.json" ]]
  pass 'signing accepts workflow-style relative artifact paths without Node module resolution'
}

test_failures() {
  local input="$WORK_ROOT/bad-input" output="$WORK_ROOT/bad-output" native_input="$WORK_ROOT/native-input"
  make_inputs "$input"
  expect_failure 'wrong signer is rejected' 'Signer certificate mismatch' \
    sign_bundle "$input" "$output" cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  printf 'unexpected\n' > "$input/extra.txt"
  expect_failure 'extra pre-sign asset is rejected' 'exactly four files' \
    sign_bundle "$input" "$WORK_ROOT/extra-output"
  make_inputs "$native_input"
  node -e '
    const fs=require("fs"), file=process.argv[1], m=JSON.parse(fs.readFileSync(file,"utf8"));
    m.native_payload_contract_sha256="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    fs.writeFileSync(file,JSON.stringify(m)+"\n");
  ' "$native_input/manifest-gmsRelease-${UPSTREAM_SHA:0:12}-${LOCAL_SHA:0:12}.json"
  expect_failure 'untrusted native payload provenance is rejected' 'Native payload contract provenance differs' \
    sign_bundle "$native_input" "$WORK_ROOT/native-output"
  pass 'failure paths remain closed'
}

test_apply_create() {
  local source="$WORK_ROOT/output" root="$WORK_ROOT/publisher" gh_log="$WORK_ROOT/gh.log" result
  mkdir -p "$root/scripts"
  cp "$PUBLISH_SCRIPT" "$root/scripts/publish-arcp-channel-release.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    '[[ "$1" == channel-info && "$2" == --latest-edge && "$3" == --expected-source-sha && "$5" == --expected-local-sha ]]' \
    > "$root/scripts/sync-build-deploy.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "%s\\n" "$*" >> "${FAKE_GH_LOG:?}"' \
    '[[ "$1 $2" != "release view" && "$1" != api ]]' \
    > "$FAKE_BIN/gh"
  chmod +x "$root/scripts"/* "$FAKE_BIN/gh"
  : > "$gh_log"
  result="$(PATH="$FAKE_BIN:$PATH" FAKE_GH_LOG="$gh_log" FAKE_CERTIFICATE_SHA256="$CERTIFICATE_SHA256" \
    "$root/scripts/publish-arcp-channel-release.sh" --release-dir "$source" --repo example/project --apply)"
  [[ "$result" == *'Created immutable ARCP edge release'* ]]
  grep -Eq '^release create arcp-edge-.* --target 3333333333333333333333333333333333333333 .*--prerelease' "$gh_log"
  pass 'apply creates one immutable edge prerelease at the local integration SHA'
}

make_fake_tools
touch "$WORK_ROOT/release.jks" "$WORK_ROOT/store-password" "$WORK_ROOT/key-password"
chmod 600 "$WORK_ROOT/release.jks" "$WORK_ROOT/store-password" "$WORK_ROOT/key-password"
test_workflow_contract
test_artifact_json_loading_contract
test_first_install_absent_package_probe
test_sign_and_dry_run
test_relative_signing_paths
test_failures
test_apply_create
printf '1..%d\n' "$PASSED"
