#!/usr/bin/env bash

# This library intentionally does not resolve configuration while being sourced.
# Device commands call arcp_load_profile after command validation.

arcp_config_die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

arcp_resolve_config_root() {
  local explicit="${1:-}" candidate
  candidate="$explicit"
  [[ -n "$candidate" ]] || candidate="${ARCP_CONFIG_ROOT:-}"
  [[ -n "$candidate" ]] || arcp_config_die "device operation requires --config-root or ARCP_CONFIG_ROOT"
  [[ "$candidate" == /* ]] || arcp_config_die "configuration root must be an absolute directory"
  [[ -d "$candidate" && -r "$candidate" && ! -L "$candidate" ]] || arcp_config_die "configuration root must be a readable non-symlink directory"
  ARCP_CONFIG_ROOT_RESOLVED="$(cd -- "$candidate" && pwd -P)" || return 1
  export ARCP_CONFIG_ROOT_RESOLVED
}

arcp_load_profile() {
  local explicit_root="${1:-}" profile="${2:-}" validator
  [[ "$profile" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || arcp_config_die "invalid profile name"
  arcp_resolve_config_root "$explicit_root" || return 1
  validator="${ARCP_PROFILE_VALIDATOR:-${SCRIPT_DIR:?}/validate-device-profiles.mjs}"
  node "$validator" "$ARCP_CONFIG_ROOT_RESOLVED" "$profile" >/dev/null || return 1
  ARCP_PROFILE_ROOT="$(realpath -e -- "$ARCP_CONFIG_ROOT_RESOLVED/$profile")" || return 1
  ARCP_PROFILE_FILE="$ARCP_PROFILE_ROOT/profile.json"
  export ARCP_PROFILE_ROOT ARCP_PROFILE_FILE
}

arcp_profile_value() {
  local dotted="$1"
  node -e '
    const value=process.argv[2].split(".").reduce((v,k)=>v==null?undefined:v[k],JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")));
    if (value===undefined || value===null || typeof value==="object") process.exit(2);
    process.stdout.write(String(value));
  ' "$ARCP_PROFILE_FILE" "$dotted"
}

arcp_profile_path() {
  local key="$1" relative candidate resolved
  relative="$(arcp_profile_value "paths.$key")" || return 1
  [[ -n "$relative" && "$relative" != /* ]] || arcp_config_die "invalid profile path"
  candidate="$ARCP_PROFILE_ROOT/$relative"
  [[ -e "$candidate" && ! -L "$candidate" ]] || arcp_config_die "required profile path is missing or is a symlink"
  resolved="$(realpath -e -- "$candidate")" || return 1
  [[ "$resolved" == "$ARCP_PROFILE_ROOT/"* ]] || arcp_config_die "profile path escapes its root"
  printf '%s' "$resolved"
}
