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
  pass "help documents mutation and uninstall boundaries"
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
if [[ "${1:-}" == "devices" ]]; then
  printf 'List of devices attached\nserial-one\tdevice\nserial-two\tdevice\n'
  exit 0
fi
exit 99
EOF
  chmod +x "$fake_bin/adb"
  secret="$repo/myconf/[REDACTED_DEVICE_ALIAS]/.env.secrets"
  printf 'ANDROID_MCP_BEARER_TOKEN=test\nCLOUDFLARE_TUNNEL_TOKEN=test\nADB_SERIAL=\n' >"$secret"
  chmod 600 "$secret"
  expect_failure "ambiguous ADB selection is rejected" "ADB serial is required because 2" \
    bash -c "cd '$repo' && PATH='$fake_bin':\"\$PATH\" scripts/sync-build-deploy.sh check --device [REDACTED_DEVICE_ALIAS]"
}

test_production_listener_safety() {
  local output status
  eval "$(sed -n '/^verify_loopback_binding() {/,/^}/p' "$SOURCE_SCRIPT")"
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
  adb_target() {
    case "$*" in
      "shell ss -ltn") printf '%s\n' "$TEST_LISTENERS" ;;
      "shell ip -o -4 addr show dev wlan0 scope global")
        printf '12: wlan0 inet %s/24 brd 192.0.2.255 scope global wlan0\n' "$TEST_WIFI_IP"
        ;;
      *) return 99 ;;
    esac
  }
  timeout() { [[ "$TEST_WIFI_OPEN" == true ]]; }

  TEST_LISTENERS='LISTEN 0 128 [::ffff:127.0.0.1]:8080 *:*'
  TEST_WIFI_IP='192.0.2.10'
  TEST_WIFI_OPEN=false
  output="$(verify_loopback_binding)"
  [[ "$output" == *'Wi-Fi TCP port 8080 is closed'* ]]

  TEST_LISTENERS='LISTEN 0 128 [::]:8080 *:*'
  set +e
  output="$( (verify_loopback_binding) 2>&1 )"
  status=$?
  set -e
  [[ $status -ne 0 && "$output" == *'exposed beyond loopback'* ]]

  TEST_LISTENERS='LISTEN 0 128 127.0.0.1:8080 *:*'
  TEST_WIFI_OPEN=true
  set +e
  output="$( (verify_loopback_binding) 2>&1 )"
  status=$?
  set -e
  [[ $status -ne 0 && "$output" == *'accepts TCP connections through the device Wi-Fi address'* ]]
  pass "production listener accepts IPv6-mapped loopback and rejects wildcard or Wi-Fi exposure"
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

test_help
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
test_production_listener_safety
test_tunnel_payload_gate

printf '1..%d\n' "$PASSED"
