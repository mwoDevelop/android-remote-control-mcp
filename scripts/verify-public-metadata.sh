#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
failed=false
mapfile -d '' -t tracked < <(git -C "$REPO_ROOT" ls-files -z)

report_path() {
  printf 'ERROR: %s at %s\n' "$1" "$2" >&2
  failed=true
}

report_matches() {
  local category="$1" pattern="$2"
  shift 2
  local output
  if command -v rg >/dev/null 2>&1; then
    output="$(rg -n -i --no-heading --color never "$pattern" "$@" 2>/dev/null | awk -F: '{print $1 ":" $2}' | sort -u || true)"
  else
    output="$(grep -Eni "$pattern" "$@" 2>/dev/null | awk -F: '{print $1 ":" $2}' | sort -u || true)"
  fi
  while IFS= read -r location; do [[ -z "$location" ]] || report_path "$category" "$location"; done <<<"$output"
}

for file in "${tracked[@]}"; do
  case "$file" in
    e2e-tests/src/test/resources/simple-calculator.apk) ;;
    myconf/*|*/.env.secrets|*.tfstate|*.tfstate.*|*.tfplan|*.jks|*.keystore|*.apk|*.aab|*/.terraform/*)
      report_path "forbidden tracked configuration or artifact" "$file"
      ;;
    */live-snapshot.json|*/chatgpt/connectors.json|*/ngrok/account.json|*/regery/domain.json)
      report_path "forbidden provider or connector snapshot" "$file"
      ;;
  esac
done

scan_files=()
email_files=()
network_files=()
for file in "${tracked[@]}"; do
  case "$file" in vendor/*) continue ;; esac
  [[ -f "$REPO_ROOT/$file" ]] || continue
  scan_files+=("$REPO_ROOT/$file")
  case "$file" in
    .claude-plugin/marketplace.json|app/src/main/res/values/strings.xml|app/src/main/kotlin/*/ui/screens/AboutScreen.kt|docs/plans/[1-5]*.md) ;;
    *) email_files+=("$REPO_ROOT/$file") ;;
  esac
  case "$file" in app/src/test/*|scripts/tests/*|scripts/location-db/test_*|docs/plans/[1-5]*.md) ;;
    *) network_files+=("$REPO_ROOT/$file") ;;
  esac
done

# Terms are assembled so this policy file does not match its own denylist.
alias_pattern="x11"'t'"|a34"'s'"|bed"'tv'"|bedroom[[:space:]_-]+tv|xiaomi11"'t'"|quo"'stodio'
domain_pattern='[.]pp[.]ua([/:]|$)'
report_matches "named private device or security-product metadata" "$alias_pattern" "${scan_files[@]}"
report_matches "private domain metadata" "$domain_pattern" "${scan_files[@]}"
report_matches "non-upstream personal account email" '@gmail[.]com' "${email_files[@]}"
report_matches "exact private-network host outside tests" '(^|[^0-9])(10[.][0-9]{1,3}[.][0-9]{1,3}[.][0-9]{1,3}|172[.](1[6-9]|2[0-9]|3[01])[.][0-9]{1,3}[.][0-9]{1,3}|192[.]168[.][0-9]{1,3}[.][0-9]{1,3})(:[0-9]+)?([^0-9]|$)' "${network_files[@]}"

[[ "$failed" == false ]] || exit 1
printf 'OK: tracked public tree contains no forbidden owner configuration metadata or generated artifacts.\n'
