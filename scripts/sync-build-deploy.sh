#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PACKAGE_ID="com.danielealbano.androidremotecontrolmcp"
OFFICIAL_UPSTREAM="https://github.com/danielealbano/android-remote-control-mcp.git"
DEFAULT_VARIANT="gmsRelease"
APPLY=false
DEVICE=""
SERIAL=""
VARIANT="$DEFAULT_VARIANT"
ARTIFACT=""
UPSTREAM_REF="upstream/main"
SKIP_E2E=false
COMMAND="${1:-}"
shift || true

usage() {
  cat <<'EOF'
Usage:
  scripts/sync-build-deploy.sh check  --device <[REDACTED_DEVICE_ALIAS]|[REDACTED_DEVICE_ALIAS]> [--serial <adb-serial>]
  scripts/sync-build-deploy.sh sync   [--upstream-ref upstream/main] --apply
  scripts/sync-build-deploy.sh build  [--variant gmsDebug|fossDebug|gmsRelease|fossRelease] [--skip-e2e-compile]
  scripts/sync-build-deploy.sh deploy --device <[REDACTED_DEVICE_ALIAS]|[REDACTED_DEVICE_ALIAS]> --artifact <apk> [--serial <adb-serial>] --apply
  scripts/sync-build-deploy.sh all    --device <[REDACTED_DEVICE_ALIAS]|[REDACTED_DEVICE_ALIAS]> [--variant ...] [--serial <adb-serial>] --apply
  scripts/sync-build-deploy.sh rollback --device <[REDACTED_DEVICE_ALIAS]|[REDACTED_DEVICE_ALIAS]> --artifact <known-good-apk> [--serial <adb-serial>] --apply

Safety contract:
  check is read-only. sync only creates a review branch and merges there; it never deploys.
  all validates, builds and deploys the already checked-out commit; it never fetches or merges.
  sync/deploy/all/rollback print a preview and make no changes without literal --apply.
  Deployment never uninstalls an app, bypasses signature checks, grants Restricted Settings,
  automates Shizuku, or changes Qustodio. Debug canaries use scripts/deploy-[REDACTED_DEVICE_ALIAS]-debug-poc.sh.

Examples:
  scripts/sync-build-deploy.sh check --device [REDACTED_DEVICE_ALIAS] --serial SERIAL
  scripts/sync-build-deploy.sh sync --upstream-ref upstream/main --apply
  scripts/sync-build-deploy.sh build --variant gmsDebug
  scripts/sync-build-deploy.sh all --device [REDACTED_DEVICE_ALIAS] --variant gmsRelease --serial SERIAL --apply
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
      --device) (($# >= 2)) || die "--device requires a value"; DEVICE="$2"; shift 2 ;;
      --serial) (($# >= 2)) || die "--serial requires a value"; SERIAL="$2"; shift 2 ;;
      --variant) (($# >= 2)) || die "--variant requires a value"; VARIANT="$2"; shift 2 ;;
      --artifact) (($# >= 2)) || die "--artifact requires a value"; ARTIFACT="$2"; shift 2 ;;
      --upstream-ref) (($# >= 2)) || die "--upstream-ref requires a value"; UPSTREAM_REF="$2"; shift 2 ;;
      --skip-e2e-compile) SKIP_E2E=true; shift ;;
      --apply) APPLY=true; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

validate_contract() {
  case "$COMMAND" in
    check)
      [[ -n "$DEVICE" ]] || die "check requires --device"
      [[ "$APPLY" == false ]] || die "check does not accept --apply"
      [[ "$VARIANT" == "$DEFAULT_VARIANT" && -z "$ARTIFACT" && "$UPSTREAM_REF" == "upstream/main" && "$SKIP_E2E" == false ]] ||
        die "check received an option that belongs to another command"
      ;;
    sync)
      [[ -z "$DEVICE" && -z "$SERIAL" && -z "$ARTIFACT" && "$VARIANT" == "$DEFAULT_VARIANT" && "$SKIP_E2E" == false ]] ||
        die "sync accepts only --upstream-ref and --apply"
      [[ "$UPSTREAM_REF" =~ ^upstream/[A-Za-z0-9._/-]+$ ]] || die "--upstream-ref must name a ref below upstream/"
      ;;
    build)
      [[ -z "$DEVICE" && -z "$SERIAL" && -z "$ARTIFACT" && "$UPSTREAM_REF" == "upstream/main" && "$APPLY" == false ]] ||
        die "build accepts only --variant and --skip-e2e-compile"
      ;;
    deploy|rollback)
      [[ -n "$DEVICE" && -n "$ARTIFACT" ]] || die "$COMMAND requires --device and --artifact"
      [[ "$VARIANT" == "$DEFAULT_VARIANT" && "$UPSTREAM_REF" == "upstream/main" && "$SKIP_E2E" == false ]] ||
        die "$COMMAND received an option that belongs to another command"
      ;;
    all)
      [[ -n "$DEVICE" ]] || die "all requires --device"
      [[ -z "$ARTIFACT" && "$UPSTREAM_REF" == "upstream/main" && "$SKIP_E2E" == false ]] ||
        die "all does not accept --artifact, --upstream-ref or --skip-e2e-compile"
      ;;
    help|--help|-h|"") usage; exit 0 ;;
    *) die "Unknown command: $COMMAND" ;;
  esac

  case "$DEVICE" in ""|[REDACTED_DEVICE_ALIAS]|[REDACTED_DEVICE_ALIAS]) ;; *) die "Unknown device: $DEVICE" ;; esac
  case "$VARIANT" in gmsDebug|fossDebug|gmsRelease|fossRelease) ;; *) die "Unknown variant: $VARIANT" ;; esac
}

device_config() {
  printf '%s/myconf/%s/android/config.json' "$REPO_ROOT" "$DEVICE"
}

device_secret_file() {
  printf '%s/myconf/%s/.env.secrets' "$REPO_ROOT" "$DEVICE"
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
  local file="$1" variable="$2"
  bash -c 'set -a; source "$1"; value="${!2:-}"; printf "%s" "$value"' _ "$file" "$variable"
}

validate_secret_file() {
  local file
  file="$(device_secret_file)"
  [[ -f "$file" ]] || die "Missing device secrets file: myconf/$DEVICE/.env.secrets"
  [[ "$(stat -c '%a' "$file")" == "600" ]] || die "Device secrets file must have mode 0600"
  git -C "$REPO_ROOT" check-ignore -q "myconf/$DEVICE/.env.secrets" || die "Device secrets file is not ignored by Git"
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
  expected_manufacturer="$(json_value "$config" device.deployment_identity.manufacturer)"
  expected_model="$(json_value "$config" device.deployment_identity.model)"
  expected_device="$(json_value "$config" device.deployment_identity.device)"
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

sync_upstream() {
  verify_upstream_remote
  if [[ "$APPLY" == false ]]; then
    printf 'PREVIEW: require clean main, fetch upstream --prune, create sync/upstream-TIMESTAMP, merge --no-ff %s.\n' "$UPSTREAM_REF"
    return
  fi
  require_clean_worktree
  [[ "$(git -C "$REPO_ROOT" branch --show-current)" == "main" ]] || die "sync must start from local main"
  git -C "$REPO_ROOT" fetch upstream --prune
  local remote_ref="refs/remotes/$UPSTREAM_REF" upstream_sha base_sha branch
  upstream_sha="$(git -C "$REPO_ROOT" rev-parse --verify "$remote_ref^{commit}")" || die "Cannot resolve $UPSTREAM_REF"
  base_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  branch="sync/upstream-$(date +%Y%m%d-%H%M%S)"
  git -C "$REPO_ROOT" switch -c "$branch"
  if ! git -C "$REPO_ROOT" merge --no-ff "$upstream_sha"; then
    printf 'Merge conflict preserved on %s. Resolve manually, commit, test, then open a PR. No abort/reset was run.\n' "$branch" >&2
    exit 1
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

apk_metadata() {
  local apk="$1" analyzer signer app_id version_code version_name digest
  analyzer="$(resolve_android_tool apkanalyzer)"
  signer="$(resolve_android_tool apksigner)"
  app_id="$($analyzer manifest application-id "$apk")"
  version_code="$($analyzer manifest version-code "$apk")"
  version_name="$($analyzer manifest version-name "$apk")"
  digest="$($signer verify --print-certs "$apk" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -1)"
  [[ -n "$digest" ]] || die "APK is unsigned or its signing digest cannot be read"
  printf '%s\t%s\t%s\t%s\n' "$app_id" "$version_code" "$version_name" "$digest"
}

write_build_manifest() {
  local apk="$1" qualified="$2" sha metadata manifest_dir manifest
  sha="$(sha256sum "$apk" | awk '{print $1}')"
  metadata="$(apk_metadata "$apk")"
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

build_variant() {
  require_command node
  variant_parts
  cd "$REPO_ROOT"
  scripts/verify-device-configs.sh
  ./gradlew ktlintCheck detekt
  ./gradlew :app:test :privacy:test :privacy-benchmark:test
  if [[ "$SKIP_E2E" == false ]]; then ./gradlew :e2e-tests:compileTestKotlin; fi
  ./gradlew "assemble${VARIANT^}"
  mapfile -t apks < <(find "app/build/outputs/apk/$FLAVOR/$BUILD_TYPE" -maxdepth 1 -type f -name '*.apk' | sort)
  ((${#apks[@]} == 1)) || die "Expected exactly one APK for $VARIANT, found ${#apks[@]}"
  local manifest
  manifest="$(write_build_manifest "${apks[0]}" "$([[ "$SKIP_E2E" == false ]] && printf true || printf false)")"
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
  digest="$($signer verify --print-certs "$local_apk" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -1)"
  [[ -n "$digest" ]] || die "Cannot read installed APK signing certificate"
  printf '%s' "$digest"
}

preflight_artifact_and_device() {
  local metadata candidate_package candidate_code candidate_cert expected_package signer installed_cert installed_code
  [[ -f "$ARTIFACT" ]] || die "Artifact does not exist: $ARTIFACT"
  [[ "$ARTIFACT" == /* ]] || ARTIFACT="$(realpath "$ARTIFACT")"
  validate_qualified_artifact
  check_device
  metadata="$(apk_metadata "$ARTIFACT")"
  IFS=$'\t' read -r candidate_package candidate_code _ candidate_cert <<<"$metadata"
  expected_package="$(json_value "$(device_config)" application.package_id)"
  [[ "$candidate_package" == "$expected_package" ]] || die "APK application ID mismatch (debug POC uses a separate helper)"
  signer="$(resolve_android_tool apksigner)"
  if installed_cert="$(installed_certificate "$expected_package" "$signer")"; then
    [[ "$installed_cert" == "$candidate_cert" ]] || die "Signing certificate mismatch; automatic uninstall is prohibited (see Plan 66 User Story 7)"
    installed_code="$(adb_target shell dumpsys package "$expected_package" | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -1)"
    if [[ "$COMMAND" != "rollback" && -n "$installed_code" ]]; then
      ((candidate_code >= installed_code)) || die "Version downgrade is allowed only through rollback"
    fi
  elif [[ "$COMMAND" == "rollback" ]]; then
    die "Rollback requires the package to be installed"
  fi
}

verify_loopback_binding() {
  local listeners
  listeners="$(adb_target shell ss -ltn 2>/dev/null | tr -d '\r' || true)"
  [[ "$listeners" != *"0.0.0.0:8080"* && "$listeners" != *"[::]:8080"* ]] ||
    die "MCP port 8080 is exposed beyond loopback"
  [[ "$listeners" == *"127.0.0.1:8080"* ]] || die "MCP server is not listening on loopback port 8080"
}

write_deployment_manifest() {
  local state="$1" sha out
  sha="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
  out="$REPO_ROOT/build/deployments/$(date -u +%Y%m%dT%H%M%SZ)-$DEVICE.json"
  node -e '
    const fs=require("fs"); const [out,state,device,sha,gitSha]=process.argv.slice(1);
    fs.writeFileSync(out,JSON.stringify({schema_version:1,type:"device_deployment",checked_at:new Date().toISOString(),
      state,device,apk_sha256:sha,git_sha:gitSha,manual_gates:["restricted_settings","shizuku_after_reboot","oem_battery_policy","qustodio_policy"]},null,2)+"\n");
  ' "$out" "$state" "$DEVICE" "$sha" "$(git -C "$REPO_ROOT" rev-parse HEAD)"
  printf '%s' "$out"
}

deploy_artifact() {
  if [[ "$APPLY" == false ]]; then
    printf 'PREVIEW: validate qualified artifact, explicit %s identity, installed/candidate signatures, install -r, restore config, and run live checks.\n' "$DEVICE"
    return
  fi
  require_command adb
  require_command node
  preflight_artifact_and_device
  local expected_package apply_script verify_script manifest
  expected_package="$(json_value "$(device_config)" application.package_id)"
  if [[ "$COMMAND" == "rollback" ]]; then
    adb_target install -r -d "$ARTIFACT"
  else
    adb_target install -r "$ARTIFACT"
  fi
  [[ "$(adb_target shell pm path "$expected_package" | tr -d '\r')" == package:* ]] || die "Package not installed after adb install -r"
  apply_script="$REPO_ROOT/myconf/$DEVICE/android/apply-config.sh"
  verify_script="$REPO_ROOT/myconf/$DEVICE/scripts/verify.sh"
  ADB_SERIAL="$SERIAL" "$apply_script" --restart
  verify_loopback_binding
  "$verify_script" --live
  manifest="$(write_deployment_manifest PENDING_MANUAL_GATES)"
  printf 'APK and configuration applied; live ordinary gates passed.\n'
  printf 'PENDING_MANUAL_GATES: Restricted Settings, Shizuku grant/restart, OEM battery policy and Qustodio remain administrator checks.\n'
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
  build) build_variant ;;
  deploy) deploy_artifact ;;
  all)
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
