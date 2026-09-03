#!/usr/bin/env bash
set -euo pipefail

# Unlock credentials are consumed only by the dedicated provisioning scripts and must never
# reach Git, build, network, ADB, or deployment child processes through an inherited environment.
unset ARCP_DEVICE_UNLOCK_PIN

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${ARCP_REPO_ROOT_OVERRIDE:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)}"
source "$SCRIPT_DIR/lib/arcp-config-root.sh"
PACKAGE_ID="com.danielealbano.androidremotecontrolmcp"
OFFICIAL_UPSTREAM="https://github.com/danielealbano/android-remote-control-mcp.git"
OWNER_REPOSITORY="https://github.com/mwoDevelop/android-remote-control-mcp.git"
DEFAULT_VARIANT="gmsRelease"
BOOTSTRAP_GO_VERSION="1.26.7"
BOOTSTRAP_GO_IMAGE="golang@sha256:b17af760035fc2f338eed92d448a6c67f2d45438844fc6c60678fa5f99e44b57"
BOOTSTRAP_MAVEN_VERSION="3.9.11"
BOOTSTRAP_MAVEN_IMAGE="maven@sha256:922927df2c662cdd47ddb116443d6bec4696cfae3de1a0ddac8fcc7b87ce61ae"
APPLY=false
DEVICE=""
CONFIG_ROOT=""
SERIAL=""
VARIANT="$DEFAULT_VARIANT"
ARTIFACT=""
UPSTREAM_REF="upstream/main"
CLOUDFLARED_REF=""
NGROK_REF=""
LATEST_STABLE=false
LATEST_EDGE=false
UNSIGNED_RELEASE=false
EXPECTED_SOURCE_SHA=""
EXPECTED_LOCAL_SHA=""
VERSION_CODE_OVERRIDE=""
VERSION_NAME_OVERRIDE=""
SKIP_E2E=false
TEST_RETRY_OCCURRED=false
COMMAND="${1:-}"
shift || true

usage() {
  cat <<'EOF'
Usage:
  scripts/sync-build-deploy.sh check  --profile <name> [--config-root <absolute-directory>] [--serial <adb-serial>]
  scripts/sync-build-deploy.sh sync   [--upstream-ref upstream/main]
                                      [--cloudflared-ref <tag-or-origin/ref>]
                                      [--ngrok-ref <origin/ref>] --apply
  scripts/sync-build-deploy.sh build  [--variant gmsDebug|fossDebug|gmsRelease|fossRelease]
                                      [--latest-stable|--latest-edge] [--expected-source-sha <sha>]
                                      [--expected-local-sha <sha>] [--version-code <code>]
                                      [--version-name <name>]
                                      [--unsigned-release] [--skip-e2e-compile]
  scripts/sync-build-deploy.sh channel-info (--latest-stable|--latest-edge)
                                      [--expected-source-sha <sha>]
  scripts/sync-build-deploy.sh deploy --profile <name> --artifact <apk> [--config-root <absolute-directory>] [--serial <adb-serial>] --apply
  scripts/sync-build-deploy.sh all    --profile <name> [--config-root <absolute-directory>] [--variant ...] [--serial <adb-serial>] --apply
  scripts/sync-build-deploy.sh rollback --profile <name> --artifact <known-good-apk> [--config-root <absolute-directory>] [--serial <adb-serial>] --apply

Safety contract:
  check is read-only. sync fetches upstream and creates a review branch only when new commits exist;
  it exits without creating a branch when upstream is already integrated, and never deploys.
  all validates, builds and deploys the already checked-out commit; it never fetches or merges.
  build --latest-stable/--latest-edge resolves the official baseline but builds the reviewed
  origin/release/<channel> local integration in an isolated worktree; it never builds pure upstream,
  changes main, updates a release branch or deploys the artifact.
  --unsigned-release is limited to latest-channel Release builds. It runs the secretless upstream
  mirror qualification profile and emits a portable pre-sign manifest for trusted post-build signing.
  sync/deploy/all/rollback print a preview and make no changes without literal --apply.
  Deployment never uninstalls an app, bypasses signature checks, grants Restricted Settings,
  automates privileged services, or changes parental-control policy. --device remains a deprecated alias
  for --profile during one migration cycle; no device mapping is stored in this repository.

Examples:
  scripts/sync-build-deploy.sh check --profile phone --config-root /absolute/private/devices --serial SERIAL
  scripts/sync-build-deploy.sh sync --upstream-ref upstream/main --apply
  scripts/sync-build-deploy.sh sync --cloudflared-ref 2026.8.2 --apply
  scripts/sync-build-deploy.sh build --variant gmsDebug
  scripts/sync-build-deploy.sh build --latest-stable --variant gmsDebug
  scripts/sync-build-deploy.sh build --latest-edge --variant gmsRelease --unsigned-release
  scripts/sync-build-deploy.sh channel-info --latest-edge --expected-source-sha 0123456789abcdef0123456789abcdef01234567
  scripts/sync-build-deploy.sh all --profile phone --config-root /absolute/private/devices --variant gmsRelease --serial SERIAL --apply
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is unavailable: $1"
}

parse_args() {
  while (($#)); do
    case "$1" in
      --profile|--device) (($# >= 2)) || die "$1 requires a value"; DEVICE="$2"; shift 2 ;;
      --config-root) (($# >= 2)) || die "--config-root requires a value"; CONFIG_ROOT="$2"; shift 2 ;;
      --serial) (($# >= 2)) || die "--serial requires a value"; SERIAL="$2"; shift 2 ;;
      --variant) (($# >= 2)) || die "--variant requires a value"; VARIANT="$2"; shift 2 ;;
      --artifact) (($# >= 2)) || die "--artifact requires a value"; ARTIFACT="$2"; shift 2 ;;
      --upstream-ref) (($# >= 2)) || die "--upstream-ref requires a value"; UPSTREAM_REF="$2"; shift 2 ;;
      --cloudflared-ref) (($# >= 2)) || die "--cloudflared-ref requires a value"; CLOUDFLARED_REF="$2"; shift 2 ;;
      --ngrok-ref) (($# >= 2)) || die "--ngrok-ref requires a value"; NGROK_REF="$2"; shift 2 ;;
      --latest-stable) LATEST_STABLE=true; shift ;;
      --latest-edge) LATEST_EDGE=true; shift ;;
      --unsigned-release) UNSIGNED_RELEASE=true; shift ;;
      --expected-source-sha)
        (($# >= 2)) || die "--expected-source-sha requires a value"
        EXPECTED_SOURCE_SHA="${2,,}"
        shift 2
        ;;
      --expected-local-sha)
        (($# >= 2)) || die "--expected-local-sha requires a value"
        EXPECTED_LOCAL_SHA="${2,,}"
        shift 2
        ;;
      --version-code) (($# >= 2)) || die "--version-code requires a value"; VERSION_CODE_OVERRIDE="$2"; shift 2 ;;
      --version-name) (($# >= 2)) || die "--version-name requires a value"; VERSION_NAME_OVERRIDE="$2"; shift 2 ;;
      --skip-e2e-compile) SKIP_E2E=true; shift ;;
      --apply) APPLY=true; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

validate_contract() {
  [[ "$LATEST_STABLE" == false || "$LATEST_EDGE" == false ]] ||
    die "--latest-stable and --latest-edge are mutually exclusive"
  [[ -z "$EXPECTED_SOURCE_SHA" || "$EXPECTED_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] ||
    die "--expected-source-sha must be a full 40-character hexadecimal commit SHA"
  [[ -z "$EXPECTED_LOCAL_SHA" || "$EXPECTED_LOCAL_SHA" =~ ^[0-9a-f]{40}$ ]] ||
    die "--expected-local-sha must be a full 40-character hexadecimal commit SHA"
  [[ -z "$EXPECTED_SOURCE_SHA" || "$LATEST_STABLE" == true || "$LATEST_EDGE" == true ]] ||
    die "--expected-source-sha requires --latest-stable or --latest-edge"
  [[ -z "$EXPECTED_LOCAL_SHA" || "$LATEST_STABLE" == true || "$LATEST_EDGE" == true ]] ||
    die "--expected-local-sha requires --latest-stable or --latest-edge"
  [[ -z "$VERSION_CODE_OVERRIDE" || "$VERSION_CODE_OVERRIDE" =~ ^[1-9][0-9]*$ ]] ||
    die "--version-code must be a positive integer"
  [[ -z "$VERSION_CODE_OVERRIDE" || "$VERSION_CODE_OVERRIDE" -le 2100000000 ]] ||
    die "--version-code exceeds Android's maximum"
  [[ -z "$VERSION_NAME_OVERRIDE" || "$VERSION_NAME_OVERRIDE" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] ||
    die "Invalid --version-name"
  case "$COMMAND" in
    check)
      [[ -n "$DEVICE" ]] || die "check requires --device"
      [[ "$APPLY" == false ]] || die "check does not accept --apply"
      [[ "$VARIANT" == "$DEFAULT_VARIANT" && -z "$ARTIFACT" && "$UPSTREAM_REF" == "upstream/main" &&
         -z "$CLOUDFLARED_REF" && -z "$NGROK_REF" && "$LATEST_STABLE" == false && "$LATEST_EDGE" == false &&
         "$UNSIGNED_RELEASE" == false && -z "$EXPECTED_SOURCE_SHA" && -z "$EXPECTED_LOCAL_SHA" &&
         -z "$VERSION_CODE_OVERRIDE" && -z "$VERSION_NAME_OVERRIDE" && "$SKIP_E2E" == false ]] ||
        die "check received an option that belongs to another command"
      ;;
    sync)
      [[ -z "$DEVICE" && -z "$CONFIG_ROOT" && -z "$SERIAL" && -z "$ARTIFACT" && "$VARIANT" == "$DEFAULT_VARIANT" &&
         "$LATEST_STABLE" == false && "$LATEST_EDGE" == false && "$UNSIGNED_RELEASE" == false &&
         -z "$EXPECTED_SOURCE_SHA" && -z "$EXPECTED_LOCAL_SHA" && -z "$VERSION_CODE_OVERRIDE" &&
         -z "$VERSION_NAME_OVERRIDE" && "$SKIP_E2E" == false ]] ||
        die "sync accepts only upstream refs and --apply"
      [[ "$UPSTREAM_REF" =~ ^upstream/[A-Za-z0-9._/-]+$ ]] || die "--upstream-ref must name a ref below upstream/"
      [[ -z "$CLOUDFLARED_REF" || "$CLOUDFLARED_REF" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Invalid --cloudflared-ref"
      [[ -z "$NGROK_REF" || "$NGROK_REF" =~ ^origin/[A-Za-z0-9._/-]+$ ]] ||
        die "--ngrok-ref must name a ref below the maintained origin/ fork"
      ;;
    build)
      [[ -z "$DEVICE" && -z "$CONFIG_ROOT" && -z "$SERIAL" && -z "$ARTIFACT" && "$UPSTREAM_REF" == "upstream/main" &&
         -z "$CLOUDFLARED_REF" && -z "$NGROK_REF" && "$APPLY" == false ]] ||
        die "build accepts only --variant, channel build options and --skip-e2e-compile"
      if [[ "$UNSIGNED_RELEASE" == true ]]; then
        [[ "$LATEST_STABLE" == true || "$LATEST_EDGE" == true ]] ||
          die "--unsigned-release requires --latest-stable or --latest-edge"
        [[ "$VARIANT" == gmsRelease || "$VARIANT" == fossRelease ]] ||
          die "--unsigned-release accepts only gmsRelease or fossRelease"
        [[ "$SKIP_E2E" == false ]] || die "--unsigned-release does not allow --skip-e2e-compile"
        [[ -n "$VERSION_CODE_OVERRIDE" && -n "$VERSION_NAME_OVERRIDE" ]] ||
          die "--unsigned-release requires ledger-backed --version-code and explicit --version-name"
      fi
      ;;
    channel-info)
      [[ -z "$DEVICE" && -z "$CONFIG_ROOT" && -z "$SERIAL" && -z "$ARTIFACT" && "$VARIANT" == "$DEFAULT_VARIANT" &&
         "$UPSTREAM_REF" == "upstream/main" && -z "$CLOUDFLARED_REF" && -z "$NGROK_REF" &&
         "$APPLY" == false && "$UNSIGNED_RELEASE" == false && "$SKIP_E2E" == false &&
         -z "$VERSION_CODE_OVERRIDE" && -z "$VERSION_NAME_OVERRIDE" ]] ||
        die "channel-info accepts only one latest channel flag and expected SHA guards"
      [[ "$LATEST_STABLE" == true || "$LATEST_EDGE" == true ]] ||
        die "channel-info requires --latest-stable or --latest-edge"
      ;;
    deploy|rollback)
      [[ -n "$DEVICE" && -n "$ARTIFACT" ]] || die "$COMMAND requires --device and --artifact"
      [[ "$VARIANT" == "$DEFAULT_VARIANT" && "$UPSTREAM_REF" == "upstream/main" && -z "$CLOUDFLARED_REF" &&
         -z "$NGROK_REF" && "$LATEST_STABLE" == false && "$LATEST_EDGE" == false &&
         "$UNSIGNED_RELEASE" == false && -z "$EXPECTED_SOURCE_SHA" && -z "$EXPECTED_LOCAL_SHA" &&
         -z "$VERSION_CODE_OVERRIDE" && -z "$VERSION_NAME_OVERRIDE" && "$SKIP_E2E" == false ]] ||
        die "$COMMAND received an option that belongs to another command"
      ;;
    all)
      [[ -n "$DEVICE" ]] || die "all requires --device"
      [[ -z "$ARTIFACT" && "$UPSTREAM_REF" == "upstream/main" && -z "$CLOUDFLARED_REF" &&
         -z "$NGROK_REF" && "$LATEST_STABLE" == false && "$LATEST_EDGE" == false &&
         "$UNSIGNED_RELEASE" == false && -z "$EXPECTED_SOURCE_SHA" && -z "$EXPECTED_LOCAL_SHA" &&
         -z "$VERSION_CODE_OVERRIDE" && -z "$VERSION_NAME_OVERRIDE" && "$SKIP_E2E" == false ]] ||
        die "all does not accept --artifact, --upstream-ref or --skip-e2e-compile"
      ;;
    help|--help|-h|"") usage; exit 0 ;;
    *) die "Unknown command: $COMMAND" ;;
  esac

  [[ -z "$DEVICE" || "$DEVICE" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || die "Invalid profile name"
  case "$VARIANT" in gmsDebug|fossDebug|gmsRelease|fossRelease) ;; *) die "Unknown variant: $VARIANT" ;; esac
}

device_config() {
  ensure_profile
  arcp_profile_path android_config
}

device_secret_file() {
  ensure_profile
  arcp_profile_path secrets
}

ensure_profile() {
  if [[ -z "${ARCP_PROFILE_ROOT:-}" ]]; then
    ARCP_PROFILE_VALIDATOR="$SCRIPT_DIR/validate-device-profiles.mjs" arcp_load_profile "$CONFIG_ROOT" "$DEVICE" ||
      die "Cannot load external device profile"
  fi
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

resolve_android_tool() {
  local name="$1" found=""
  if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return; fi
  if [[ -n "${ANDROID_HOME:-}" ]]; then
    found="$(find "$ANDROID_HOME" -type f -name "$name" -perm -u+x 2>/dev/null | sort -V | tail -1)"
  fi
  [[ -n "$found" ]] || die "Cannot find $name; add it to PATH or set ANDROID_HOME"
  printf '%s' "$found"
}

read_secret_variable() {
  local file="$1" variable="$2" line raw="" matches=0
  [[ "$variable" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "Invalid secret variable name"
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "$variable="*)
        raw="${line#*=}"
        matches=$((matches + 1))
        ;;
      "export $variable="*)
        raw="${line#*=}"
        matches=$((matches + 1))
        ;;
    esac
  done <"$file"
  ((matches <= 1)) || die "Duplicate $variable assignment in device secrets file"
  ((matches == 1)) || return 0
  if [[ "$raw" == \'*\' && "$raw" == *\' && ${#raw} -ge 2 ]]; then
    raw="${raw:1:${#raw}-2}"
  elif [[ "$raw" == \"*\" && "$raw" == *\" && ${#raw} -ge 2 ]]; then
    raw="${raw:1:${#raw}-2}"
  fi
  printf '%s' "$raw"
}

resolve_ngrok_test_token() {
  local token="${NGROK_AUTHTOKEN:-}"
  [[ -n "$token" ]] || die "NGROK_AUTHTOKEN is unset; ordinary live integration tests require it explicitly"
  printf '%s' "$token"
}

validate_secret_file() {
  local file relative
  file="$(device_secret_file)"
  [[ -f "$file" && ! -L "$file" ]] || die "Missing regular device secrets file"
  [[ "$(stat -c '%a' "$file")" == "600" ]] || die "Device secrets file must have mode 0600"
  if [[ "$file" == "$REPO_ROOT/"* ]]; then
    relative="${file#"$REPO_ROOT/"}"
    ! git -C "$REPO_ROOT" ls-files --error-unmatch -- "$relative" >/dev/null 2>&1 || die "Device secrets file is tracked by the public repository"
  fi
  [[ -n "$(read_secret_variable "$file" ANDROID_MCP_BEARER_TOKEN)" ]] || die "ANDROID_MCP_BEARER_TOKEN is empty"
  [[ -n "$(read_secret_variable "$file" CLOUDFLARE_TUNNEL_TOKEN)" ]] || die "CLOUDFLARE_TUNNEL_TOKEN is empty"
}

resolve_serial() {
  local file configured=""
  if [[ -z "$SERIAL" ]]; then
    file="$(device_secret_file)"
    if [[ -r "$file" ]]; then configured="$(read_secret_variable "$file" ADB_SERIAL)"; fi
    SERIAL="$configured"
  fi
  if [[ -z "$SERIAL" ]]; then
    mapfile -t connected < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
    ((${#connected[@]} == 1)) || die "ADB serial is required because ${#connected[@]} authorized devices are connected"
    SERIAL="${connected[0]}"
  fi
}

adb_target() {
  adb -s "$SERIAL" "$@"
}

verify_device_identity() {
  local config expected_manufacturer expected_model expected_device actual_manufacturer actual_model actual_device
  config="$(device_config)"
  [[ -r "$config" ]] || die "Missing device config: $config"
  ensure_profile
  expected_manufacturer="$(arcp_profile_value android_identity.manufacturer)"
  expected_model="$(arcp_profile_value android_identity.model)"
  expected_device="$(arcp_profile_value android_identity.device)"
  adb_target get-state >/dev/null
  actual_manufacturer="$(adb_target shell getprop ro.product.manufacturer | tr -d '\r')"
  actual_model="$(adb_target shell getprop ro.product.model | tr -d '\r')"
  actual_device="$(adb_target shell getprop ro.product.device | tr -d '\r')"
  [[ "${actual_manufacturer,,}" == "${expected_manufacturer,,}" ]] || die "Device manufacturer mismatch"
  [[ "$actual_model" == "$expected_model" ]] || die "Device model mismatch"
  [[ "$actual_device" == "$expected_device" ]] || die "Android device codename mismatch"
  [[ "$(adb_target shell getprop ro.kernel.qemu | tr -d '\r')" != "1" ]] || die "Emulators are not valid deployment targets"
  printf 'OK: target identity matches %s (%s/%s).\n' "$DEVICE" "$expected_model" "$expected_device"
}

check_device() {
  require_command node
  require_command adb
  resolve_serial
  verify_device_identity
  validate_secret_file
  printf 'OK: read-only device preflight passed for %s on explicit serial %s.\n' "$DEVICE" "$SERIAL"
}

require_clean_worktree() {
  [[ -z "$(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all)" ]] ||
    die "A completely clean worktree is required"
}

verify_upstream_remote() {
  local fetch_url push_url
  fetch_url="$(git -C "$REPO_ROOT" remote get-url upstream 2>/dev/null)" || die "Missing upstream remote"
  push_url="$(git -C "$REPO_ROOT" remote get-url --push upstream 2>/dev/null)" || die "Missing upstream push URL"
  [[ "$fetch_url" == "$OFFICIAL_UPSTREAM" ]] || die "upstream fetch URL is not the official repository"
  [[ "$push_url" == "DISABLED" ]] || die "upstream push URL must be DISABLED"
}

upstream_is_integrated() {
  local upstream_sha="$1" base_sha="$2"
  git -C "$REPO_ROOT" merge-base --is-ancestor "$upstream_sha" "$base_sha"
}

verify_vendor_remote() {
  local path="$1" remote="$2" expected_url="$3" fetch_url
  fetch_url="$(git -C "$REPO_ROOT/$path" remote get-url "$remote" 2>/dev/null)" ||
    die "Missing $remote remote in $path"
  [[ "$fetch_url" == "$expected_url" ]] || die "$path $remote URL is not the expected repository"
}

vendor_ref_is_fast_forward() {
  local path="$1" current_sha="$2" target_sha="$3"
  git -C "$REPO_ROOT/$path" merge-base --is-ancestor "$current_sha" "$target_sha"
}

resolve_vendor_ref() {
  local path="$1" remote="$2" ref="$3"
  git -C "$REPO_ROOT/$path" fetch "$remote" --prune --tags
  git -C "$REPO_ROOT/$path" rev-parse --verify "$ref^{commit}"
}

sync_upstream() {
  verify_upstream_remote
  [[ -z "$CLOUDFLARED_REF" ]] ||
    verify_vendor_remote vendor/cloudflared origin https://github.com/cloudflare/cloudflared.git
  [[ -z "$NGROK_REF" ]] ||
    verify_vendor_remote vendor/ngrok-java origin https://github.com/danielealbano/ngrok-java.git
  if [[ "$APPLY" == false ]]; then
    printf 'PREVIEW: require clean main, fetch and merge %s only when pending' "$UPSTREAM_REF"
    [[ -z "$CLOUDFLARED_REF" ]] || printf ', update cloudflared to %s' "$CLOUDFLARED_REF"
    [[ -z "$NGROK_REF" ]] || printf ', update ngrok-java to %s' "$NGROK_REF"
    printf '; create one sync/upstream-TIMESTAMP review branch only when changes exist.\n'
    return
  fi
  require_clean_worktree
  [[ "$(git -C "$REPO_ROOT" branch --show-current)" == "main" ]] || die "sync must start from local main"
  git -C "$REPO_ROOT" fetch upstream --prune
  local remote_ref="refs/remotes/$UPSTREAM_REF" upstream_sha base_sha branch
  local cloudflared_current="" cloudflared_target="" ngrok_current="" ngrok_target=""
  local app_pending=false cloudflared_pending=false ngrok_pending=false
  upstream_sha="$(git -C "$REPO_ROOT" rev-parse --verify "$remote_ref^{commit}")" || die "Cannot resolve $UPSTREAM_REF"
  base_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  upstream_is_integrated "$upstream_sha" "$base_sha" || app_pending=true

  if [[ -n "$CLOUDFLARED_REF" ]]; then
    cloudflared_current="$(git -C "$REPO_ROOT/vendor/cloudflared" rev-parse HEAD)"
    cloudflared_target="$(resolve_vendor_ref vendor/cloudflared origin "$CLOUDFLARED_REF")" ||
      die "Cannot resolve cloudflared ref $CLOUDFLARED_REF"
    if [[ "$cloudflared_current" != "$cloudflared_target" ]]; then
      vendor_ref_is_fast_forward vendor/cloudflared "$cloudflared_current" "$cloudflared_target" ||
        die "cloudflared update is not a fast-forward from the pinned commit"
      cloudflared_pending=true
    fi
  fi

  if [[ -n "$NGROK_REF" ]]; then
    ngrok_current="$(git -C "$REPO_ROOT/vendor/ngrok-java" rev-parse HEAD)"
    ngrok_target="$(resolve_vendor_ref vendor/ngrok-java origin "$NGROK_REF")" ||
      die "Cannot resolve ngrok-java ref $NGROK_REF"
    if [[ "$ngrok_current" != "$ngrok_target" ]]; then
      vendor_ref_is_fast_forward vendor/ngrok-java "$ngrok_current" "$ngrok_target" ||
        die "ngrok-java update is not a fast-forward; merge upstream in the maintained fork first"
      ngrok_pending=true
    fi
  fi

  if [[ "$app_pending" == false && "$cloudflared_pending" == false && "$ngrok_pending" == false ]]; then
    printf 'Already up to date: requested upstream refs are integrated; no review branch created.\n'
    return
  fi
  branch="sync/upstream-$(date +%Y%m%d-%H%M%S)"
  git -C "$REPO_ROOT" switch -c "$branch"
  if [[ "$app_pending" == true ]] && ! git -C "$REPO_ROOT" merge --no-ff "$upstream_sha"; then
    printf 'Merge conflict preserved on %s. Resolve manually, commit, test, then open a PR. No abort/reset was run.\n' "$branch" >&2
    exit 1
  fi
  if [[ "$cloudflared_pending" == true ]]; then
    git -C "$REPO_ROOT/vendor/cloudflared" switch --detach "$cloudflared_target"
    git -C "$REPO_ROOT" add vendor/cloudflared
  fi
  if [[ "$ngrok_pending" == true ]]; then
    git -C "$REPO_ROOT/vendor/ngrok-java" switch --detach "$ngrok_target"
    git -C "$REPO_ROOT" add vendor/ngrok-java
  fi
  if ! git -C "$REPO_ROOT" diff --cached --quiet; then
    git -C "$REPO_ROOT" commit -m "chore: update vendored upstreams"
  fi
  printf 'Sync branch ready for review: %s\nbase=%s\nupstream=%s\nmerge=%s\n' \
    "$branch" "$base_sha" "$upstream_sha" "$(git -C "$REPO_ROOT" rev-parse HEAD)"
  printf 'Review the diff and open a PR; this script does not merge to main or push.\n'
}

variant_parts() {
  case "$VARIANT" in
    gmsDebug) FLAVOR=gms; BUILD_TYPE=debug ;;
    fossDebug) FLAVOR=foss; BUILD_TYPE=debug ;;
    gmsRelease) FLAVOR=gms; BUILD_TYPE=release ;;
    fossRelease) FLAVOR=foss; BUILD_TYPE=release ;;
  esac
}

latest_stable_tag_from_remote_listing() {
  awk '$2 ~ /^refs\/tags\/v[0-9]+\.[0-9]+\.[0-9]+$/ {sub("refs/tags/", "", $2); print $2}' |
    sort -V |
    tail -1
}

resolve_upstream_channel() {
  local channel="$1" channel_ref label sha
  verify_upstream_remote
  require_command git
  case "$channel" in
    stable)
      label="$(git -C "$REPO_ROOT" ls-remote --tags --refs upstream 'refs/tags/v*' |
        latest_stable_tag_from_remote_listing)"
      [[ -n "$label" ]] || die "Official upstream has no stable vMAJOR.MINOR.PATCH tag"
      channel_ref="refs/arcp-upstream-channels/stable"
      git -C "$REPO_ROOT" fetch upstream "+refs/tags/$label:$channel_ref"
      ;;
    edge)
      label="edge"
      channel_ref="refs/arcp-upstream-channels/edge"
      git -C "$REPO_ROOT" fetch upstream "+refs/tags/edge:$channel_ref"
      ;;
    *) die "Unknown upstream channel: $channel" ;;
  esac
  sha="$(git -C "$REPO_ROOT" rev-parse --verify "$channel_ref^{commit}")" ||
    die "Cannot resolve latest $channel commit"
  printf '%s\t%s\n' "$label" "$sha"
}

assert_expected_source_sha() {
  local actual_sha="${1,,}"
  [[ -z "$EXPECTED_SOURCE_SHA" || "$actual_sha" == "$EXPECTED_SOURCE_SHA" ]] ||
    die "Resolved upstream source $actual_sha does not match --expected-source-sha $EXPECTED_SOURCE_SHA"
}

verify_owner_remote() {
  local fetch_url
  fetch_url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)" || die "Missing origin remote"
  [[ "$fetch_url" == "$OWNER_REPOSITORY" ]] || die "origin fetch URL is not the owner repository"
}

resolve_local_channel() {
  local channel="$1" branch remote_ref sha
  verify_owner_remote
  branch="release/$channel"
  remote_ref="refs/arcp-owner-channels/$channel"
  git -C "$REPO_ROOT" fetch --no-tags origin "+refs/heads/$branch:$remote_ref" >/dev/null
  sha="$(git -C "$REPO_ROOT" rev-parse --verify "$remote_ref^{commit}")" ||
    die "Cannot resolve reviewed owner branch $branch"
  printf '%s\t%s\n' "$branch" "$sha"
}

assert_expected_local_sha() {
  local actual_sha="${1,,}"
  [[ -z "$EXPECTED_LOCAL_SHA" || "$actual_sha" == "$EXPECTED_LOCAL_SHA" ]] ||
    die "Resolved local source $actual_sha does not match --expected-local-sha $EXPECTED_LOCAL_SHA"
}

verify_channel_ancestry() {
  local channel="$1" upstream_sha="$2" local_sha="$3" edge_label edge_sha
  git -C "$REPO_ROOT" merge-base --is-ancestor "$upstream_sha" "$local_sha" ||
    die "release/$channel does not contain the resolved official $channel baseline"
  if [[ "$channel" == stable ]]; then
    IFS=$'\t' read -r edge_label edge_sha < <(resolve_upstream_channel edge)
    if git -C "$REPO_ROOT" merge-base --is-ancestor "$edge_sha" "$local_sha"; then
      die "release/stable contains the official edge baseline and is not a stable integration"
    fi
  fi
}

channel_info() {
  local channel label source_sha local_ref local_sha
  if [[ "$LATEST_STABLE" == true ]]; then channel=stable; else channel=edge; fi
  IFS=$'\t' read -r label source_sha < <(resolve_upstream_channel "$channel")
  IFS=$'\t' read -r local_ref local_sha < <(resolve_local_channel "$channel")
  assert_expected_source_sha "$source_sha"
  assert_expected_local_sha "$local_sha"
  verify_channel_ancestry "$channel" "$source_sha" "$local_sha"
  node -e '
    const [channel,label,upstreamSha,localRef,localSha]=process.argv.slice(1);
    process.stdout.write(JSON.stringify({schema_version:2,channel,upstream_label:label,upstream_sha:upstreamSha,
      local_ref:localRef,local_sha:localSha})+"\n");
  ' "$channel" "$label" "$source_sha" "$local_ref" "$local_sha"
}

build_upstream_channel() (
  local channel label source_sha short_sha local_ref local_sha local_short_sha channel_temp_dir channel_worktree
  local final_label final_sha final_local_ref final_local_sha feature_contract_sha submodules_json native_payload_json
  local source_apk output_dir output_apk output_manifest sha metadata qualified signed output_suffix manifest_type
  local child_manifest test_retry_occurred=false
  local -a child_args child_manifests
  channel="$1"
  require_clean_worktree
  IFS=$'\t' read -r label source_sha < <(resolve_upstream_channel "$channel")
  IFS=$'\t' read -r local_ref local_sha < <(resolve_local_channel "$channel")
  assert_expected_source_sha "$source_sha"
  assert_expected_local_sha "$local_sha"
  verify_channel_ancestry "$channel" "$source_sha" "$local_sha"
  short_sha="${source_sha:0:12}"
  local_short_sha="${local_sha:0:12}"
  channel_temp_dir="$(mktemp -d "/tmp/arcp-$channel-build.XXXXXX")"
  channel_worktree="$channel_temp_dir/worktree"

  cleanup_channel_build() {
    if [[ -d "$channel_worktree" ]]; then
      git -C "$channel_worktree" submodule deinit --force --all >/dev/null 2>&1 || true
      git -C "$REPO_ROOT" worktree remove --force "$channel_worktree" >/dev/null 2>&1 || true
    fi
    [[ ! -d "$channel_temp_dir" ]] || rm -rf -- "$channel_temp_dir"
  }
  trap cleanup_channel_build EXIT

  git -C "$REPO_ROOT" worktree add --detach "$channel_worktree" "$local_sha"
  git -C "$channel_worktree" submodule update --init --recursive
  feature_contract_sha="$(node "$SCRIPT_DIR/verify-arcp-channel-features.mjs" "$channel_worktree" "$channel" hash)" ||
    die "ARCP owner feature contract failed for $channel"
  native_payload_json="$(node "$channel_worktree/scripts/native-tunnel-payloads.mjs" "$channel_worktree" summary)" ||
    die "ARCP native payload contract failed for $channel"
  submodules_json="$(git -C "$channel_worktree" submodule status --recursive | node -e '
    const fs=require("fs"), result={};
    for (const line of fs.readFileSync(0,"utf8").trim().split("\n").filter(Boolean)) {
      const match=line.match(/^[ +\-U]?([0-9a-f]{40})\s+(\S+)/);
      if (!match || result[match[2]]) process.exit(2);
      result[match[2]]=match[1];
    }
    process.stdout.write(JSON.stringify(result));
  ')" || die "Cannot record exact submodule provenance"

  qualified=true
  if [[ "$SKIP_E2E" == true ]]; then qualified=false; fi
  child_args=(build --variant "$VARIANT")
  [[ -z "$VERSION_CODE_OVERRIDE" ]] || child_args+=(--version-code "$VERSION_CODE_OVERRIDE")
  [[ -z "$VERSION_NAME_OVERRIDE" ]] || child_args+=(--version-name "$VERSION_NAME_OVERRIDE")
  if [[ "$SKIP_E2E" == true ]]; then child_args+=(--skip-e2e-compile); fi
  if ! env -u NGROK_AUTHTOKEN -u RELEASE_KEYSTORE_BASE64 -u RELEASE_KEYSTORE_PASSWORD \
    -u RELEASE_KEY_ALIAS -u RELEASE_KEY_PASSWORD -u GH_TOKEN -u GITHUB_TOKEN \
    ARCP_REPO_ROOT_OVERRIDE="$channel_worktree" \
    ARCP_FORK_CHANNEL_BUILD=true \
    ARCP_CHANNEL_UNSIGNED_RELEASE="$UNSIGNED_RELEASE" \
    "$SCRIPT_DIR/sync-build-deploy.sh" "${child_args[@]}"; then
    die "Latest $channel build failed for $label ($source_sha)"
  fi

  IFS=$'\t' read -r final_label final_sha < <(resolve_upstream_channel "$channel")
  IFS=$'\t' read -r final_local_ref final_local_sha < <(resolve_local_channel "$channel")
  [[ "$final_label" == "$label" && "$final_sha" == "$source_sha" ]] ||
    die "Upstream $channel moved during the build: $label/$source_sha -> $final_label/$final_sha"
  [[ "$final_local_ref" == "$local_ref" && "$final_local_sha" == "$local_sha" ]] ||
    die "Owner $channel integration moved during the build: $local_ref/$local_sha -> $final_local_ref/$final_local_sha"

  variant_parts
  mapfile -t channel_apks < <(
    find "$channel_worktree/app/build/outputs/apk/$FLAVOR/$BUILD_TYPE" -maxdepth 1 -type f -name '*.apk' | sort
  )
  ((${#channel_apks[@]} == 1)) || die "Expected exactly one $channel APK, found ${#channel_apks[@]}"
  source_apk="${channel_apks[0]}"
  output_dir="$REPO_ROOT/build/channels/$channel"
  signed=true
  output_suffix=""
  manifest_type="arcp_channel_build"
  if [[ "$UNSIGNED_RELEASE" == true ]]; then
    signed=false
    output_suffix="-unsigned"
    manifest_type="arcp_channel_pre_sign"
  fi
  output_apk="$output_dir/android-remote-control-mcp-arcp-$channel-${VARIANT}-${short_sha}-${local_short_sha}${output_suffix}.apk"
  output_manifest="$output_dir/manifest-${VARIANT}-${short_sha}-${local_short_sha}.json"
  mkdir -p "$output_dir"
  cp "$source_apk" "$output_apk"
  sha="$(sha256sum "$output_apk" | awk '{print $1}')"
  if [[ "$signed" == true ]]; then
    metadata="$(apk_metadata "$output_apk")"
  else
    metadata="$(apk_package_metadata "$output_apk")"
    mapfile -t child_manifests < <(
      find "$channel_worktree/build/deployments" -maxdepth 1 -type f -name "pre-sign-${VARIANT}-*.json" | sort
    )
    ((${#child_manifests[@]} == 1)) || die "Expected exactly one internal pre-sign manifest"
    child_manifest="${child_manifests[0]}"
    test_retry_occurred="$(json_value "$child_manifest" qualification.test_retry_occurred)"
  fi
  node -e '
    const fs=require("fs");
    const [out,type,channel,label,upstreamSha,localRef,localSha,featureContract,submodulesJson,nativePayloadJson,variant,qualified,signed,testRetry,apk,sha,metadata]=process.argv.slice(1);
    const [applicationId,versionCode,versionName,certificateSha256]=metadata.split("\t");
    const nativePayload=JSON.parse(nativePayloadJson);
    fs.writeFileSync(out,JSON.stringify({schema_version:4,type,
      created_at:new Date().toISOString(),channel,upstream_label:label,upstream_sha:upstreamSha,
      local_ref:localRef,local_sha:localSha,feature_contract_sha256:featureContract,
      native_payload_contract_version:nativePayload.contract_version,
      native_payload_contract_sha256:nativePayload.contract_sha256,
      native_toolchain:nativePayload.toolchain,submodules:JSON.parse(submodulesJson),variant,
      upstream_repository:"https://github.com/danielealbano/android-remote-control-mcp",
      source_repository:"https://github.com/mwoDevelop/android-remote-control-mcp",
      qualified:qualified==="true",mandatory_gates_skipped:qualified!=="true",
      qualification:{profile:"arcp_fork_static",ngrok_live_integration:"pending_protected_job",
        test_retry_occurred:testRetry==="true"},
      signed:signed==="true",apk_asset:apk,raw_unsigned_sha256:signed==="true"?null:sha,
      sha256:sha,application_id:applicationId,version_code:Number(versionCode),version_name:versionName,
      certificate_sha256:certificateSha256||null},null,2)+"\n");
  ' "$output_manifest" "$manifest_type" "$channel" "$label" "$source_sha" "$local_ref" "$local_sha" \
    "$feature_contract_sha" "$submodules_json" "$native_payload_json" "$VARIANT" "$qualified" "$signed" "$test_retry_occurred" \
    "$(basename "$output_apk")" "$sha" "$metadata"
  printf 'Latest %s ARCP build complete: upstream=%s/%s local=%s/%s\nAPK: %s\nManifest: %s\n' \
    "$channel" "$label" "$source_sha" "$local_ref" "$local_sha" "$output_apk" "$output_manifest"
)

prepare_host_cloudflared() {
  local host_tools_dir host_cloudflared
  require_command go
  host_tools_dir="$REPO_ROOT/build/host-tools"
  host_cloudflared="$host_tools_dir/cloudflared"
  mkdir -p "$host_tools_dir"
  (
    cd "$REPO_ROOT/vendor/cloudflared"
    go build -o "$host_cloudflared" ./cmd/cloudflared
  )
  [[ -x "$host_cloudflared" ]] || die "Host cloudflared build did not create an executable"
  PATH="$host_tools_dir:$PATH"
  export PATH
}

prepare_go_toolchain() {
  local host_tools_dir go_root temporary_dir container_id=""
  if command -v go >/dev/null 2>&1 && [[ "$(go version)" == "go version go$BOOTSTRAP_GO_VERSION "* ]]; then
    return
  fi

  require_command docker
  host_tools_dir="$REPO_ROOT/build/host-tools"
  go_root="$host_tools_dir/go-$BOOTSTRAP_GO_VERSION"
  mkdir -p "$host_tools_dir"
  if [[ ! -x "$go_root/bin/go" ]]; then
    temporary_dir="$(mktemp -d "$host_tools_dir/.go-toolchain.XXXXXX")"
    container_id="$(docker create "$BOOTSTRAP_GO_IMAGE")"
    if ! docker cp "$container_id:/usr/local/go" "$temporary_dir/go"; then
      docker rm -f "$container_id" >/dev/null 2>&1 || true
      rm -rf -- "$temporary_dir"
      die "Cannot extract the pinned Go toolchain from $BOOTSTRAP_GO_IMAGE"
    fi
    docker rm "$container_id" >/dev/null
    mv "$temporary_dir/go" "$go_root"
    rmdir "$temporary_dir"
  fi
  PATH="$go_root/bin:$PATH"
  export PATH
  [[ "$(go version)" == "go version go$BOOTSTRAP_GO_VERSION "* ]] ||
    die "Pinned Go bootstrap has an unexpected version"
}

prepare_maven_toolchain() {
  local host_tools_dir maven_root temporary_dir container_id=""
  if command -v mvn >/dev/null 2>&1; then return; fi

  require_command docker
  host_tools_dir="$REPO_ROOT/build/host-tools"
  maven_root="$host_tools_dir/maven-$BOOTSTRAP_MAVEN_VERSION"
  mkdir -p "$host_tools_dir"
  if [[ ! -x "$maven_root/bin/mvn" ]]; then
    temporary_dir="$(mktemp -d "$host_tools_dir/.maven-toolchain.XXXXXX")"
    container_id="$(docker create "$BOOTSTRAP_MAVEN_IMAGE")"
    if ! docker cp "$container_id:/usr/share/maven" "$temporary_dir/maven"; then
      docker rm -f "$container_id" >/dev/null 2>&1 || true
      rm -rf -- "$temporary_dir"
      die "Cannot extract the pinned Maven toolchain from $BOOTSTRAP_MAVEN_IMAGE"
    fi
    docker rm "$container_id" >/dev/null
    mv "$temporary_dir/maven" "$maven_root"
    rmdir "$temporary_dir"
  fi
  PATH="$maven_root/bin:$PATH"
  export PATH
  [[ "$(mvn --version | head -1)" == "Apache Maven $BOOTSTRAP_MAVEN_VERSION "* ]] ||
    die "Pinned Maven bootstrap has an unexpected version"
}

prepare_native_tunnel_payload() {
  require_command make
  make -C "$REPO_ROOT" compile-cloudflared compile-ngrok-native
}

validate_tunnel_payload() {
  # shellcheck source=lib/native-tunnel-payloads.sh
  source "$SCRIPT_DIR/lib/native-tunnel-payloads.sh"
  validate_native_tunnel_payload "$1"
}

validate_admin_ui_manifest() {
  local apk="$1" analyzer
  analyzer="$(resolve_android_tool apkanalyzer)"
  node "$REPO_ROOT/scripts/verify-admin-ui-manifest.mjs" "$analyzer" "$apk"
}

certificate_digest() {
  local signer="$1" apk="$2" output digest
  output="$("$signer" verify --print-certs "$apk")" || return 1
  digest="$({
    sed -n -E \
      's/^(Signer #[0-9]+|V[0-9]+ Signer:)[[:space:]]*certificate SHA-256 digest: //p' \
      <<<"$output"
  } | head -1)"
  [[ -n "$digest" ]] || return 1
  printf '%s' "$digest"
}

apk_package_metadata() {
  local apk="$1" analyzer app_id version_code version_name
  analyzer="$(resolve_android_tool apkanalyzer)"
  app_id="$($analyzer manifest application-id "$apk")"
  version_code="$($analyzer manifest version-code "$apk")"
  version_name="$($analyzer manifest version-name "$apk")"
  if [[ -z "$app_id" || ! "$version_code" =~ ^[0-9]+$ || -z "$version_name" ]]; then
    printf 'ERROR: APK package or version metadata cannot be read\n' >&2
    return 1
  fi
  printf '%s\t%s\t%s\n' "$app_id" "$version_code" "$version_name"
}

apk_metadata() {
  local apk="$1" signer metadata digest
  signer="$(resolve_android_tool apksigner)"
  metadata="$(apk_package_metadata "$apk")" || return 1
  if ! digest="$(certificate_digest "$signer" "$apk")"; then
    printf 'ERROR: APK is unsigned or its signing digest cannot be read\n' >&2
    return 1
  fi
  printf '%s\t%s\t%s\t%s\n' "$metadata" "$digest"
}

write_build_manifest() {
  local apk="$1" qualified="$2" sha metadata manifest_dir manifest
  sha="$(sha256sum "$apk" | awk '{print $1}')"
  metadata="$(apk_metadata "$apk")" || return 1
  manifest_dir="$REPO_ROOT/build/deployments"
  mkdir -p "$manifest_dir"
  manifest="$manifest_dir/build-${VARIANT}-${sha}.json"
  node -e '
    const fs=require("fs"); const [out,apk,sha,variant,qualified,gitSha,meta]=process.argv.slice(1);
    const [applicationId,versionCode,versionName,certificateSha256]=meta.split("\t");
    fs.writeFileSync(out,JSON.stringify({schema_version:1,type:"qualified_build",created_at:new Date().toISOString(),
      git_sha:gitSha,variant,qualified:qualified==="true",apk,sha256:sha,application_id:applicationId,
      version_code:Number(versionCode),version_name:versionName,certificate_sha256:certificateSha256,
      mandatory_gates_skipped:qualified!=="true"},null,2)+"\n");
  ' "$manifest" "$(realpath "$apk")" "$sha" "$VARIANT" "$qualified" "$(git -C "$REPO_ROOT" rev-parse HEAD)" "$metadata"
  printf '%s' "$manifest"
}

write_unsigned_build_manifest() {
  local apk="$1" qualified="$2" sha metadata manifest_dir manifest profile type ngrok_status
  sha="$(sha256sum "$apk" | awk '{print $1}')"
  metadata="$(apk_package_metadata "$apk")" || return 1
  manifest_dir="$REPO_ROOT/build/deployments"
  mkdir -p "$manifest_dir"
  manifest="$manifest_dir/pre-sign-${VARIANT}-${sha}.json"
  profile="owner_full"
  type="qualified_unsigned_build"
  ngrok_status="passed_in_process"
  if [[ "${ARCP_FORK_CHANNEL_BUILD:-false}" == true ]]; then
    profile="arcp_fork_static"
    type="arcp_fork_unsigned_build"
    ngrok_status="pending_protected_job"
  fi
  node -e '
    const fs=require("fs"); const [out,apk,sha,variant,qualified,gitSha,testRetry,profile,type,ngrokStatus,meta]=process.argv.slice(1);
    const [applicationId,versionCode,versionName]=meta.split("\t");
    fs.writeFileSync(out,JSON.stringify({schema_version:3,type,
      created_at:new Date().toISOString(),git_sha:gitSha,variant,qualified:qualified==="true",
      apk_asset:require("path").basename(apk),raw_unsigned_sha256:sha,application_id:applicationId,
      version_code:Number(versionCode),version_name:versionName,certificate_sha256:null,
      qualification:{profile,ngrok_live_integration:ngrokStatus,
        test_retry_occurred:testRetry==="true"},
      mandatory_gates_skipped:qualified!=="true"},null,2)+"\n");
  ' "$manifest" "$apk" "$sha" "$VARIANT" "$qualified" "$(git -C "$REPO_ROOT" rev-parse HEAD)" \
    "$TEST_RETRY_OCCURRED" "$profile" "$type" "$ngrok_status" "$metadata"
  printf '%s' "$manifest"
}

assert_channel_build_secretless() {
  local variable
  for variable in NGROK_AUTHTOKEN RELEASE_KEYSTORE_BASE64 RELEASE_KEYSTORE_PASSWORD RELEASE_KEY_ALIAS \
    RELEASE_KEY_PASSWORD GH_TOKEN GITHUB_TOKEN; do
    [[ -z "${!variable:-}" ]] || die "Secret-bearing variable is forbidden in an ARCP static channel build: $variable"
  done
}

run_secretless_channel_tests() {
  local init_script="$1"
  if ./gradlew --init-script "$init_script" :app:test :privacy:test :privacy-benchmark:test; then
    return
  fi
  TEST_RETRY_OCCURRED=true
  printf 'WARNING: channel test task failed once; retrying the same secretless task exactly once.\n' >&2
  ./gradlew --init-script "$init_script" :app:test :privacy:test :privacy-benchmark:test
}

build_variant() {
  local ngrok_test_token manifest
  local -a gradle_init_args=() gradle_version_args=()
  require_command node
  variant_parts
  cd "$REPO_ROOT"
  prepare_go_toolchain
  prepare_maven_toolchain
  prepare_host_cloudflared
  prepare_native_tunnel_payload
  ./gradlew ktlintCheck detekt
  if [[ "${ARCP_FORK_CHANNEL_BUILD:-false}" == true ]]; then
    assert_channel_build_secretless
    gradle_init_args=(--init-script "$SCRIPT_DIR/gradle/arcp-fork-static.init.gradle")
    run_secretless_channel_tests "${gradle_init_args[1]}"
  else
    ngrok_test_token="$(resolve_ngrok_test_token)"
    NGROK_AUTHTOKEN="$ngrok_test_token" ./gradlew :app:test :privacy:test :privacy-benchmark:test
  fi
  if [[ "$SKIP_E2E" == false ]]; then ./gradlew :e2e-tests:compileTestKotlin; fi
  [[ -z "$VERSION_CODE_OVERRIDE" ]] || gradle_version_args+=("-PVERSION_CODE=$VERSION_CODE_OVERRIDE")
  [[ -z "$VERSION_NAME_OVERRIDE" ]] || gradle_version_args+=("-PVERSION_NAME=$VERSION_NAME_OVERRIDE")
  ./gradlew "${gradle_version_args[@]}" "assemble${VARIANT^}"
  mapfile -t apks < <(find "app/build/outputs/apk/$FLAVOR/$BUILD_TYPE" -maxdepth 1 -type f -name '*.apk' | sort)
  ((${#apks[@]} == 1)) || die "Expected exactly one APK for $VARIANT, found ${#apks[@]}"
  validate_tunnel_payload "${apks[0]}"
  validate_admin_ui_manifest "${apks[0]}"
  if [[ "${ARCP_CHANNEL_UNSIGNED_RELEASE:-false}" == true ]]; then
    manifest="$(write_unsigned_build_manifest "${apks[0]}" "$([[ "$SKIP_E2E" == false ]] && printf true || printf false)")" ||
      die "Failed to create an unsigned pre-sign build manifest"
  else
    manifest="$(write_build_manifest "${apks[0]}" "$([[ "$SKIP_E2E" == false ]] && printf true || printf false)")" ||
      die "Failed to create a qualified build manifest"
  fi
  printf 'Build complete: %s\nManifest: %s\n' "${apks[0]}" "$manifest"
  [[ "$SKIP_E2E" == false ]] || printf 'UNQUALIFIED: mandatory E2E compile gate was skipped; deployment will refuse this artifact.\n' >&2
  BUILT_ARTIFACT="$(realpath "${apks[0]}")"
}

qualified_manifest_for() {
  local apk="$1" sha
  sha="$(sha256sum "$apk" | awk '{print $1}')"
  find "$REPO_ROOT/build/deployments" -maxdepth 1 -type f -name "build-*-$sha.json" -print 2>/dev/null | sort | head -1
}

validate_qualified_artifact() {
  local manifest expected_sha actual_sha qualified manifest_apk
  manifest="$(qualified_manifest_for "$ARTIFACT")"
  [[ -f "$manifest" ]] || die "No local qualified build manifest matches this APK"
  expected_sha="$(json_value "$manifest" sha256)"
  actual_sha="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
  qualified="$(json_value "$manifest" qualified)"
  manifest_apk="$(json_value "$manifest" apk)"
  [[ "$expected_sha" == "$actual_sha" && "$qualified" == "true" && "$manifest_apk" == "$(realpath "$ARTIFACT")" ]] ||
    die "Artifact manifest is unqualified or does not match the APK"
}

installed_certificate() {
  local package="$1" signer="$2" remote_path temp_dir local_apk digest
  remote_path="$(adb_target shell pm path "$package" | tr -d '\r' | sed -n 's/^package://p' | head -1)"
  [[ -n "$remote_path" ]] || return 3
  temp_dir="$(mktemp -d)"
  local_apk="$temp_dir/installed-base.apk"
  trap '[[ -n "${temp_dir:-}" && -d "$temp_dir" ]] && rm -rf -- "$temp_dir"' RETURN
  adb_target pull "$remote_path" "$local_apk" >/dev/null
  digest="$(certificate_digest "$signer" "$local_apk")" || return 1
  [[ -n "$digest" ]] || die "Cannot read installed APK signing certificate"
  printf '%s' "$digest"
}

preflight_artifact_and_device() {
  local metadata candidate_package candidate_code candidate_cert expected_package signer installed_cert installed_code
  [[ -f "$ARTIFACT" ]] || die "Artifact does not exist: $ARTIFACT"
  [[ "$ARTIFACT" == /* ]] || ARTIFACT="$(realpath "$ARTIFACT")"
  validate_qualified_artifact
  check_device
  metadata="$(apk_metadata "$ARTIFACT")" || die "Cannot read candidate APK metadata"
  IFS=$'\t' read -r candidate_package candidate_code _ candidate_cert <<<"$metadata"
  ensure_profile
  expected_package="$(arcp_profile_value application_id)"
  [[ "$candidate_package" == "$expected_package" ]] || die "APK application ID mismatch (debug POC uses a separate helper)"
  signer="$(resolve_android_tool apksigner)"
  if installed_cert="$(installed_certificate "$expected_package" "$signer")"; then
    [[ "$installed_cert" == "$candidate_cert" ]] || die "Signing certificate mismatch; automatic uninstall is prohibited"
    installed_code="$(adb_target shell dumpsys package "$expected_package" | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -1)"
    if [[ "$COMMAND" != "rollback" && -n "$installed_code" ]]; then
      ((candidate_code >= installed_code)) || die "Version downgrade is allowed only through rollback"
    fi
  elif [[ "$COMMAND" == "rollback" ]]; then
    die "Rollback requires the package to be installed"
  fi
}

verify_loopback_binding() {
  local forward_port loopback_status wifi_ip
  require_command curl
  forward_port="$(adb_target forward tcp:0 tcp:8080 | tr -d '\r')"
  [[ "$forward_port" =~ ^[0-9]+$ ]] || die "ADB did not allocate a host port for the MCP loopback check"
  loopback_status="$(
    curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
      --max-time 8 "http://127.0.0.1:${forward_port}/mcp" || true
  )"
  adb_target forward --remove "tcp:${forward_port}" >/dev/null
  case "$loopback_status" in
    200|400|401|403|405) ;;
    *) die "MCP server is not reachable over the device loopback port 8080" ;;
  esac

  wifi_ip="$(adb_target shell ip -o -4 addr show dev wlan0 scope global 2>/dev/null | tr -d '\r' | awk '{print $4}' | cut -d/ -f1 | head -1)"
  [[ -n "$wifi_ip" ]] || die "Cannot verify Wi-Fi non-exposure because wlan0 has no IPv4 address"
  if timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/8080"' _ "$wifi_ip" 2>/dev/null; then
    die "MCP port 8080 accepts TCP connections through the device Wi-Fi address"
  fi
  printf 'OK: MCP responds through ADB loopback forwarding and Wi-Fi TCP port 8080 is closed.\n'
}

write_deployment_manifest() {
  local state="$1" sha out
  sha="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
  out="$REPO_ROOT/build/deployments/$(date -u +%Y%m%dT%H%M%SZ)-$DEVICE.json"
  node -e '
    const fs=require("fs"); const [out,state,device,sha,gitSha]=process.argv.slice(1);
    fs.writeFileSync(out,JSON.stringify({schema_version:1,type:"device_deployment",checked_at:new Date().toISOString(),
      state,profile:device,apk_sha256:sha,git_sha:gitSha,manual_gates:["restricted_settings","privileged_service_after_reboot","oem_battery_policy","parental_control_policy"]},null,2)+"\n");
  ' "$out" "$state" "$DEVICE" "$sha" "$(git -C "$REPO_ROOT" rev-parse HEAD)"
  printf '%s' "$out"
}

deploy_artifact() {
  ensure_profile
  if [[ "$APPLY" == false ]]; then
    printf 'PREVIEW: validate qualified artifact, explicit %s identity, installed/candidate signatures, install -r, restore config, and run live checks.\n' "$DEVICE"
    return
  fi
  require_command adb
  require_command node
  require_command timeout
  preflight_artifact_and_device
  local expected_package apply_script verify_script manifest
  ensure_profile
  expected_package="$(arcp_profile_value application_id)"
  if [[ "$COMMAND" == "rollback" ]]; then
    adb_target install -r -d "$ARTIFACT"
  else
    adb_target install -r "$ARTIFACT"
  fi
  [[ "$(adb_target shell pm path "$expected_package" | tr -d '\r')" == package:* ]] || die "Package not installed after adb install -r"
  apply_script="$(arcp_profile_path apply)"
  verify_script="$(arcp_profile_path verify)"
  env -u ARCP_DEVICE_UNLOCK_PIN ADB_SERIAL="$SERIAL" "$apply_script" --restart
  verify_loopback_binding
  "$verify_script" --live
  manifest="$(write_deployment_manifest PENDING_MANUAL_GATES)"
  printf 'APK and configuration applied; basic endpoint and loopback checks passed.\n'
  printf 'PENDING_MANUAL_GATES: authenticated ordinary/admin calls, OAuth denial, screen-off, service restart, privileged-service recovery, Restricted Settings, OEM battery policy and parental-control policy remain acceptance checks.\n'
  printf 'Deployment manifest: %s\n' "$manifest"
}

rollback_artifact() {
  if [[ "$APPLY" == false ]]; then deploy_artifact; return; fi
  local sha previous
  sha="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
  previous="$(rg -l --fixed-strings "\"apk_sha256\": \"$sha\"" "$REPO_ROOT/build/deployments"/*-"$DEVICE".json 2>/dev/null | head -1 || true)"
  [[ -n "$previous" ]] || die "Rollback artifact is not present in a previous device deployment manifest"
  deploy_artifact
}

parse_args "$@"
validate_contract

case "$COMMAND" in
  check) check_device ;;
  sync) sync_upstream ;;
  build)
    if [[ "$LATEST_STABLE" == true ]]; then
      build_upstream_channel stable
    elif [[ "$LATEST_EDGE" == true ]]; then
      build_upstream_channel edge
    else
      build_variant
    fi
    ;;
  channel-info) channel_info ;;
  deploy) deploy_artifact ;;
  all)
    ensure_profile
    if [[ "$APPLY" == false ]]; then
      printf 'PREVIEW: validate and build the current reviewed commit, then deploy to %s; no fetch or merge.\n' "$DEVICE"
    else
      require_clean_worktree
      build_variant
      ARTIFACT="$BUILT_ARTIFACT"
      deploy_artifact
    fi
    ;;
  rollback) rollback_artifact ;;
esac
