#!/usr/bin/env bash
set -euo pipefail

umask 077
unset [REDACTED_DEVICE_ALIAS]_PIN [REDACTED_DEVICE_ALIAS]_PIN NGROK_AUTHTOKEN ANDROID_MCP_BEARER_TOKEN CLOUDFLARE_TUNNEL_TOKEN \
  RELEASE_KEYSTORE_BASE64 RELEASE_KEYSTORE_PASSWORD RELEASE_KEY_ALIAS RELEASE_KEY_PASSWORD

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ID="com.danielealbano.androidremotecontrolmcp"
RELEASE_DIR=""
REPOSITORY="${GITHUB_REPOSITORY:-mwoDevelop/android-remote-control-mcp}"
APPLY=false
TEMP_DIR=""

usage() {
  cat <<'EOF'
Usage:
  scripts/publish-arcp-channel-release.sh --release-dir <dir> [--repo <owner/repo>] [--apply]

Without --apply the command performs a non-mutating publication dry run. With --apply it verifies
official and owner channel freshness immediately before creating one immutable ARCP release. Existing
tags/assets are never overwritten; a complete matching release is an idempotent no-op.
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

verified_single_signer_digest() {
  local apk="$1" output digest
  local -a digests
  output="$($APKSIGNER verify --verbose --print-certs "$apk")" || return 1
  grep -Eq '^Verified using v(2|3|3\.1) scheme .*: true$' <<<"$output" || return 1
  mapfile -t digests < <(
    sed -n -E 's/^.*certificate SHA-256 digest:[[:space:]]*//p' <<<"$output" |
      tr '[:upper:]' '[:lower:]' | tr -d ':' | sort -u
  )
  ((${#digests[@]} == 1)) || return 1
  digest="$(tr -d '[:space:]' <<<"${digests[0]}")"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$digest"
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

cleanup() {
  [[ -z "$TEMP_DIR" || ! -d "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT INT TERM

validate_release_assets() {
  local directory="$1" expect_notes="$2" manifest
  local variant asset expected_sha actual_sha certificate asset_certificate verified_certificate
  local app_id version_code version_name expected_version_code expected_version_name
  local -a allowed actual
  manifest="$directory/release-manifest.json"
  [[ -f "$manifest" ]] || return 10
  node -e '
    const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    if (m.schema_version!==3 || m.type!=="arcp_channel_release" || m.immutable!==true ||
        !["stable","edge"].includes(m.channel) || m.prerelease!==(m.channel==="edge") ||
        !/^[0-9a-f]{40}$/.test(m.upstream_sha) || !/^[0-9a-f]{40}$/.test(m.local_sha) ||
        m.local_ref!==`release/${m.channel}` || !/^[0-9a-f]{64}$/.test(m.feature_contract_sha256) ||
        !m.submodules || !["vendor/cloudflared","vendor/ngrok-java"].every(k=>/^[0-9a-f]{40}$/.test(m.submodules[k]||"")) ||
        !/^[0-9a-f]{40}$/.test(m.workflow_source_sha) || !/^[0-9a-f]{64}$/.test(m.certificate_sha256) ||
        m.qualification?.profile!=="arcp_fork_release" ||
        m.qualification?.ngrok_live_integration!=="passed_protected_job" ||
        m.qualification?.mandatory_gates_skipped!==false || !Array.isArray(m.assets) || m.assets.length!==2 ||
        new Set(m.assets.map(a=>a.variant)).size!==2 ||
        !m.assets.every(a=>["gmsRelease","fossRelease"].includes(a.variant) &&
          a.application_id==="com.danielealbano.androidremotecontrolmcp" &&
          /^[0-9a-f]{64}$/.test(a.signed_sha256) && a.certificate_sha256===m.certificate_sha256 &&
          a.signed_asset===require("path").basename(a.signed_asset))) process.exit(2);
  ' "$manifest" || return 11

  allowed=(release-manifest.json)
  [[ "$expect_notes" == true ]] && allowed+=(release-notes.md)
  certificate="$(json_value "$manifest" certificate_sha256)"
  for variant in gmsRelease fossRelease; do
    asset="$(node -e '
      const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      const a=m.assets.find(v=>v.variant===process.argv[2]); if(!a) process.exit(2); process.stdout.write(a.signed_asset);
    ' "$manifest" "$variant")" || return 12
    allowed+=("$asset")
    [[ -f "$directory/$asset" ]] || return 13
    expected_sha="$(node -e '
      const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      process.stdout.write(m.assets.find(v=>v.variant===process.argv[2]).signed_sha256);
    ' "$manifest" "$variant")"
    actual_sha="$(sha256sum "$directory/$asset" | awk '{print $1}')"
    [[ "$actual_sha" == "$expected_sha" ]] || return 14
    asset_certificate="$(node -e '
      const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      process.stdout.write(m.assets.find(v=>v.variant===process.argv[2]).certificate_sha256);
    ' "$manifest" "$variant")"
    [[ "$asset_certificate" == "$certificate" ]] || return 15
    verified_certificate="$(verified_single_signer_digest "$directory/$asset")" || return 17
    [[ "$verified_certificate" == "$certificate" ]] || return 18
    app_id="$($APKANALYZER manifest application-id "$directory/$asset")"
    version_code="$($APKANALYZER manifest version-code "$directory/$asset")"
    version_name="$($APKANALYZER manifest version-name "$directory/$asset")"
    expected_version_code="$(node -e '
      const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      process.stdout.write(String(m.assets.find(v=>v.variant===process.argv[2]).version_code));
    ' "$manifest" "$variant")"
    expected_version_name="$(node -e '
      const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      process.stdout.write(m.assets.find(v=>v.variant===process.argv[2]).version_name);
    ' "$manifest" "$variant")"
    [[ "$app_id" == "$PACKAGE_ID" && "$version_code" == "$expected_version_code" &&
       "$version_name" == "$expected_version_name" ]] || return 19
  done
  mapfile -t allowed < <(printf '%s\n' "${allowed[@]}" | sort)
  mapfile -t actual < <(find "$directory" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
  [[ "${actual[*]}" == "${allowed[*]}" ]] || return 16
}

while (($#)); do
  case "$1" in
    --release-dir) (($# >= 2)) || die "$1 requires a value"; RELEASE_DIR="$2"; shift 2 ;;
    --repo) (($# >= 2)) || die "$1 requires a value"; REPOSITORY="$2"; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_command node
require_command sha256sum
APKSIGNER="$(resolve_android_tool apksigner)"
APKANALYZER="$(resolve_android_tool apkanalyzer)"
[[ -d "$RELEASE_DIR" ]] || die "--release-dir must be an existing directory"
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "Invalid --repo value"
validation_status=0
validate_release_assets "$RELEASE_DIR" true || validation_status=$?
[[ $validation_status -eq 0 ]] ||
  die "Release directory is incomplete, damaged or contains extra files (validation code $validation_status)"

MANIFEST="$RELEASE_DIR/release-manifest.json"
CHANNEL="$(json_value "$MANIFEST" channel)"
UPSTREAM_LABEL="$(json_value "$MANIFEST" upstream_label)"
UPSTREAM_SHA="$(json_value "$MANIFEST" upstream_sha)"
LOCAL_REF="$(json_value "$MANIFEST" local_ref)"
LOCAL_SHA="$(json_value "$MANIFEST" local_sha)"
RELEASE_TAG="$(json_value "$MANIFEST" release_tag)"
WORKFLOW_SOURCE_SHA="$(json_value "$MANIFEST" workflow_source_sha)"
[[ "$RELEASE_TAG" =~ ^arcp-(stable|edge)-[A-Za-z0-9._-]+-vc[0-9]+$ ]] ||
  die "Immutable ARCP release tag contract is invalid"
[[ "$LOCAL_REF" == "release/$CHANNEL" ]] || die "Local release ref mismatch"

mapfile -t SIGNED_ASSETS < <(node -e '
  const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  for (const a of m.assets) console.log(a.signed_asset);
' "$MANIFEST")
UPLOAD_ASSETS=("$RELEASE_DIR/${SIGNED_ASSETS[0]}" "$RELEASE_DIR/${SIGNED_ASSETS[1]}" "$MANIFEST")

if [[ "$APPLY" == false ]]; then
  printf 'DRY RUN: would publish immutable ARCP release %s to %s\n' "$RELEASE_TAG" "$REPOSITORY"
  printf 'channel=%s upstream=%s/%s local=%s/%s\n' \
    "$CHANNEL" "$UPSTREAM_LABEL" "$UPSTREAM_SHA" "$LOCAL_REF" "$LOCAL_SHA"
  for asset in "${UPLOAD_ASSETS[@]}"; do
    printf 'asset=%s sha256=%s\n' "$(basename "$asset")" "$(sha256sum "$asset" | awk '{print $1}')"
  done
  printf 'No GitHub release or tag was created or modified.\n'
  exit 0
fi

require_command gh
require_command git
channel_flag="--latest-$CHANNEL"
"$SCRIPT_DIR/sync-build-deploy.sh" channel-info "$channel_flag" \
  --expected-source-sha "$UPSTREAM_SHA" --expected-local-sha "$LOCAL_SHA" >/dev/null
TEMP_BASE="${RUNNER_TEMP:-/tmp}"
[[ -d "$TEMP_BASE" ]] || die "Temporary directory base does not exist: $TEMP_BASE"
TEMP_DIR="$(mktemp -d "$TEMP_BASE/arcp-channel-publish.XXXXXX")"

release_exists=false
if gh release view "$RELEASE_TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  release_exists=true
elif gh api "repos/$REPOSITORY/git/ref/tags/$RELEASE_TAG" >/dev/null 2>&1; then
  die "Tag $RELEASE_TAG exists without a release; refusing ambiguous publication"
fi

TITLE="ARCP $CHANNEL — $UPSTREAM_LABEL / ${LOCAL_SHA:0:12}"
if [[ "$release_exists" == true ]]; then
  expected_prerelease=false
  [[ "$CHANNEL" == edge ]] && expected_prerelease=true
  [[ "$(gh release view "$RELEASE_TAG" --repo "$REPOSITORY" --json isPrerelease --jq .isPrerelease)" == "$expected_prerelease" ]] ||
    die "Existing release pre-release state is invalid"
  BACKUP_DIR="$TEMP_DIR/previous"
  mkdir -p "$BACKUP_DIR"
  gh release download "$RELEASE_TAG" --repo "$REPOSITORY" --dir "$BACKUP_DIR"
  validation_status=0
  validate_release_assets "$BACKUP_DIR" false || validation_status=$?
  [[ $validation_status -eq 0 ]] ||
    die "Existing release assets are incomplete or damaged (validation code $validation_status)"
  PREVIOUS_MANIFEST="$BACKUP_DIR/release-manifest.json"
  [[ "$(json_value "$PREVIOUS_MANIFEST" release_tag)" == "$RELEASE_TAG" ]] ||
    die "Existing release manifest tag mismatch"
  cmp -s "$PREVIOUS_MANIFEST" "$MANIFEST" ||
    die "Immutable release identity already exists with different provenance or asset digests"
  printf 'NO-OP: immutable release %s already contains the complete verified bundle\n' "$RELEASE_TAG"
  exit 0
else
  create_args=(release create "$RELEASE_TAG" --repo "$REPOSITORY" --target "$LOCAL_SHA" \
    --title "$TITLE" --notes-file "$RELEASE_DIR/release-notes.md")
  [[ "$CHANNEL" != edge ]] || create_args+=(--prerelease)
  gh "${create_args[@]}" "${UPLOAD_ASSETS[@]}"
  printf 'Created immutable ARCP %s release %s for local %s\n' "$CHANNEL" "$RELEASE_TAG" "$LOCAL_SHA"
fi
