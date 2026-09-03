#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_CLI="$(cd -- "$TEST_DIR/.." && pwd)/arcp"
WORK_ROOT="$(mktemp -d)"
FAKE_ROOT="$WORK_ROOT/repo"
FAKE_BIN="$WORK_ROOT/bin"
STATE="$WORK_ROOT/state"
LOG="$WORK_ROOT/calls.log"
WORKFLOW_SHA="1111111111111111111111111111111111111111"
UPSTREAM_SHA="2222222222222222222222222222222222222222"
LOCAL_SHA="3333333333333333333333333333333333333333"
PASSED=0

cleanup() { [[ ! -d "$WORK_ROOT" ]] || rm -rf -- "$WORK_ROOT"; }
trap cleanup EXIT

pass() { PASSED=$((PASSED + 1)); printf 'ok %d - %s\n' "$PASSED" "$1"; }

expect_failure() {
  local name="$1" pattern="$2" output status
  shift 2
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 && "$output" == *"$pattern"* ]] || {
    printf 'not ok - %s\n%s\n' "$name" "$output" >&2
    exit 1
  }
  pass "$name"
}

set_workflow_state() { printf '%s' "$2" > "$STATE/workflow-$1"; }

reset_state() {
  rm -rf -- "$STATE"
  mkdir -p "$STATE"
  : > "$LOG"
  set_workflow_state ci active
  set_workflow_state arcp active
  set_workflow_state edge disabled_manually
  set_workflow_state release disabled_manually
}

make_fixture() {
  mkdir -p "$FAKE_ROOT/scripts" "$FAKE_BIN"
  cp "$SOURCE_CLI" "$FAKE_ROOT/scripts/arcp"
  chmod +x "$FAKE_ROOT/scripts/arcp"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "%s\n" "$*" >> "${FAKE_CALL_LOG:?}"' \
    'if [[ "$1" == channel-info ]]; then' \
    '  printf "{\"schema_version\":2,\"channel\":\"edge\",\"upstream_label\":\"edge\",\"upstream_sha\":\"%s\",\"local_ref\":\"release/edge\",\"local_sha\":\"%s\"}\n" "${FAKE_UPSTREAM_SHA:?}" "${FAKE_LOCAL_SHA:?}"' \
    'fi' > "$FAKE_ROOT/scripts/sync-build-deploy.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$FAKE_ROOT/scripts/arcp-release-artifact.sh"
  chmod +x "$FAKE_ROOT/scripts"/*

  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'args="$*"' \
    'case "$args" in' \
    ' *" remote get-url origin") printf "https://github.com/mwoDevelop/android-remote-control-mcp.git\n" ;;' \
    ' *" symbolic-ref --quiet --short HEAD") printf "%s\n" "${FAKE_GIT_BRANCH:-main}" ;;' \
    ' *" status --porcelain --untracked-files=normal") [[ "${FAKE_GIT_DIRTY:-false}" != true ]] || printf "?? dirty\n" ;;' \
    ' *" fetch --no-tags origin "*) exit 0 ;;' \
    ' *" rev-parse HEAD") printf "%s\n" "${FAKE_WORKFLOW_SHA:?}" ;;' \
    ' *" rev-parse refs/remotes/origin/main") printf "%s\n" "${FAKE_REMOTE_SHA:-${FAKE_WORKFLOW_SHA:?}}" ;;' \
    ' *) printf "unexpected fake git call: %s\n" "$args" >&2; exit 2 ;;' \
    'esac' > "$FAKE_BIN/git"

  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "gh %s\n" "$*" >> "${FAKE_CALL_LOG:?}"' \
    'state=${FAKE_STATE:?}' \
    'workflow_json() {' \
    '  node - "$state" <<"NODE"' \
    'const fs=require("fs"), d=process.argv[2];' \
    'const read=n=>fs.readFileSync(`${d}/workflow-${n}`,"utf8");' \
    'const rows=[' \
    ' {id:1,name:"CI",path:".github/workflows/ci.yml",state:read("ci")},' \
    ' {id:2,name:"ARCP channel release",path:".github/workflows/arcp-channel-release.yml",state:read("arcp")},' \
    ' {id:3,name:"Legacy Edge Release (manual only)",path:".github/workflows/edge-release.yml",state:read("edge")},' \
    ' {id:4,name:"Release",path:".github/workflows/release.yml",state:read("release")}];' \
    'process.stdout.write(JSON.stringify(rows));' \
    'NODE' \
    '}' \
    'case "${1:-} ${2:-}" in' \
    ' "auth status") exit 0 ;;' \
    ' "repo view") printf "mwoDevelop/android-remote-control-mcp\n" ;;' \
    ' "workflow list") workflow_json ;;' \
    ' "workflow enable"|"workflow disable")' \
    '   action=$2; path=$3' \
    '   [[ "${FAKE_GH_FAIL_PATH:-}" != "$path" ]] || exit 9' \
    '   case "$path" in *ci.yml) key=ci ;; *arcp-channel-release.yml) key=arcp ;; *edge-release.yml) key=edge ;; *release.yml) key=release ;; esac' \
    '   [[ "$action" == enable ]] && value=active || value=disabled_manually' \
    '   printf "%s" "$value" > "$state/workflow-$key" ;;' \
    ' "workflow run")' \
    '   for arg in "$@"; do case "$arg" in request_id=*) printf "%s" "${arg#request_id=}" > "$state/request" ;; publish=*) printf "%s" "${arg#publish=}" > "$state/publish" ;; esac; done ;;' \
    ' "run list")' \
    '   request="$(cat "$state/request" 2>/dev/null || true)"' \
    '   publish="$(cat "$state/publish" 2>/dev/null || printf false)"; [[ "$publish" == true ]] && mode=publish || mode=dry-run' \
    '   count=0; [[ ! -f "$state/list-count" ]] || count="$(cat "$state/list-count")"; count=$((count+1)); printf "%s" "$count" > "$state/list-count"' \
    '   if ((count <= ${FAKE_GH_EMPTY_LISTS:-0})); then printf "[]\n"; exit 0; fi' \
    '   duplicate=${FAKE_GH_DUPLICATE:-false}' \
    '   node - "$request" "$duplicate" "$mode" <<"NODE"' \
    'const [request,duplicate,mode]=process.argv.slice(2); const row={databaseId:4242,displayTitle:`ARCP edge r1 ${mode} [${request}]`,' \
    ' event:"workflow_dispatch",headBranch:"main",headSha:process.env.FAKE_WORKFLOW_SHA,status:"queued",conclusion:"",url:"https://example.invalid/runs/4242"};' \
    'process.stdout.write(JSON.stringify(duplicate==="true"?[row,{...row,databaseId:4243,url:"https://example.invalid/runs/4243"}]:[row]));' \
    'NODE' \
    '   ;;' \
    ' "run watch") [[ "${FAKE_GH_WATCH_FAIL:-false}" != true ]] ;;' \
    ' "run view")' \
    '   request="$(cat "$state/request")"; publish="$(cat "$state/publish" 2>/dev/null || printf false)"; [[ "$publish" == true ]] && mode=publish || mode=dry-run' \
    '   conclusion=success; [[ "${FAKE_GH_WATCH_FAIL:-false}" != true ]] || conclusion=failure' \
    '   node - "$request" "$conclusion" "$mode" <<"NODE"' \
    'const [request,conclusion,mode]=process.argv.slice(2); process.stdout.write(JSON.stringify({databaseId:4242,' \
    ' displayTitle:`ARCP edge r1 ${mode} [${request}]`,event:"workflow_dispatch",headBranch:"main",headSha:process.env.FAKE_WORKFLOW_SHA,' \
    ' status:"completed",conclusion,url:"https://example.invalid/runs/4242"}));' \
    'NODE' \
    '   ;;' \
    ' "run download")' \
    '   directory=""; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == --dir ]]; then j=$((i+1)); directory="${!j}"; fi; done' \
    '   mkdir -p "$directory"; request="$(cat "$state/request")"; publish="$(cat "$state/publish" 2>/dev/null || printf false)"' \
    '   if [[ -n "${FAKE_RESULT_STATUS:-}" ]]; then result_status="$FAKE_RESULT_STATUS"; elif [[ "$publish" == true ]]; then result_status=published; else result_status=dry_run_validated; fi' \
    '   node - "$directory/release-result.json" "$request" "$result_status" <<"NODE"' \
    'const fs=require("fs"), [out,request,status]=process.argv.slice(2); fs.writeFileSync(out,JSON.stringify({schema_version:1,type:"arcp_release_result",' \
    ' status,request_id:request,run_id:4242,channel:"edge",upstream_sha:process.env.FAKE_UPSTREAM_SHA,' \
    ' local_sha:process.env.FAKE_LOCAL_SHA,release_tag:"arcp-edge-test-vc1"})+"\n");' \
    'NODE' \
    '   ;;' \
    ' "release view") printf "{\"tagName\":\"arcp-edge-test-vc1\",\"targetCommitish\":\"%s\",\"isPrerelease\":true}\n" "${FAKE_LOCAL_SHA:?}" ;;' \
    ' *) printf "unexpected fake gh call: %s\n" "$*" >&2; exit 2 ;;' \
    'esac' > "$FAKE_BIN/gh"
  chmod +x "$FAKE_BIN"/*
  reset_state
}

run_cli() {
  PATH="$FAKE_BIN:$PATH" ARCP_REPO_ROOT_OVERRIDE="$FAKE_ROOT" ARCP_DISCOVERY_ATTEMPTS=3 \
    ARCP_DISCOVERY_INTERVAL_SECONDS=0 FAKE_STATE="$STATE" FAKE_CALL_LOG="$LOG" \
    FAKE_WORKFLOW_SHA="$WORKFLOW_SHA" FAKE_UPSTREAM_SHA="$UPSTREAM_SHA" FAKE_LOCAL_SHA="$LOCAL_SHA" \
    "$FAKE_ROOT/scripts/arcp" "$@"
}

run_cli_partial_failure() { FAKE_GH_FAIL_PATH=.github/workflows/release.yml run_cli "$@"; }
run_cli_duplicate() { FAKE_GH_DUPLICATE=true run_cli "$@"; }
run_cli_dirty() { FAKE_GIT_DIRTY=true run_cli "$@"; }
run_cli_diverged() { FAKE_REMOTE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa run_cli "$@"; }
run_cli_watch_failure() { FAKE_GH_WATCH_FAIL=true run_cli "$@"; }
run_cli_existing_noop() { FAKE_RESULT_STATUS=existing_verified_noop run_cli "$@"; }

test_build_contract() {
  local output
  reset_state
  run_cli build >/dev/null
  [[ "$(tail -1 "$LOG")" == 'build --variant gmsDebug' ]]
  run_cli build stable --variant fossDebug --skip-e2e-compile >/dev/null
  [[ "$(tail -1 "$LOG")" == 'build --variant fossDebug --latest-stable --skip-e2e-compile' ]]
  expect_failure 'channel release variants fail before build' 'produced only' run_cli build edge --variant gmsRelease
  [[ "$(grep -c '^build ' "$LOG")" -eq 2 ]]
  expect_failure 'local release requires signing configuration' 'requires ignored keystore.properties' \
    run_cli build local --variant gmsRelease
  output="$(run_cli --help)"
  [[ "$output" == *'scripts/arcp release <stable|edge>'* ]]
  pass 'build aliases delegate safely with documented defaults'
}

test_github_configuration() {
  local before_calls after_calls
  reset_state
  set_workflow_state edge active
  set_workflow_state release active
  expect_failure 'workflow status detects legacy publisher drift' 'disabled_manually' run_cli github status
  run_cli github configure >/dev/null
  [[ "$(<"$STATE/workflow-edge")" == active && "$(<"$STATE/workflow-release")" == active ]]
  run_cli github configure --apply >/dev/null
  run_cli github status >/dev/null
  [[ "$(<"$STATE/workflow-edge")" == disabled_manually && "$(<"$STATE/workflow-release")" == disabled_manually ]]
  before_calls="$(grep -Ec '^gh workflow (enable|disable)' "$LOG")"
  run_cli github configure --apply >/dev/null
  after_calls="$(grep -Ec '^gh workflow (enable|disable)' "$LOG")"
  [[ "$before_calls" == "$after_calls" ]]
  set_workflow_state release active
  expect_failure 'partial configuration failure is detected' 'did not converge' \
    run_cli_partial_failure github configure --apply
  pass 'GitHub desired state is previewed, converged and idempotent'
}

test_release_dispatch_and_resume() {
  local output request
  reset_state
  output="$(run_cli release edge --no-wait)"
  request="$(sed -n 's/^request_id=//p' <<<"$output")"
  [[ "$request" =~ ^arcp-[A-Za-z0-9._-]+$ && "$output" == *'run_id=4242'* ]]
  grep -Fq "expected_source_sha=$UPSTREAM_SHA" "$LOG"
  grep -Fq "expected_local_sha=$LOCAL_SHA" "$LOG"
  grep -Fq 'publish=false' "$LOG"
  output="$(run_cli release status --request-id "$request" --watch)"
  [[ "$output" == *'result=dry_run_validated'* ]]
  pass 'dry-run dispatch pins sources and resumes by exact request ID'
}

test_release_publication_results() {
  local output
  reset_state
  output="$(run_cli release edge --publish)"
  [[ "$output" == *'result=published'* ]]
  grep -Fq 'publish=true' "$LOG"
  grep -Fq 'gh release view arcp-edge-test-vc1' "$LOG"
  reset_state
  output="$(run_cli_existing_noop release edge --publish)"
  [[ "$output" == *'result=existing_verified_noop'* ]]
  pass 'publication and existing immutable no-op are reported and remotely verified'
}

test_release_failure_guards() {
  local output
  reset_state
  output="$(FAKE_GH_EMPTY_LISTS=1 run_cli release edge --no-wait)"
  [[ "$output" == *'run_id=4242'* && "$(<"$STATE/list-count")" == 2 ]]
  reset_state
  expect_failure 'duplicate correlated runs fail closed' 'More than one' \
    run_cli_duplicate release edge --no-wait
  reset_state
  expect_failure 'dirty worktree blocks dispatch' 'clean worktree' \
    run_cli_dirty release edge --no-wait
  reset_state
  expect_failure 'diverged main blocks dispatch' 'differs from authoritative' \
    run_cli_diverged release edge --no-wait
  reset_state
  set_workflow_state release active
  expect_failure 'publication blocks on legacy workflow drift' 'single-publisher' run_cli release edge --publish --no-wait
  reset_state
  output="$(run_cli release edge --no-wait)"
  request="$(sed -n 's/^request_id=//p' <<<"$output")"
  expect_failure 'terminal workflow failure is propagated' 'conclusion=failure' \
    run_cli_watch_failure release status --request-id "$request" --watch
  pass 'registration, repository and terminal failure paths fail closed'
}

make_fixture
test_build_contract
test_github_configuration
test_release_dispatch_and_resume
test_release_publication_results
test_release_failure_guards
printf '1..%d\n' "$PASSED"
