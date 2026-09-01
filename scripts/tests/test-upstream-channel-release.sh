#!/usr/bin/env bash
set -euo pipefail

umask 077
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/../.." && pwd)"
SIGN_SCRIPT="$REPO_ROOT/scripts/sign-upstream-channel-release.sh"
PUBLISH_SCRIPT="$REPO_ROOT/scripts/publish-upstream-channel-release.sh"
WORK_ROOT="$(mktemp -d)"
FAKE_BIN="$WORK_ROOT/bin"
CERTIFICATE_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
PASSED=0

cleanup() {
  [[ ! -d "$WORK_ROOT" ]] || rm -rf -- "$WORK_ROOT"
}
trap cleanup EXIT

pass() {
  PASSED=$((PASSED + 1))
  printf 'ok %d - %s\n' "$PASSED" "$1"
}

expect_failure() {
  local name="$1" pattern="$2"
  shift 2
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { printf 'not ok - %s unexpectedly succeeded\n' "$name" >&2; exit 1; }
  [[ "$output" == *"$pattern"* ]] || {
    printf 'not ok - %s did not contain expected text: %s\n%s\n' "$name" "$pattern" "$output" >&2
    exit 1
  }
  pass "$name"
}

make_fake_android_tools() {
  mkdir -p "$FAKE_BIN"
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$2" in' \
    '  application-id) printf "com.danielealbano.androidremotecontrolmcp\\n" ;;' \
    '  version-code) printf "11200\\n" ;;' \
    '  version-name) printf "1.12.0\\n" ;;' \
    '  *) exit 1 ;;' \
    'esac' >"$FAKE_BIN/apkanalyzer"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'case "$1" in' \
    '  sign)' \
    '    output=""' \
    '    for ((i=1;i<=$#;i++)); do if [[ "${!i}" == --out ]]; then j=$((i+1)); output="${!j}"; fi; done' \
    '    cp "${!#}" "$output"' \
    '    ;;' \
    '  verify)' \
    '    printf "Verified using v2 scheme (APK Signature Scheme v2): true\\n"' \
    '    printf "Signer #1 certificate SHA-256 digest: %s\\n" "${FAKE_CERTIFICATE_SHA256:?}"' \
    '    ;;' \
    '  *) exit 1 ;;' \
    'esac' >"$FAKE_BIN/apksigner"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ "$1" == -c ]]; then exit 0; fi' \
    'args=("$@")' \
    'cp "${args[${#args[@]}-2]}" "${args[${#args[@]}-1]}"' >"$FAKE_BIN/zipalign"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\\n" lib/arm64-v8a/libcloudflared.so lib/arm64-v8a/libngrok_java.so lib/x86_64/libcloudflared.so lib/x86_64/libngrok_java.so' \
    >"$FAKE_BIN/unzip"
  chmod +x "$FAKE_BIN/apkanalyzer" "$FAKE_BIN/apksigner" "$FAKE_BIN/zipalign" "$FAKE_BIN/unzip"
}

make_input_bundle() {
  local channel="$1" label="$2" source_sha="$3" directory="$4" short_sha raw variant raw_sha
  short_sha="${source_sha:0:12}"
  mkdir -p "$directory"
  for variant in gmsRelease fossRelease; do
    raw="android-remote-control-mcp-$channel-${variant}-${short_sha}-unsigned.apk"
    printf 'unsigned-%s-%s\n' "$channel" "$variant" >"$directory/$raw"
    raw_sha="$(sha256sum "$directory/$raw" | awk '{print $1}')"
    node -e '
      const fs=require("fs");
      const [out,channel,label,sourceSha,variant,raw,rawSha]=process.argv.slice(1);
      fs.writeFileSync(out,JSON.stringify({schema_version:2,type:"upstream_channel_pre_sign",
        channel,source_label:label,source_sha:sourceSha,variant,
        source_repository:"https://github.com/danielealbano/android-remote-control-mcp",
        qualified:true,mandatory_gates_skipped:false,
        qualification:{profile:"upstream_mirror_secretless",ngrok_live_integration:"not_applicable_untrusted_source",
          test_retry_occurred:false},
        signed:false,apk_asset:raw,raw_unsigned_sha256:rawSha,sha256:rawSha,
        application_id:"com.danielealbano.androidremotecontrolmcp",version_code:11200,
        version_name:"1.12.0",certificate_sha256:null},null,2)+"\n");
    ' "$directory/manifest-${variant}-${short_sha}.json" "$channel" "$label" "$source_sha" \
      "$variant" "$raw" "$raw_sha"
  done
}

sign_bundle() {
  local input="$1" output="$2" expected_certificate="${3:-$CERTIFICATE_SHA256}"
  PATH="$FAKE_BIN:$PATH" FAKE_CERTIFICATE_SHA256="$CERTIFICATE_SHA256" \
    "$SIGN_SCRIPT" --input-dir "$input" --output-dir "$output" \
      --keystore "$WORK_ROOT/release.jks" --store-password-file "$WORK_ROOT/store-password" \
      --key-alias release --key-password-file "$WORK_ROOT/key-password" \
      --expected-certificate-sha256 "$expected_certificate" \
      --workflow-run-id test-run --workflow-source-sha 1111111111111111111111111111111111111111
}

test_cli_and_workflow_contracts() {
  local build_job
  if rg -n 'uses: [^ ]+@(v[0-9]+|main|master|stable)$' "$REPO_ROOT/.github/workflows/upstream-channel-release.yml"; then
    printf 'not ok - workflow contains an unpinned action\n' >&2
    exit 1
  fi
  [[ "$(rg -c 'uses: [^ ]+@[0-9a-f]{40}( |$)' "$REPO_ROOT/.github/workflows/upstream-channel-release.yml")" -eq 9 ]]
  build_job="$(sed -n '/^  build-untrusted-upstream:/,/^  sign-and-publish:/p' \
    "$REPO_ROOT/.github/workflows/upstream-channel-release.yml")"
  [[ "$build_job" == *'contents: read'* && "$build_job" == *'persist-credentials: false'* ]]
  [[ "$build_job" != *'secrets.'* && "$build_job" == *'--latest-$CHANNEL'* ]]
  [[ "$build_job" == *'git remote add upstream'* && "$build_job" == *'git remote set-url --push upstream DISABLED'* ]]
  [[ "$(rg -c 'NGROK_AUTHTOKEN' "$REPO_ROOT/scripts/gradle/upstream-mirror-secretless.init.gradle")" -eq 0 ]]
  rg -q 'NgrokTunnelIntegrationTest' "$REPO_ROOT/scripts/gradle/upstream-mirror-secretless.init.gradle"
  rg -q 'https://api.github.com/repos/danielealbano/android-remote-control-mcp/releases/latest' \
    "$REPO_ROOT/app/src/main/kotlin/com/danielealbano/androidremotecontrolmcp/services/update/GithubReleaseChecker.kt"
  pass "workflow pins actions and isolates untrusted build credentials and updater stream"
}

test_stable_sign_and_dry_run() {
  local input="$WORK_ROOT/stable-input" output="$WORK_ROOT/stable-output" dry_run
  make_input_bundle stable v1.12.0 2222222222222222222222222222222222222222 "$input"
  sign_bundle "$input" "$output" >/dev/null
  [[ "$(node -e 'const m=require(process.argv[1]);process.stdout.write(m.release_tag)' "$output/release-manifest.json")" == upstream-v1.12.0 ]]
  [[ "$(node -e 'const m=require(process.argv[1]);process.stdout.write(String(m.assets.length))' "$output/release-manifest.json")" == 2 ]]
  dry_run="$(PATH="$FAKE_BIN:$PATH" "$PUBLISH_SCRIPT" --release-dir "$output" --repo example/project)"
  [[ "$dry_run" == *'DRY RUN: would publish pre-release upstream-v1.12.0'* ]]
  [[ "$dry_run" == *'No GitHub release or tag was created or modified.'* ]]
  pass "stable GMS and FOSS bundle signs, verifies and publication dry-run is non-mutating"
}

test_edge_sign_and_dry_run() {
  local input="$WORK_ROOT/edge-input" output="$WORK_ROOT/edge-output" dry_run
  make_input_bundle edge edge 3333333333333333333333333333333333333333 "$input"
  sign_bundle "$input" "$output" >/dev/null
  [[ "$(node -e 'const m=require(process.argv[1]);process.stdout.write(m.release_tag)' "$output/release-manifest.json")" == upstream-edge ]]
  dry_run="$(PATH="$FAKE_BIN:$PATH" "$PUBLISH_SCRIPT" --release-dir "$output" --repo example/project)"
  [[ "$dry_run" == *'channel=edge source_label=edge'* ]]
  pass "edge GMS and FOSS bundle signs and uses the rolling upstream-edge contract"
}

test_failure_paths() {
  local input="$WORK_ROOT/wrong-cert-input" output="$WORK_ROOT/wrong-cert-output"
  make_input_bundle edge edge 4444444444444444444444444444444444444444 "$input"
  expect_failure "wrong signing certificate is rejected" "Signer certificate mismatch" \
    sign_bundle "$input" "$output" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

  input="$WORK_ROOT/extra-input"
  output="$WORK_ROOT/extra-output"
  make_input_bundle stable v1.12.0 5555555555555555555555555555555555555555 "$input"
  printf 'unexpected\n' >"$input/extra.txt"
  expect_failure "unexpected pre-sign asset is rejected" "exactly four files" sign_bundle "$input" "$output"

  input="$WORK_ROOT/damaged-input"
  output="$WORK_ROOT/damaged-output"
  make_input_bundle stable v1.12.0 6666666666666666666666666666666666666666 "$input"
  sign_bundle "$input" "$output" >/dev/null
  printf 'unexpected\n' >"$output/extra.txt"
  expect_failure "publication rejects an extra release asset" "incomplete, damaged or contains extra files" \
    env PATH="$FAKE_BIN:$PATH" "$PUBLISH_SCRIPT" --release-dir "$output" --repo example/project
}

prepare_remote_assets() {
  local source="$1" target="$2"
  mkdir -p "$target"
  cp "$source/release-manifest.json" "$target/"
  find "$source" -maxdepth 1 -type f -name '*.apk' -exec cp {} "$target/" \;
}

make_fake_github() {
  local publish_root="$WORK_ROOT/publish-root"
  mkdir -p "$publish_root/scripts"
  cp "$PUBLISH_SCRIPT" "$publish_root/scripts/publish-upstream-channel-release.sh"
  chmod +x "$publish_root/scripts/publish-upstream-channel-release.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "%s\\n" "$*" >>"${FAKE_SYNC_LOG:?}"' \
    '[[ "$1" == channel-info && "$2" == --latest-* && "$3" == --expected-source-sha && "$4" =~ ^[0-9a-f]{40}$ ]]' \
    >"$publish_root/scripts/sync-build-deploy.sh"
  chmod +x "$publish_root/scripts/sync-build-deploy.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "%s\\n" "$*" >>"${FAKE_GH_LOG:?}"' \
    'case "$1 $2" in' \
    '  "release view")' \
    '    if [[ "${FAKE_GH_MODE:?}" == new || "${FAKE_GH_MODE:?}" == tag-only ]]; then exit 1; fi' \
    '    if [[ "$*" == *"--json isPrerelease"* ]]; then printf "true\\n"; fi' \
    '    if [[ "$*" == *"--json body"* ]]; then printf "previous notes\\n"; fi' \
    '    ;;' \
    '  "release download")' \
    '    destination=""' \
    '    for ((i=1;i<=$#;i++)); do if [[ "${!i}" == --dir ]]; then j=$((i+1)); destination="${!j}"; fi; done' \
    '    cp "${FAKE_REMOTE_DIR:?}"/* "$destination/"' \
    '    ;;' \
    '  "release create"|"release upload"|"release edit") ;;' \
    '  api*) [[ "${FAKE_GH_MODE:?}" == tag-only ]] ;;' \
    '  *) exit 2 ;;' \
    'esac' >"$FAKE_BIN/gh"
  chmod +x "$FAKE_BIN/gh"
  printf '%s' "$publish_root/scripts/publish-upstream-channel-release.sh"
}

test_apply_publication_contracts() {
  local publisher gh_log sync_log output remote result old_input old_output
  publisher="$(make_fake_github)"
  gh_log="$WORK_ROOT/gh.log"
  sync_log="$WORK_ROOT/sync.log"
  : >"$gh_log"
  : >"$sync_log"

  output="$WORK_ROOT/stable-output"
  result="$(PATH="$FAKE_BIN:$PATH" FAKE_GH_MODE=new FAKE_GH_LOG="$gh_log" FAKE_SYNC_LOG="$sync_log" \
    "$publisher" --release-dir "$output" --repo example/project --apply)"
  [[ "$result" == *'Created pre-release upstream-v1.12.0'* ]]
  rg -q '^release create upstream-v1.12.0 .*--prerelease' "$gh_log"
  rg -q '^channel-info --latest-stable --expected-source-sha' "$sync_log"
  pass "new stable publication uses an immutable pre-release tag after a freshness guard"

  remote="$WORK_ROOT/remote-same-stable"
  prepare_remote_assets "$output" "$remote"
  : >"$gh_log"
  result="$(PATH="$FAKE_BIN:$PATH" FAKE_GH_MODE=existing FAKE_REMOTE_DIR="$remote" \
    FAKE_GH_LOG="$gh_log" FAKE_SYNC_LOG="$sync_log" \
    "$publisher" --release-dir "$output" --repo example/project --apply)"
  [[ "$result" == *'NO-OP:'* ]]
  ! rg -q '^release (upload|edit)' "$gh_log"
  pass "existing complete same-source stable publication is an idempotent no-op"

  remote="$WORK_ROOT/remote-damaged-stable"
  prepare_remote_assets "$output" "$remote"
  printf 'damage\n' >>"$(find "$remote" -maxdepth 1 -type f -name '*.apk' -print -quit)"
  expect_failure "same-source damaged remote release fails closed" "incomplete or damaged" \
    env PATH="$FAKE_BIN:$PATH" FAKE_GH_MODE=existing FAKE_REMOTE_DIR="$remote" \
      FAKE_GH_LOG="$gh_log" FAKE_SYNC_LOG="$sync_log" \
      "$publisher" --release-dir "$output" --repo example/project --apply

  remote="$WORK_ROOT/remote-without-manifest"
  prepare_remote_assets "$output" "$remote"
  rm "$remote/release-manifest.json"
  expect_failure "existing release without provenance manifest fails closed" "incomplete or damaged" \
    env PATH="$FAKE_BIN:$PATH" FAKE_GH_MODE=existing FAKE_REMOTE_DIR="$remote" \
      FAKE_GH_LOG="$gh_log" FAKE_SYNC_LOG="$sync_log" \
      "$publisher" --release-dir "$output" --repo example/project --apply

  old_input="$WORK_ROOT/old-edge-input"
  old_output="$WORK_ROOT/old-edge-output"
  make_input_bundle edge edge 7777777777777777777777777777777777777777 "$old_input"
  sign_bundle "$old_input" "$old_output" >/dev/null
  remote="$WORK_ROOT/remote-old-edge"
  prepare_remote_assets "$old_output" "$remote"
  : >"$gh_log"
  result="$(PATH="$FAKE_BIN:$PATH" FAKE_GH_MODE=existing FAKE_REMOTE_DIR="$remote" \
    FAKE_GH_LOG="$gh_log" FAKE_SYNC_LOG="$sync_log" \
    "$publisher" --release-dir "$WORK_ROOT/edge-output" --repo example/project --apply)"
  [[ "$result" == *'Updated rolling pre-release upstream-edge'* ]]
  rg -q '^release upload upstream-edge .*--clobber' "$gh_log"
  rg -q '^release edit upstream-edge .*--prerelease' "$gh_log"
  pass "edge publication replaces a previously verified older source"

  : >"$gh_log"
  expect_failure "tag without release is rejected" "exists without a release" \
    env PATH="$FAKE_BIN:$PATH" FAKE_GH_MODE=tag-only FAKE_GH_LOG="$gh_log" FAKE_SYNC_LOG="$sync_log" \
      "$publisher" --release-dir "$output" --repo example/project --apply
}

make_fake_android_tools
export FAKE_CERTIFICATE_SHA256="$CERTIFICATE_SHA256"
printf 'keystore\n' >"$WORK_ROOT/release.jks"
printf 'store-password\n' >"$WORK_ROOT/store-password"
printf 'key-password\n' >"$WORK_ROOT/key-password"
chmod 600 "$WORK_ROOT/release.jks" "$WORK_ROOT/store-password" "$WORK_ROOT/key-password"

test_cli_and_workflow_contracts
test_stable_sign_and_dry_run
test_edge_sign_and_dry_run
test_failure_paths
test_apply_publication_contracts

printf '1..%d\n' "$PASSED"
