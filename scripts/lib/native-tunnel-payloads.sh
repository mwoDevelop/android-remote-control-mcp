#!/usr/bin/env bash

# Shared fail-closed APK payload validator. The JSON contract is the only ABI matrix.
validate_native_tunnel_payload() {
  local apk="$1" entries
  require_command node
  require_command unzip
  entries="$(unzip -Z1 "$apk")"
  if ! node "$REPO_ROOT/scripts/native-tunnel-payloads.mjs" "$REPO_ROOT" validate <<<"$entries"; then
    die "APK tunnel payload does not satisfy config/arcp-native-payloads.json"
  fi
}
