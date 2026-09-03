#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ROOT=""
PROFILE=""
RUN_ADAPTERS=false

usage() {
  cat <<'EOF'
Usage: scripts/verify-device-configs.sh --config-root <absolute-directory> [--profile <name>] [--run-adapters]

Validates the public, non-secret profile contract. --run-adapters additionally invokes each profile's
private verifier; it is intended for a trusted local checkout, not public CI.
EOF
}

while (($#)); do
  case "$1" in
    --config-root) (($# >= 2)) || { printf 'ERROR: --config-root requires a value\n' >&2; exit 2; }; CONFIG_ROOT="$2"; shift 2 ;;
    --profile) (($# >= 2)) || { printf 'ERROR: --profile requires a value\n' >&2; exit 2; }; PROFILE="$2"; shift 2 ;;
    --run-adapters) RUN_ADAPTERS=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ -n "$CONFIG_ROOT" ]] || CONFIG_ROOT="${ARCP_CONFIG_ROOT:-}"
[[ -n "$CONFIG_ROOT" ]] || { printf 'ERROR: --config-root or ARCP_CONFIG_ROOT is required\n' >&2; exit 1; }
validator_args=("$CONFIG_ROOT")
[[ -z "$PROFILE" ]] || validator_args+=("$PROFILE")
"$SCRIPT_DIR/validate-device-profiles.mjs" "${validator_args[@]}"

if [[ "$RUN_ADAPTERS" == true ]]; then
  CONFIG_ROOT="$(realpath -e -- "$CONFIG_ROOT")"
  if [[ -n "$PROFILE" ]]; then
    profiles=("$PROFILE")
  else
    mapfile -t profiles < <(find "$CONFIG_ROOT" -mindepth 2 -maxdepth 2 -type f -name profile.json -printf '%h\n' | xargs -r -n1 basename | sort -u)
  fi
  for profile in "${profiles[@]}"; do
    verifier="$(node -e '
      const path=require("path"), fs=require("fs"), root=process.argv[1], name=process.argv[2];
      const p=JSON.parse(fs.readFileSync(path.join(root,name,"profile.json"),"utf8"));
      process.stdout.write(path.resolve(root,name,p.paths.verify));
    ' "$CONFIG_ROOT" "$profile")"
    [[ -f "$verifier" && ! -L "$verifier" ]] || { printf 'ERROR: invalid verifier for profile %s\n' "$profile" >&2; exit 1; }
    "$verifier"
  done
fi
