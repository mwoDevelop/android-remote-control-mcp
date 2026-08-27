#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd -- "$TEST_DIR/.." && pwd)/deploy-[REDACTED_DEVICE_ALIAS]-debug-poc.sh"
REPO_ROOT="$(cd -- "$TEST_DIR/../.." && pwd)"
SHIZUKU_MANIFEST="$REPO_ROOT/shizuku-admin/src/main/AndroidManifest.xml"

help_output="$("$SCRIPT" --help)"
[[ "$help_output" == *'127.0.0.1:8081'* ]]
[[ "$help_output" == *'never grants Shizuku permission'* ]]

preview_output="$("$SCRIPT" --serial [REDACTED_DEVICE_ALIAS]-test)"
[[ "$preview_output" == PREVIEW:* ]]
[[ "$preview_output" == *'beside production'* ]]

set +e
missing_serial_output="$("$SCRIPT" --apply 2>&1)"
missing_serial_status=$?
set -e
[[ $missing_serial_status -ne 0 ]]
[[ "$missing_serial_output" == *'--serial is required'* ]]

script_source="$(<"$SCRIPT")"
[[ "$script_source" == *"tr '[:upper:]' '[:lower:]'"* ]]
[[ "$script_source" == *'for _ in {1..30}'* ]]

manifest_source="$(<"$SHIZUKU_MANIFEST")"
[[ "$manifest_source" == *'android:name="rikka.shizuku.ShizukuProvider"'* ]]
[[ "$manifest_source" == *'android:authorities="${applicationId}.shizuku"'* ]]
[[ "$manifest_source" == *'android:permission="android.permission.INTERACT_ACROSS_USERS_FULL"'* ]]

printf '1..5\nok 1 - help documents isolation and Shizuku boundary\nok 2 - default is a non-mutating preview\nok 3 - apply rejects implicit device selection\nok 4 - live identity and listener checks are normalized and bounded\nok 5 - isolated module declares the required Shizuku provider\n'
