# Unified ARCP CLI and release entrypoint

Status: independently reviewed; accepted findings incorporated; implementation in progress.

Independent review: `docs/reviews/77_unified_arcp_cli_and_release_entrypoint_review_20260903.md`

## Goal

Expose one small, safe command-line interface for routine ARCP builds and releases while retaining the existing
qualified scripts as internal implementation units. Make `ARCP channel release` the only enabled GitHub publication
workflow in the owner fork, without deleting or editing the two inherited/legacy workflow definitions merely to
disable them.

## Verified baseline

- `scripts/sync-build-deploy.sh` already resolves and builds the reviewed `release/stable` and `release/edge`
  integrations; it is the source of truth for build, provenance and deployment checks.
- `.github/workflows/arcp-channel-release.yml` already allocates the global version code, builds GMS and FOSS without
  signing secrets, runs protected live-ngrok qualification, signs in a protected environment and optionally publishes
  an immutable release.
- `scripts/arcp-version-ledger.sh`, `scripts/sign-arcp-channel-release.sh`,
  `scripts/publish-arcp-channel-release.sh` and `scripts/arcp-release-artifact.sh` remain focused internal building
  blocks. Their security boundaries must not be duplicated in the new CLI.
- The owner repository currently reports `CI`, `ARCP channel release`, `Release`, and
  `Legacy Edge Release (manual only)` as active. The latter two publication workflows must become
  `disabled_manually` in the fork.
- The owner `main` contains the official upstream `main`; there are no currently unintegrated upstream commits.
- Local `main` is one existing documentation commit ahead of `origin/main`; preserve that commit and add this work in
  a separate commit.

## Public command contract

Add executable `scripts/arcp` with these user-facing commands:

```text
scripts/arcp build [local|stable|edge] [--variant gmsDebug|fossDebug|gmsRelease|fossRelease]
                   [--skip-e2e-compile]
scripts/arcp release <stable|edge> [--revision N] [--publish] [--no-wait]
scripts/arcp release status [--limit N] [--request-id <id>] [--watch]
scripts/arcp github status
scripts/arcp github configure [--apply]
```

Defaults and safety rules:

1. `build` defaults to source `local` and variant `gmsDebug`; channel builds delegate to
   `sync-build-deploy.sh build --latest-<channel>`. `stable` and `edge` accept only debug variants. Installable channel
   Release artifacts are produced exclusively by `release`; internal ledger-backed unsigned builds remain available
   to the workflow through `sync-build-deploy.sh`.
2. `release` defaults to revision `1`, `publish=false`, remote `main`, and waiting for the exact dispatched run.
   Only literal `--publish` may request publication. The CLI never reads signing secrets.
3. Give every dispatch a generated, allowlisted request ID, pass it as a workflow input, and include it in `run-name`.
   Before dispatch, resolve the authoritative upstream/local channel identity and pass both full SHAs as workflow
   guards. The workflow must call `channel-info` with both expected SHAs so movement while queued fails closed.
4. Resolve the run by its exact request ID rather than assuming the newest run belongs to this invocation. Match the
   exact owner repository, workflow, `workflow_dispatch` event, `main` head branch and workflow-source SHA; reject zero
   or duplicate matches. `--no-wait` means wait only for bounded run registration, then print exact machine-usable
   `request_id`, `run_id` and `url`. Exact status can later be resumed with `release status --request-id`; `--watch`
   propagates the workflow conclusion. Plain status listing remains informational.
5. Refuse a release when the owner origin URL is wrong, the current branch is not `main`, the worktree is dirty, an
   authoritative `git fetch --no-tags origin main` shows local `HEAD` differs from `origin/main`, GitHub authentication
   or repository identity is wrong, or the selected channel does not pass the existing source resolver. This prevents
   releasing code that GitHub cannot see. Deliberately support and test only the expected HTTPS/SSH owner remote forms.
6. `github configure` is a dry-run unless `--apply` is present. Applying enables `arcp-channel-release.yml`, disables
   `edge-release.yml` and `release.yml`, and leaves `ci.yml` active. Verify the resulting states after mutation.
   Address known workflows by exact path, print before/desired/after state plus rollback commands, remain idempotent,
   and fail closed on partial convergence. Unknown active workflow paths are reported for human review, never disabled
   automatically.
7. Do not delete or modify inherited workflow content merely to disable it. GitHub workflow state is the adapter
   boundary that preserves upstream mergeability. A repository update may require rerunning `github configure`;
   `github status` must report drift with a non-zero exit status.
8. Preserve direct low-level script compatibility for CI and recovery, but document it as an internal interface.
9. `release --publish` must fail before expensive publication work when the activation variable is not exactly true,
   and workflow success must be followed by verification of the expected immutable release. Never silently downgrade
   a requested publication to a dry-run. Report explicit outcomes: `dry_run_validated`, `published`, or
   `existing_verified_noop`.
10. Bound `revision` to `1..9999`; values greater than one are explicit same-source repairs, not ordinary retries.

## Workflow and documentation changes

1. Add optional, validated `request_id`, `expected_source_sha` and `expected_local_sha` inputs to
   `arcp-channel-release.yml`, plus a deterministic `run-name` containing request ID, channel, revision and mode.
   CLI dispatches provide all three. Blank manual UI SHA inputs retain explicit resolve-at-run-start semantics and are
   documented as unpinned/manual; blank request IDs use the unique GitHub run ID in the displayed fallback.
2. Separate read-only source/version preview and signing from write-capable ledger reservation/publication. A dry-run
   must receive no `contents: write` token. The publication job is conditional on `publish=true`, receives no signing
   key, checks `ENABLE_ARCP_RELEASE_PUBLISHING=true`, and publishes only the signed closed artifact set.
3. Add a shell contract test for parsing, delegation, safe defaults, exact run correlation, timeout/failure
   propagation, remote/worktree guards and GitHub workflow desired-state handling. All GitHub and build commands are
   mocked in unit-style tests; no release is created by the test suite.
4. Register the test in CI beside the existing release/build shell contract suites.
5. Update the root README and `docs/ARCP_CHANNEL_RELEASES.md` to present `scripts/arcp` as the routine interface,
   explain that legacy workflows remain in Git but are disabled in the owner repository, and retain a short internal
   troubleshooting reference to the underlying scripts.

## Delivery and verification

1. Run shell syntax validation and the new focused contract test.
2. Run the existing sync/build, version-ledger and channel-release contract suites to prove delegation did not weaken
   their invariants.
3. Run `actionlint` on all workflows (using the existing repository/tooling convention).
4. Exercise both stable/edge delegations in tests and live read-only `channel-info` resolution for both channels. Run
   one real representative channel debug build through `scripts/arcp build`; the other channel may remain a mocked
   delegation because the unchanged backend has its own contract suite.
5. Push the implementation commit to `origin/main`, monitor the resulting CI run to success, then run
   `scripts/arcp github configure --apply` and verify that only `ARCP channel release` and `CI` remain active.
6. Snapshot releases and `release/version-ledger`, then exercise a real `scripts/arcp release edge --no-wait` dry-run
   dispatch after deployment. Capture exact registration and resume it using
   `scripts/arcp release status --request-id <id> --watch`. It must complete successfully without changing either
   snapshot. If protected environment approval is required, report that manual gate rather than weakening it.
7. Confirm no tracked secret/env/keystore material was introduced, commit with Conventional Commits, and push without
   rewriting the pre-existing local commit.

## Acceptance criteria

- The documented build and release examples use only `scripts/arcp` for routine work.
- Stable and edge builds delegate to the correct reviewed local integration branches.
- Channel builds reject Release variants before expensive work; signed Release artifacts come only from the workflow.
- Dry-run is the release default; publication requires `--publish` and stays inside GitHub protected environments.
- Concurrent dispatches cannot be confused because the CLI follows an exact request ID, and queued movement cannot
  change its two pinned source SHAs.
- Dry-run jobs have no write token, and requested publication cannot silently become a dry-run.
- GitHub desired state has `CI` and `ARCP channel release` active and both legacy publication workflows disabled.
- Existing low-level security/provenance tests and the new CLI tests pass; GitHub CI is green.
- No secrets are tracked and no Android device/application deployment is performed for this tooling-only change.

## Rollback

- Revert the implementation commit to remove the public CLI and request-ID input.
- Re-enable either legacy workflow explicitly with `gh workflow enable <workflow>` only if its historical recovery
  path is intentionally needed.
- Workflow disabling does not delete workflow history, tags, releases or artifacts.
