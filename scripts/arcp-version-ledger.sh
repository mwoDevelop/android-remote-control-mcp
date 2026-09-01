#!/usr/bin/env bash
set -euo pipefail

umask 077
unset [REDACTED_DEVICE_ALIAS]_PIN [REDACTED_DEVICE_ALIAS]_PIN ANDROID_MCP_BEARER_TOKEN CLOUDFLARE_TUNNEL_TOKEN \
  RELEASE_KEYSTORE_BASE64 RELEASE_KEYSTORE_PASSWORD RELEASE_KEY_ALIAS RELEASE_KEY_PASSWORD

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
REMOTE="origin"
LEDGER_BRANCH="release/version-ledger"
LEDGER_REF="refs/arcp-version-ledger/remote"
EXPECTED_ORIGIN_URL="${ARCP_EXPECTED_ORIGIN_URL:-https://github.com/mwoDevelop/android-remote-control-mcp.git}"
INITIAL_VERSION_CODE=21000000
ANDROID_MAX_VERSION_CODE=2100000000

COMMAND="${1:-}"
shift || true
CHANNEL=""
UPSTREAM_LABEL=""
UPSTREAM_SHA=""
LOCAL_SHA=""
REVISION=1
APPLY=false

usage() {
  cat <<'EOF'
Usage:
  scripts/arcp-version-ledger.sh lookup \
    --channel <stable|edge> --upstream-label <label> --upstream-sha <sha> --local-sha <sha> [--revision N]
  scripts/arcp-version-ledger.sh allocate \
    --channel <stable|edge> --upstream-label <label> --upstream-sha <sha> --local-sha <sha> [--revision N] [--apply]

Without --apply, allocate prints an unreserved preview. --apply appends the identity to the protected
release/version-ledger ref with a normal fast-forward push; a concurrent allocation fails instead of reusing a code.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --channel) (($# >= 2)) || die "$1 requires a value"; CHANNEL="$2"; shift 2 ;;
    --upstream-label) (($# >= 2)) || die "$1 requires a value"; UPSTREAM_LABEL="$2"; shift 2 ;;
    --upstream-sha) (($# >= 2)) || die "$1 requires a value"; UPSTREAM_SHA="${2,,}"; shift 2 ;;
    --local-sha) (($# >= 2)) || die "$1 requires a value"; LOCAL_SHA="${2,,}"; shift 2 ;;
    --revision) (($# >= 2)) || die "$1 requires a value"; REVISION="$2"; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "$COMMAND" == lookup || "$COMMAND" == allocate ]] || { usage; die "Expected lookup or allocate"; }
[[ "$CHANNEL" == stable || "$CHANNEL" == edge ]] || die "--channel must be stable or edge"
[[ "$UPSTREAM_LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid --upstream-label"
[[ "$UPSTREAM_SHA" =~ ^[0-9a-f]{40}$ ]] || die "--upstream-sha must be a full SHA"
[[ "$LOCAL_SHA" =~ ^[0-9a-f]{40}$ ]] || die "--local-sha must be a full SHA"
[[ "$REVISION" =~ ^[1-9][0-9]*$ ]] || die "--revision must be a positive integer"
[[ "$COMMAND" == allocate || "$APPLY" == false ]] || die "lookup does not accept --apply"

actual_origin="$(git -C "$REPO_ROOT" remote get-url "$REMOTE" 2>/dev/null)" || die "Missing origin remote"
[[ "$actual_origin" == "$EXPECTED_ORIGIN_URL" ]] || die "origin URL is not the expected owner repository"

git -C "$REPO_ROOT" update-ref -d "$LEDGER_REF" >/dev/null 2>&1 || true
ledger_exists=false
if git -C "$REPO_ROOT" fetch --no-tags "$REMOTE" "+refs/heads/$LEDGER_BRANCH:$LEDGER_REF" >/dev/null 2>&1; then
  ledger_exists=true
fi

temporary_dir="$(mktemp -d /tmp/arcp-version-ledger.XXXXXX)"
cleanup() {
  [[ "$temporary_dir" == /tmp/arcp-version-ledger.* && -d "$temporary_dir" ]] || return 0
  rm -rf -- "$temporary_dir"
}
trap cleanup EXIT INT TERM

ledger_file="$temporary_dir/ledger.json"
if [[ "$ledger_exists" == true ]]; then
  git -C "$REPO_ROOT" show "$LEDGER_REF:ledger.json" >"$ledger_file" || die "Remote ledger.json is missing"
else
  node -e '
    const fs=require("fs"); const [out,next,max]=process.argv.slice(1);
    fs.writeFileSync(out,JSON.stringify({schema_version:1,next_version_code:Number(next),android_max_version_code:Number(max),entries:[]},null,2)+"\n");
  ' "$ledger_file" "$INITIAL_VERSION_CODE" "$ANDROID_MAX_VERSION_CODE"
fi

result_file="$temporary_dir/result.json"
next_ledger="$temporary_dir/next-ledger.json"
set +e
node - "$ledger_file" "$result_file" "$next_ledger" "$COMMAND" "$CHANNEL" "$UPSTREAM_LABEL" \
  "$UPSTREAM_SHA" "$LOCAL_SHA" "$REVISION" "$APPLY" <<'NODE'
const fs=require("fs");
const [ledgerPath,resultPath,nextPath,command,channel,upstreamLabel,upstreamSha,localSha,revisionRaw,applyRaw]=process.argv.slice(2);
const ledger=JSON.parse(fs.readFileSync(ledgerPath,"utf8"));
if (ledger.schema_version !== 1 || !Number.isInteger(ledger.next_version_code) ||
    !Number.isInteger(ledger.android_max_version_code) || !Array.isArray(ledger.entries)) throw new Error("invalid ledger schema");
const revision=Number(revisionRaw);
const identity=`${channel}:${upstreamLabel}:${upstreamSha}:${localSha}:r${revision}`;
let entry=ledger.entries.find(value=>value.identity===identity);
if (entry) {
  const immutable={channel,upstream_label:upstreamLabel,upstream_sha:upstreamSha,local_sha:localSha,revision};
  for (const [key,value] of Object.entries(immutable)) if (entry[key] !== value) throw new Error(`identity collision for ${key}`);
} else {
  if (command === "lookup") process.exit(3);
  const code=ledger.next_version_code;
  if (!Number.isInteger(code) || code < 1 || code > ledger.android_max_version_code) throw new Error("versionCode exhausted or invalid");
  const upstreamShort=upstreamSha.slice(0,12), localShort=localSha.slice(0,12);
  const releaseTag=channel === "stable"
    ? `arcp-stable-${upstreamLabel}-${localShort}-vc${code}`
    : `arcp-edge-${upstreamShort}-${localShort}-vc${code}`;
  entry={identity,channel,upstream_label:upstreamLabel,upstream_sha:upstreamSha,local_sha:localSha,revision,
    version_code:code,release_tag:releaseTag};
  if (applyRaw === "true") {
    ledger.entries.push(entry);
    ledger.next_version_code=code+1;
    fs.writeFileSync(nextPath,JSON.stringify(ledger,null,2)+"\n");
  }
}
fs.writeFileSync(resultPath,JSON.stringify(entry)+"\n");
NODE
node_status=$?
set -e
if [[ $node_status -eq 3 ]]; then die "Release identity is not allocated"; fi
[[ $node_status -eq 0 ]] || die "Ledger validation failed"

if [[ "$COMMAND" == allocate && "$APPLY" == true && -f "$next_ledger" ]]; then
  blob_sha="$(git -C "$REPO_ROOT" hash-object -w "$next_ledger")"
  tree_sha="$(printf '100644 blob %s\tledger.json\n' "$blob_sha" | git -C "$REPO_ROOT" mktree)"
  parent_args=()
  if [[ "$ledger_exists" == true ]]; then parent_args=(-p "$(git -C "$REPO_ROOT" rev-parse "$LEDGER_REF^{commit}")"); fi
  entry_identity="$(node -e 'process.stdout.write(require(process.argv[1]).identity)' "$result_file")"
  commit_sha="$(printf 'release: allocate %s\n' "$entry_identity" | \
    git -C "$REPO_ROOT" -c user.name='ARCP Release Ledger' -c user.email='release-ledger@users.noreply.github.com' \
      commit-tree "$tree_sha" "${parent_args[@]}")"
  if ! git -C "$REPO_ROOT" push "$REMOTE" "$commit_sha:refs/heads/$LEDGER_BRANCH" >/dev/null; then
    die "Concurrent ledger update detected; fetch and retry the same identity"
  fi
fi

if [[ "$COMMAND" == allocate && "$APPLY" == false ]]; then
  printf 'PREVIEW: allocation is not reserved\n' >&2
fi
node -e 'const value=require(process.argv[1]); process.stdout.write(JSON.stringify(value)+"\n")' "$result_file"
