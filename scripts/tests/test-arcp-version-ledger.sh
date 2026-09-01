#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_ROOT="$(mktemp -d /tmp/arcp-version-ledger-test.XXXXXX)"
PASSED=0

cleanup() {
  [[ "$WORK_ROOT" == /tmp/arcp-version-ledger-test.* && -d "$WORK_ROOT" ]] || return 0
  rm -rf -- "$WORK_ROOT"
}
trap cleanup EXIT INT TERM

pass() {
  PASSED=$((PASSED + 1))
  printf 'ok %d - %s\n' "$PASSED" "$1"
}

remote="$WORK_ROOT/remote.git"
repo="$WORK_ROOT/repo"
git init -q --bare "$remote"
git init -q -b main "$repo"
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.invalid
mkdir -p "$repo/scripts"
cp "$SOURCE_ROOT/scripts/arcp-version-ledger.sh" "$repo/scripts/"
printf 'test\n' >"$repo/README.md"
git -C "$repo" add .
git -C "$repo" commit -q -m initial
git -C "$repo" remote add origin "$remote"
git -C "$repo" push -q -u origin main

upstream_sha=1111111111111111111111111111111111111111
local_sha="$(git -C "$repo" rev-parse HEAD)"
common=(--channel edge --upstream-label edge --upstream-sha "$upstream_sha" --local-sha "$local_sha")

preview="$(cd "$repo" && ARCP_EXPECTED_ORIGIN_URL="$remote" scripts/arcp-version-ledger.sh allocate "${common[@]}")"
[[ "$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).version_code))' "$preview")" == 21000000 ]]
if git --git-dir="$remote" show-ref --verify --quiet refs/heads/release/version-ledger; then
  printf 'not ok - preview mutated the remote ledger\n' >&2
  exit 1
fi
pass "preview allocates no remote version code"

first="$(cd "$repo" && ARCP_EXPECTED_ORIGIN_URL="$remote" scripts/arcp-version-ledger.sh allocate "${common[@]}" --apply)"
first_code="$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).version_code))' "$first")"
first_tag="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).release_tag)' "$first")"
[[ "$first_code" == 21000000 && "$first_tag" == arcp-edge-*-vc21000000 ]]
first_head="$(git --git-dir="$remote" rev-parse refs/heads/release/version-ledger)"

repeat="$(cd "$repo" && ARCP_EXPECTED_ORIGIN_URL="$remote" scripts/arcp-version-ledger.sh allocate "${common[@]}" --apply)"
[[ "$repeat" == "$first" ]]
[[ "$(git --git-dir="$remote" rev-parse refs/heads/release/version-ledger)" == "$first_head" ]]
pass "same immutable identity reuses its allocation without a ledger commit"

second="$(cd "$repo" && ARCP_EXPECTED_ORIGIN_URL="$remote" scripts/arcp-version-ledger.sh allocate \
  "${common[@]}" --revision 2 --apply)"
second_code="$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).version_code))' "$second")"
[[ "$second_code" == 21000001 ]]
lookup="$(cd "$repo" && ARCP_EXPECTED_ORIGIN_URL="$remote" scripts/arcp-version-ledger.sh lookup \
  "${common[@]}" --revision 2)"
[[ "$lookup" == "$second" ]]
pass "repair identity receives a greater code and is remotely retrievable"

ledger="$(git --git-dir="$remote" show refs/heads/release/version-ledger:ledger.json)"
node -e '
  const ledger=JSON.parse(process.argv[1]);
  if (ledger.next_version_code !== 21000002 || ledger.entries.length !== 2) process.exit(1);
  const codes=new Set(ledger.entries.map(entry=>entry.version_code));
  if (codes.size !== ledger.entries.length) process.exit(1);
' "$ledger"
pass "persisted ledger is append-only and contains unique increasing codes"

set +e
wrong_origin_output="$(cd "$repo" && scripts/arcp-version-ledger.sh lookup "${common[@]}" 2>&1)"
wrong_origin_status=$?
set -e
[[ $wrong_origin_status -ne 0 && "$wrong_origin_output" == *'origin URL is not the expected owner repository'* ]]
pass "unexpected owner remote fails closed"

printf '1..%d\n' "$PASSED"
