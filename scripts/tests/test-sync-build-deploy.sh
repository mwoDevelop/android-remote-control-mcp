#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT="$(cd -- "$TEST_DIR/.." && pwd)/sync-build-deploy.sh"
PASSED=0
WORK_ROOT="$(mktemp -d)"

cleanup() {
  [[ -d "$WORK_ROOT" ]] && rm -rf -- "$WORK_ROOT"
}
trap cleanup EXIT

new_repo() {
  local repo
  repo="$(mktemp -d "$WORK_ROOT/repo.XXXXXX")"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name Test
  mkdir -p "$repo/scripts" "$repo/myconf/[REDACTED_DEVICE_ALIAS]"
  cp "$SOURCE_SCRIPT" "$repo/scripts/sync-build-deploy.sh"
  chmod +x "$repo/scripts/sync-build-deploy.sh"
  printf '.env.secrets\n' >"$repo/.gitignore"
  printf 'seed\n' >"$repo/README.md"
  git -C "$repo" add .
  git -C "$repo" commit -q -m seed
  git -C "$repo" remote add upstream https://github.com/danielealbano/android-remote-control-mcp.git
  git -C "$repo" remote set-url --push upstream DISABLED
  printf '%s' "$repo"
}

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

test_help() {
  local repo output
  repo="$(new_repo)"
  output="$(cd "$repo" && scripts/sync-build-deploy.sh --help)"
  [[ "$output" == *"all validates, builds and deploys the already checked-out commit"* ]]
  [[ "$output" == *"never uninstalls"* ]]
  [[ "$output" == *"--cloudflared-ref"* ]]
  [[ "$output" == *"--latest-stable"* ]]
  [[ "$output" == *"--latest-edge"* ]]
  pass "help documents mutation and uninstall boundaries"
}

test_channel_arguments() {
  local repo
  repo="$(new_repo)"
  expect_failure "latest channel flags are mutually exclusive" "mutually exclusive" \
    bash -c "cd '$repo' && scripts/sync-build-deploy.sh build --latest-stable --latest-edge"
  expect_failure "latest channel flags belong only to build" "sync accepts only" \
    bash -c "cd '$repo' && scripts/sync-build-deploy.sh sync --latest-edge"
  expect_failure "unsigned release requires a latest channel" "requires --latest-stable or --latest-edge" \
    bash -c "cd '$repo' && scripts/sync-build-deploy.sh build --variant gmsRelease --unsigned-release"
  expect_failure "unsigned release rejects debug variants" "accepts only gmsRelease or fossRelease" \
    bash -c "cd '$repo' && scripts/sync-build-deploy.sh build --latest-edge --variant gmsDebug --unsigned-release"
  expect_failure "unsigned release rejects skipped mandatory gates" "does not allow --skip-e2e-compile" \
    bash -c "cd '$repo' && scripts/sync-build-deploy.sh build --latest-edge --variant fossRelease --unsigned-release --skip-e2e-compile"
  expect_failure "expected source SHA is a guard not a selector" "requires --latest-stable or --latest-edge" \
    bash -c "cd '$repo' && scripts/sync-build-deploy.sh build --expected-source-sha 0123456789abcdef0123456789abcdef01234567"
  expect_failure "expected source SHA must be full hexadecimal" "40-character hexadecimal" \
    bash -c "cd '$repo' && scripts/sync-build-deploy.sh channel-info --latest-edge --expected-source-sha develop"
  expect_failure "arbitrary developer channel remains unsupported" "Unknown argument: --latest-develop" \
    bash -c "cd '$repo' && scripts/sync-build-deploy.sh build --latest-develop --variant gmsRelease"
}

test_expected_source_sha_guard() {
  local output status
  eval "$(sed -n '/^assert_expected_source_sha() {/,/^}/p' "$SOURCE_SCRIPT")"
  die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
  EXPECTED_SOURCE_SHA=0123456789abcdef0123456789abcdef01234567
  assert_expected_source_sha "$EXPECTED_SOURCE_SHA"
  set +e
  output="$(assert_expected_source_sha ffffffffffffffffffffffffffffffffffffffff 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 && "$output" == *'does not match --expected-source-sha'* ]]
  pass "expected source SHA guard fails closed on channel drift"
}

test_channel_build_secret_boundary() {
  local output status
  eval "$(sed -n '/^assert_channel_build_secretless() {/,/^}/p' "$SOURCE_SCRIPT")"
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
  unset NGROK_AUTHTOKEN RELEASE_KEYSTORE_BASE64 RELEASE_KEYSTORE_PASSWORD RELEASE_KEY_ALIAS \
    RELEASE_KEY_PASSWORD GH_TOKEN GITHUB_TOKEN
  assert_channel_build_secretless
  NGROK_AUTHTOKEN=must-not-reach-upstream
  set +e
  output="$(assert_channel_build_secretless 2>&1)"
  status=$?
  set -e
  unset NGROK_AUTHTOKEN
  [[ $status -ne 0 && "$output" == *'NGROK_AUTHTOKEN'* ]]
  pass "upstream channel build rejects ngrok and signing secrets"
}

test_unsigned_apk_metadata() {
  local metadata
  eval "$(sed -n '/^apk_package_metadata() {/,/^}/p' "$SOURCE_SCRIPT")"
  resolve_android_tool() { printf fake_apkanalyzer; }
  fake_apkanalyzer() {
    case "$2" in
      application-id) printf 'com.danielealbano.androidremotecontrolmcp\n' ;;
      version-code) printf '123\n' ;;
      version-name) printf '1.2.3\n' ;;
      *) return 1 ;;
    esac
  }
  metadata="$(apk_package_metadata unsigned.apk)"
  [[ "$metadata" == $'com.danielealbano.androidremotecontrolmcp\t123\t1.2.3' ]]
  pass "unsigned APK metadata does not require a signing certificate"
}

test_secretless_test_retry_is_bounded() {
  local repo count output status previous_dir
  repo="$(new_repo)"
  eval "$(sed -n '/^run_secretless_channel_tests() {/,/^}/p' "$SOURCE_SCRIPT")"
  printf '%s\n' '#!/usr/bin/env bash' \
    'count_file="${TEST_COUNT_FILE:?}"' \
    'count=0; [[ ! -f "$count_file" ]] || count="$(<"$count_file")"' \
    'count=$((count + 1)); printf "%s" "$count" >"$count_file"' \
    '[[ "${ALWAYS_FAIL:-false}" != true && "$count" -ge 2 ]]' >"$repo/gradlew"
  chmod +x "$repo/gradlew"
  previous_dir="$PWD"
  cd "$repo"
  TEST_RETRY_OCCURRED=false
  TEST_COUNT_FILE="$repo/count" run_secretless_channel_tests test.init.gradle
  [[ "$TEST_RETRY_OCCURRED" == true && "$(<"$repo/count")" == 2 ]]
  cd "$previous_dir"

  rm "$repo/count"
  TEST_RETRY_OCCURRED=false
  set +e
  output="$(cd "$repo" && TEST_COUNT_FILE="$repo/count" ALWAYS_FAIL=true \
    run_secretless_channel_tests test.init.gradle 2>&1)"
  status=$?
  set -e
  count="$(<"$repo/count")"
  [[ $status -ne 0 && "$count" == 2 && "$output" == *'retrying the same secretless task exactly once'* ]]
  pass "secretless upstream tests retry once and deterministic failures remain fatal"
}

test_latest_stable_selection() {
  local selected
  eval "$(sed -n '/^latest_stable_tag_from_remote_listing() {/,/^}/p' "$SOURCE_SCRIPT")"
  selected="$(printf '%s\n' \
    '111 refs/tags/v1.9.0' \
    '222 refs/tags/v1.10.0' \
    '333 refs/tags/v2.0.0' \
    '444 refs/tags/v3.0.0-rc1' \
    '555 refs/tags/v2.0.0^{}' | latest_stable_tag_from_remote_listing)"
  [[ "$selected" == "v2.0.0" ]]
  pass "latest stable accepts only strict release tags and uses version order"
}

test_host_cloudflared_preparation() {
  local repo
  repo="$(new_repo)"
  mkdir -p "$repo/vendor/cloudflared"
  (
    eval "$(sed -n '/^prepare_host_cloudflared() {/,/^}/p' "$SOURCE_SCRIPT")"
    require_command() { :; }
    die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
    go() {
      [[ "$1" == "build" && "$2" == "-o" ]]
      printf '#!/usr/bin/env sh\nexit 0\n' >"$3"
      chmod +x "$3"
    }
    REPO_ROOT="$repo"
    prepare_host_cloudflared
    [[ -x "$repo/build/host-tools/cloudflared" ]]
    [[ ":$PATH:" == *":$repo/build/host-tools:"* ]]
  )
  pass "build prepares pinned host cloudflared and adds it to PATH"
}

test_go_toolchain_bootstrap() {
  local repo
  repo="$(new_repo)"
  (
    eval "$(sed -n '/^prepare_go_toolchain() {/,/^}/p' "$SOURCE_SCRIPT")"
    require_command() { :; }
    die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
    docker() {
      case "$1" in
        create) printf 'temporary-container\n' ;;
        cp)
          mkdir -p "$3/bin"
          printf '#!/usr/bin/env sh\nprintf "go version go1.26.7 linux/amd64\\n"\n' >"$3/bin/go"
          chmod +x "$3/bin/go"
          ;;
        rm) : ;;
        *) return 1 ;;
      esac
    }
    REPO_ROOT="$repo"
    BOOTSTRAP_GO_VERSION="1.26.7"
    BOOTSTRAP_GO_IMAGE="pinned-test-image"
    prepare_go_toolchain
    [[ "$(go version)" == "go version go1.26.7 linux/amd64" ]]
    [[ ":$PATH:" == *":$repo/build/host-tools/go-1.26.7/bin:"* ]]
  )
  pass "build bootstraps a pinned local Go toolchain when the host has none"
}

test_maven_toolchain_bootstrap() {
  local repo
  repo="$(new_repo)"
  (
    eval "$(sed -n '/^prepare_maven_toolchain() {/,/^}/p' "$SOURCE_SCRIPT")"
    require_command() { :; }
    die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
    docker() {
      case "$1" in
        create) printf 'temporary-container\n' ;;
        cp)
          mkdir -p "$3/bin"
          printf '#!/usr/bin/env sh\nprintf "Apache Maven 3.9.11 (test)\\n"\n' >"$3/bin/mvn"
          chmod +x "$3/bin/mvn"
          ;;
        rm) : ;;
        *) return 1 ;;
      esac
    }
    REPO_ROOT="$repo"
    BOOTSTRAP_MAVEN_VERSION="3.9.11"
    BOOTSTRAP_MAVEN_IMAGE="pinned-test-image"
    prepare_maven_toolchain
    [[ "$(mvn --version | head -1)" == "Apache Maven 3.9.11 (test)" ]]
    [[ ":$PATH:" == *":$repo/build/host-tools/maven-3.9.11/bin:"* ]]
  )
  pass "build bootstraps a pinned local Maven toolchain when the host has none"
}

test_unknown_flag() {
  local repo
  repo="$(new_repo)"
  expect_failure "unknown flags fail closed" "Unknown argument" \
    bash -c "cd '$repo' && scripts/sync-build-deploy.sh build --surprise"
}

test_sync_preview() {
  local repo output
  repo="$(new_repo)"
  output="$(cd "$repo" && scripts/sync-build-deploy.sh sync)"
  [[ "$output" == PREVIEW:* ]]
  [[ "$(git -C "$repo" branch --show-current)" == "main" ]]
  [[ "$(git -C "$repo" branch --format='%(refname:short)')" == "main" ]]
  pass "sync without apply is a non-mutating preview"
}

test_vendor_sync_preview() {
  local repo output
  repo="$(new_repo)"
  mkdir -p "$repo/vendor/cloudflared"
  git -C "$repo/vendor/cloudflared" init -q
  git -C "$repo/vendor/cloudflared" remote add origin https://github.com/cloudflare/cloudflared.git
  output="$(cd "$repo" && scripts/sync-build-deploy.sh sync --cloudflared-ref 2026.8.2)"
  [[ "$output" == *"update cloudflared to 2026.8.2"* ]]
  [[ "$(git -C "$repo" branch --show-current)" == "main" ]]
  pass "vendor sync preview is non-mutating and uses the same script"
}

test_dirty_sync() {
  local repo
  repo="$(new_repo)"
  printf 'dirty\n' >>"$repo/README.md"
  expect_failure "dirty worktree is rejected before sync fetch" "clean worktree" \
    bash -c "cd '$repo' && scripts/sync-build-deploy.sh sync --apply"
  [[ "$(git -C "$repo" branch --show-current)" == "main" ]]
}

test_wrong_upstream() {
  local repo
  repo="$(new_repo)"
  git -C "$repo" remote set-url upstream https://example.invalid/not-official.git
  expect_failure "wrong upstream URL is rejected" "not the official repository" \
    bash -c "cd '$repo' && scripts/sync-build-deploy.sh sync"
}

test_upstream_integrated_detection() {
  local repo root_sha main_sha upstream_sha
  repo="$(new_repo)"
  eval "$(sed -n '/^upstream_is_integrated() {/,/^}/p' "$SOURCE_SCRIPT")"
  REPO_ROOT="$repo"
  root_sha="$(git -C "$repo" rev-parse HEAD)"

  printf 'main\n' >"$repo/main-only.txt"
  git -C "$repo" add main-only.txt
  git -C "$repo" commit -q -m main-ahead
  main_sha="$(git -C "$repo" rev-parse HEAD)"
  upstream_is_integrated "$root_sha" "$main_sha"

  git -C "$repo" switch -q -c upstream-test "$root_sha"
  printf 'upstream\n' >"$repo/upstream-only.txt"
  git -C "$repo" add upstream-only.txt
  git -C "$repo" commit -q -m upstream-ahead
  upstream_sha="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" switch -q main
  if upstream_is_integrated "$upstream_sha" "$main_sha"; then
    printf 'not ok - divergent upstream was reported as integrated\n' >&2
    exit 1
  fi
  pass "sync detects integrated and pending upstream histories"
}

test_vendor_fast_forward_detection() {
  local repo first_sha second_sha side_sha
  repo="$(new_repo)"
  REPO_ROOT="$repo"
  eval "$(sed -n '/^vendor_ref_is_fast_forward() {/,/^}/p' "$SOURCE_SCRIPT")"
  first_sha="$(git -C "$repo" rev-parse HEAD)"
  printf 'next\n' >"$repo/next.txt"
  git -C "$repo" add next.txt
  git -C "$repo" commit -q -m next
  second_sha="$(git -C "$repo" rev-parse HEAD)"
  vendor_ref_is_fast_forward . "$first_sha" "$second_sha"

  git -C "$repo" switch -q -c side "$first_sha"
  printf 'side\n' >"$repo/side.txt"
  git -C "$repo" add side.txt
  git -C "$repo" commit -q -m side
  side_sha="$(git -C "$repo" rev-parse HEAD)"
  if vendor_ref_is_fast_forward . "$second_sha" "$side_sha"; then
    printf 'not ok - divergent vendor update was accepted\n' >&2
    exit 1
  fi
  pass "vendor updates accept only fast-forward refs"
}

test_deploy_preview() {
  local repo output
  repo="$(new_repo)"
  output="$(cd "$repo" && scripts/sync-build-deploy.sh deploy --device [REDACTED_DEVICE_ALIAS] --artifact /does/not/exist.apk)"
  [[ "$output" == *"PREVIEW:"* ]]
  [[ "$output" == *"signatures"* ]]
  pass "deploy without apply does not require or mutate an artifact/device"
}

test_all_preview_has_no_sync() {
  local repo output
  repo="$(new_repo)"
  output="$(cd "$repo" && scripts/sync-build-deploy.sh all --device [REDACTED_DEVICE_ALIAS] --variant gmsRelease)"
  [[ "$output" == *"no fetch or merge"* ]]
  [[ "$(git -C "$repo" branch --show-current)" == "main" ]]
  pass "all preview explicitly excludes fetch and merge"
}

test_ambiguous_adb() {
  local repo fake_bin secret
  repo="$(new_repo)"
  fake_bin="$(mktemp -d "$WORK_ROOT/bin.XXXXXX")"
cat >"$fake_bin/adb" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${[REDACTED_DEVICE_ALIAS]_PIN:-}" || -n "${[REDACTED_DEVICE_ALIAS]_PIN:-}" ]]; then
  printf 'unlock PIN leaked to adb child\n' >&2
  exit 77
fi
if [[ "${1:-}" == "devices" ]]; then
  printf 'List of devices attached\nserial-one\tdevice\nserial-two\tdevice\n'
  exit 0
fi
exit 99
EOF
  chmod +x "$fake_bin/adb"
  secret="$repo/myconf/[REDACTED_DEVICE_ALIAS]/.env.secrets"
  printf 'ANDROID_MCP_BEARER_TOKEN=test\nCLOUDFLARE_TUNNEL_TOKEN=test\nADB_SERIAL=\nexport [REDACTED_DEVICE_ALIAS]_PIN=987654\n' >"$secret"
  chmod 600 "$secret"
  expect_failure "ambiguous ADB selection is rejected" "ADB serial is required because 2" \
    env [REDACTED_DEVICE_ALIAS]_PIN=123456 [REDACTED_DEVICE_ALIAS]_PIN=654321 \
      bash -c "cd '$repo' && PATH='$fake_bin':\"\$PATH\" scripts/sync-build-deploy.sh check --device [REDACTED_DEVICE_ALIAS]"
}

test_secret_reader_does_not_execute_or_export_pin() {
  local repo secret value marker
  repo="$(new_repo)"
  secret="$repo/myconf/[REDACTED_DEVICE_ALIAS]/.env.secrets"
  marker="$repo/executed"
  printf 'ANDROID_MCP_BEARER_TOKEN=admin-token\nCLOUDFLARE_TUNNEL_TOKEN=tunnel-token\nexport [REDACTED_DEVICE_ALIAS]_PIN=$(touch %s)\n' "$marker" >"$secret"
  chmod 600 "$secret"
  (
    unset [REDACTED_DEVICE_ALIAS]_PIN [REDACTED_DEVICE_ALIAS]_PIN
    eval "$(sed -n '/^read_secret_variable() {/,/^}/p' "$SOURCE_SCRIPT")"
    die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
    value="$(read_secret_variable "$secret" ANDROID_MCP_BEARER_TOKEN)"
    [[ "$value" == "admin-token" ]]
    [[ -z "${[REDACTED_DEVICE_ALIAS]_PIN:-}" ]]
  )
  [[ ! -e "$marker" ]]
  pass "secret reader neither executes nor exports unrelated [REDACTED_DEVICE_ALIAS]_PIN"
}

test_ngrok_test_token_resolution() {
  local repo secret value
  repo="$(new_repo)"
  mkdir -p "$repo/myconf/[REDACTED_DEVICE_ALIAS]"
  secret="$repo/myconf/[REDACTED_DEVICE_ALIAS]/.env.secrets"
  printf 'NGROK_AUTHTOKEN=file-token\n' >"$secret"
  chmod 600 "$secret"
  (
    eval "$(sed -n '/^read_secret_variable() {/,/^}/p' "$SOURCE_SCRIPT")"
    eval "$(sed -n '/^resolve_ngrok_test_token() {/,/^}/p' "$SOURCE_SCRIPT")"
    die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
    REPO_ROOT="$repo"
    unset NGROK_AUTHTOKEN
    value="$(resolve_ngrok_test_token)"
    [[ "$value" == "file-token" ]]
    NGROK_AUTHTOKEN="environment-token"
    value="$(resolve_ngrok_test_token)"
    [[ "$value" == "environment-token" ]]
  )
  pass "build resolves the ngrok integration credential without sourcing unrelated secrets"
}

test_production_listener_safety() {
  local output status
  eval "$(sed -n '/^verify_loopback_binding() {/,/^}/p' "$SOURCE_SCRIPT")"
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
  adb_target() {
    case "$*" in
      "forward tcp:0 tcp:8080") printf '36123\n' ;;
      "forward --remove tcp:36123") return 0 ;;
      "shell ip -o -4 addr show dev wlan0 scope global")
        printf '12: wlan0 inet %s/24 brd 192.0.2.255 scope global wlan0\n' "$TEST_WIFI_IP"
        ;;
      *) return 99 ;;
    esac
  }
  require_command() { :; }
  curl() { printf '%s' "$TEST_LOOPBACK_HTTP"; }
  timeout() { [[ "$TEST_WIFI_OPEN" == true ]]; }

  TEST_LOOPBACK_HTTP=401
  TEST_WIFI_IP='192.0.2.10'
  TEST_WIFI_OPEN=false
  output="$(verify_loopback_binding)"
  [[ "$output" == *'Wi-Fi TCP port 8080 is closed'* ]]

  TEST_LOOPBACK_HTTP=000
  set +e
  output="$( (verify_loopback_binding) 2>&1 )"
  status=$?
  set -e
  [[ $status -ne 0 && "$output" == *'not reachable over the device loopback'* ]]

  TEST_LOOPBACK_HTTP=401
  TEST_WIFI_OPEN=true
  set +e
  output="$( (verify_loopback_binding) 2>&1 )"
  status=$?
  set -e
  [[ $status -ne 0 && "$output" == *'accepts TCP connections through the device Wi-Fi address'* ]]
  pass "production listener passes ADB loopback HTTP and rejects Wi-Fi exposure"
}

test_tunnel_payload_gate() {
  local output status
  eval "$(sed -n '/^validate_tunnel_payload() {/,/^}/p' "$SOURCE_SCRIPT")"
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
  require_command() { :; }
  unzip() { printf '%s\n' "$TEST_APK_ENTRIES"; }

  TEST_APK_ENTRIES=$'lib/arm64-v8a/libcloudflared.so\nlib/arm64-v8a/libngrok_java.so\nlib/x86_64/libcloudflared.so\nlib/x86_64/libngrok_java.so'
  validate_tunnel_payload test.apk

  TEST_APK_ENTRIES=$'lib/arm64-v8a/libcloudflared.so\nlib/arm64-v8a/libngrok_java.so\nlib/x86_64/libcloudflared.so'
  set +e
  output="$( (validate_tunnel_payload test.apk) 2>&1 )"
  status=$?
  set -e
  [[ $status -ne 0 && "$output" == *'lib/x86_64/libngrok_java.so'* ]]
  pass "qualified builds require Cloudflare and ngrok payloads for both supported ABIs"
}

test_apksigner_digest_compatibility() {
  local digest output status repo
  eval "$(sed -n '/^certificate_digest() {/,/^}/p' "$SOURCE_SCRIPT")"
  fake_apksigner() { printf '%s\n' "$TEST_APKSIGNER_OUTPUT"; }

  TEST_APKSIGNER_OUTPUT='Signer #1 certificate SHA-256 digest: legacy-digest'
  digest="$(certificate_digest fake_apksigner test.apk)"
  [[ "$digest" == "legacy-digest" ]]

  TEST_APKSIGNER_OUTPUT='V2 Signer: certificate SHA-256 digest: modern-digest'
  digest="$(certificate_digest fake_apksigner test.apk)"
  [[ "$digest" == "modern-digest" ]]

  TEST_APKSIGNER_OUTPUT='DOES NOT VERIFY'
  set +e
  output="$(certificate_digest fake_apksigner test.apk 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 && -z "$output" ]]

  repo="$(new_repo)"
  eval "$(sed -n '/^write_build_manifest() {/,/^}/p' "$SOURCE_SCRIPT")"
  apk_metadata() { return 1; }
  sha256sum() { printf 'deadbeef  %s\n' "$1"; }
  REPO_ROOT="$repo"
  VARIANT=gmsRelease
  set +e
  output="$(write_build_manifest test.apk true 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 && -z "$output" ]]
  pass "APK metadata accepts old and new apksigner output and fails closed"
}

test_help
test_channel_arguments
test_expected_source_sha_guard
test_channel_build_secret_boundary
test_unsigned_apk_metadata
test_secretless_test_retry_is_bounded
test_latest_stable_selection
test_go_toolchain_bootstrap
test_maven_toolchain_bootstrap
test_host_cloudflared_preparation
test_unknown_flag
test_sync_preview
test_vendor_sync_preview
test_dirty_sync
test_wrong_upstream
test_upstream_integrated_detection
test_vendor_fast_forward_detection
test_deploy_preview
test_all_preview_has_no_sync
test_ambiguous_adb
test_secret_reader_does_not_execute_or_export_pin
test_ngrok_test_token_resolution
test_production_listener_safety
test_tunnel_payload_gate
test_apksigner_digest_compatibility

printf '1..%d\n' "$PASSED"
