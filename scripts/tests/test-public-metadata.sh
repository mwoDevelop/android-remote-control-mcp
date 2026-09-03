#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$TEST_DIR/../verify-public-metadata.sh"
tmp="$(mktemp -d)"
trap 'find "$tmp" -depth -delete' EXIT

"$SOURCE" >/dev/null
mkdir -p "$tmp/scripts"
cp "$SOURCE" "$tmp/scripts/verify-public-metadata.sh"
chmod +x "$tmp/scripts/verify-public-metadata.sh"
git -C "$tmp" init -q -b main
git -C "$tmp" config user.name Test
git -C "$tmp" config user.email test@example.invalid
suffix='p''p.u''a'
printf 'endpoint=https://private-host.%s/mcp\n' "$suffix" >"$tmp/config.txt"
git -C "$tmp" add .

set +e
output="$("$tmp/scripts/verify-public-metadata.sh" 2>&1)"
status=$?
set -e
[[ $status -ne 0 ]]
[[ "$output" == *'private domain metadata at '*'/config.txt:1'* ]]
[[ "$output" != *'private-host'* ]]
printf 'OK: public metadata policy passes the tree and redacts a synthetic rejection.\n'
