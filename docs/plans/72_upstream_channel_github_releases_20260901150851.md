<!-- IMPLEMENTED, PUSHED AND REMOTELY ACCEPTED — mirror APKs were not deployed to devices. -->
<!-- Never commit keystores, signing passwords, tokens, generated properties or release credentials. -->

# Plan 72 — Publish qualified stable and edge builds from the official upstream

Automate GitHub Release publication for the two already supported pure-upstream channels. The publishing path must
consume the same channel resolution and build entrypoint as local use: `build --latest-stable` for the newest strict
`vMAJOR.MINOR.PATCH` tag and `build --latest-edge` for the official moving `edge` tag. It must not add an arbitrary
`develop` or branch-name channel.

## Implementation and acceptance status — 2026-09-01

Implemented and pushed in commits beginning with `15fed32`, with remote-run corrections through `35eb03e` and the
host-independent bootstrap test in `5338668`:

- secretless unsigned Release builds through `--latest-stable` / `--latest-edge`, with
  `--expected-source-sha` as a fail-closed guard and no arbitrary developer channel;
- portable per-variant pre-sign manifests, one bounded test-task retry recorded in provenance, and separate trusted
  signing with raw/zipaligned/signed hashes;
- stable immutable and edge rolling publication logic, pre-release enforcement, exact asset allowlists, remote asset
  re-verification, edge backup plus best-effort rollback, and non-mutating dry-run by default;
- a scheduled/manual GitHub workflow with pinned Actions, non-persisted build credentials, read-only untrusted build
  permissions, protected signing environment and an explicit repository-variable activation switch;
- root and detailed release-channel documentation plus CI execution of shell/contract/actionlint validation.

Acceptance evidence:

- 32 build/deploy contract tests and 12 release-workflow tests pass for stable/edge, GMS/FOSS, wrong certificate,
  source drift, unsupported branch, extra/damaged/missing assets, stable idempotence and rolling edge replacement;
- `actionlint v1.7.7`, shell syntax and the secretless Gradle init script validate;
- real stable `v1.12.0` source `3777403d148283c5a18a3e8122ff819da4eed808` produced qualified unsigned
  `gmsRelease` and `fossRelease` APKs; a temporary test certificate signed both, both re-verified and the publisher
  completed a no-mutation dry run;
- real edge source `16f39717ce0969aa81a4ec132ba1cad861ba46cc` produced a qualified unsigned `gmsRelease` APK;
- a confirmed upstream server-start race failed once in a repeated stable test run. The workflow now retries the same
  secretless Gradle task at most once; deterministic double failures remain fatal and the retry is recorded.
- the protected GitHub Environment `upstream-releases` contains the four signing secrets by name, the public
  certificate/activation variables, and a deployment branch policy restricted to `main`;
- [stable workflow run `33531282998`](https://github.com/mwoDevelop/android-remote-control-mcp/actions/runs/33531282998)
  completed both jobs and published immutable pre-release
  [`upstream-v1.12.0`](https://github.com/mwoDevelop/android-remote-control-mcp/releases/tag/upstream-v1.12.0);
- [edge workflow run `33535264145`](https://github.com/mwoDevelop/android-remote-control-mcp/actions/runs/33535264145)
  completed both jobs and published rolling pre-release
  [`upstream-edge`](https://github.com/mwoDevelop/android-remote-control-mcp/releases/tag/upstream-edge);
- both releases contain exactly GMS APK, FOSS APK and `release-manifest.json`, are non-draft pre-releases, and use
  signer SHA-256 `[REDACTED_RESOURCE_ID]`;
- stable signed APK SHA-256 values are `[REDACTED_RESOURCE_ID]`
  (GMS) and `[REDACTED_RESOURCE_ID]` (FOSS); edge values are
  `[REDACTED_RESOURCE_ID]` (GMS) and
  `[REDACTED_RESOURCE_ID]` (FOSS);
- the edge assets were downloaded without a GitHub token and independently revalidated. Real same-source apply runs
  for stable and edge both returned verified `NO-OP`, proving publication-layer idempotence without rebuilding or
  replacing either release;
- the remote runs exposed and fixed missing checkout remotes, missing Rust Android targets, an incorrect first secret
  upload invocation, indented `apksigner` output and the missing publisher-job upstream remote. No APK was deployed to a
  phone because pure-upstream mirror publication is intentionally separate from managed-device delivery.

## Current verified state

- `scripts/sync-build-deploy.sh build --latest-stable --variant ...` resolves the highest official stable tag and
  builds its exact commit in an isolated temporary worktree. Debug variants complete; unsigned Release variants need
  the pre-sign metadata path introduced by this plan before they can be copied and qualified.
- `scripts/sync-build-deploy.sh build --latest-edge --variant ...` uses the same path for the official moving `edge`
  tag and has the same current Release limitation.
- Channel builds deliberately contain only the official upstream source. They exclude fork-only Shizuku/admin/recovery
  extensions and `myconf/`.
- Channel build modes never deploy and never change the checked-out `main` branch.
- Existing `.github/workflows/release.yml` and `.github/workflows/edge-release.yml` publish builds of this fork's
  checked-out commit. They do not publish artifacts produced from `--latest-stable` or `--latest-edge`.
- An isolated upstream worktree does not receive the ignored owner `keystore.properties`. A Release APK built there is
  therefore unsigned and cannot pass the existing signed-APK qualification gate.
- The existing channel output uses one `manifest.json` per channel. Building several flavors/variants would overwrite
  that file, so it is not yet a safe multi-asset release contract.

## Fixed decisions and non-goals

1. GitHub publication for official-upstream artifacts must call the existing `--latest-stable` or `--latest-edge`
   path. Workflow YAML must not duplicate tag selection, source checkout or provenance logic.
2. Do not implement a free-form `--latest-develop`, `--upstream-branch` publication input or any arbitrary branch
   channel. The only source channels are stable semantic-version tags and the official `edge` tag.
3. Keep fork releases and pure-upstream mirror releases distinct. Existing fork tags/releases remain `v*` and `edge`;
   upstream mirror tags/releases use `upstream-vMAJOR.MINOR.PATCH` and `upstream-edge`. This avoids silently replacing
   the fork's custom release stream.
4. Mark every pure-upstream mirror release as a GitHub pre-release, including a stable upstream source. In this
   repository, “stable” describes the selected upstream source, not eligibility for the fork application's automatic
   updater. A mirror release must never become GitHub `/releases/latest` and must not make installed fork builds lose
   their Shizuku/admin/recovery features through an automatic update.
5. Do not expose a signing key to the checked-out upstream source or any Gradle/Make task executed from it. Build and
   test the unsigned Release APK first; sign only in a separate trusted job that executes pinned fork-owned signing
   and verification code without running upstream build scripts.
6. Never pass signing passwords as command-line arguments. GitHub secrets may be materialized only below
   `$RUNNER_TEMP`, with mode `600`, and must be deleted by an unconditional cleanup step.
7. Publication is fail-closed: no release is created or modified unless both GMS and FOSS Release APKs share the exact
   resolved source SHA, expected package ID and owner signing certificate, and all mandatory tests are qualified.
8. This plan changes release automation, fork-owned scripts/tests and documentation only. It must not modify upstream
   Android application classes or device configuration.
9. Upstream mirror builds use a secretless test profile. It excludes only the live
   `NgrokTunnelIntegrationTest`, because that test requires an account token, while retaining its compilation and all
   other tests. No production, device or owner ngrok token is exposed to upstream code; provenance records the profile.
10. The build job has read-only repository permission, no GitHub Environment, no secrets and no persisted checkout
    credentials. Only the trusted signing/publication job has `contents: write` and the protected
    `upstream-releases` Environment.
11. GitHub multi-asset updates are not atomic. Edge publication backs up the previous asset set and attempts rollback
    on failure, but reports an explicit incomplete state if restoration cannot be proven.

## Independent review applied

The separate review is recorded in
`docs/reviews/72_upstream_channel_github_releases_review_20260901.md`. Its blocking findings were accepted: unsigned
metadata is separated from signature qualification, upstream tests receive no ngrok secret, multi-variant builds are
bound by `--expected-source-sha`, signing re-derives all security metadata, cancellation and edge atomicity guarantees
are stated realistically, and the workflow permission/credential boundary is explicit.

## Target release contract

| Channel | Source selector | GitHub tag/release | Behavior |
|---|---|---|---|
| stable | `--latest-stable` → newest strict `vMAJOR.MINOR.PATCH` | `upstream-vMAJOR.MINOR.PATCH` | Immutable; publish once for a source SHA and never overwrite it |
| edge | `--latest-edge` → official `edge` tag | `upstream-edge` | Rolling pre-release; update only when the resolved upstream SHA changes |

Each release contains:

- owner-signed `gmsRelease` and `fossRelease` APKs with stable, channel-specific filenames;
- one aggregate JSON provenance manifest containing source repository, source label/SHA, variant, package/version,
  unsigned and signed SHA-256 values, certificate SHA-256, build qualification and workflow run identity;
- generated release notes that clearly identify the artifacts as pure official-upstream builds without fork features;
- no debug APK, secret file, keystore, `keystore.properties`, device configuration or raw environment dump.

## User Story 1 — Separate unsigned channel build from trusted signing

- [x] Extend the channel builder with an internal/explicit unsigned Release output mode. It must still run lint,
  detekt, unit/integration tests, E2E compilation and native payload checks before returning an unsigned APK.
- [x] Keep `build --latest-stable` and `build --latest-edge` as the public selectors. Do not introduce a second tag or
  branch resolution implementation.
- [x] Add `--expected-source-sha` as a guard, not a source selector. It is valid only together with one latest-channel
  flag, and it compares the freshly resolved channel both before and after the build.
- [x] Run channel tests without `NGROK_AUTHTOKEN`, excluding only the live ngrok integration class through a trusted
  Gradle init script. Record `upstream_mirror_secretless` and the explicit non-applicable live test in provenance.
- [x] Record a pre-sign provenance manifest using metadata readable without a certificate: source label/SHA, variant,
  application ID, version code/name, unsigned APK SHA-256 and mandatory-gate status.
- [x] Make channel manifests variant- and source-specific instead of overwriting one `manifest.json`, for example
  `manifest-gmsRelease-<short-sha>.json` and `manifest-fossRelease-<short-sha>.json`.
- [x] Add a trusted `sign-channel-artifact` operation that consumes an unsigned APK, its pre-sign manifest, an external
  keystore path and an external properties/secret file. It must not execute code from the upstream worktree.
- [x] Use `zipalign` before `apksigner`, then verify the final APK with `apksigner verify --verbose --print-certs` and
  the existing package/version/native-payload validators.
- [x] Require an expected owner certificate SHA-256 supplied as a non-secret repository variable or checked trusted
  configuration. A mismatch aborts before publication.
- [x] Confirm GMS and FOSS signed assets use the same source SHA and certificate. Preserve raw unsigned, zipaligned and
  signed digests in the aggregate manifest; store portable asset names, never build-host absolute paths.
- [x] Ensure all temporary signing files are created below a unique `$RUNNER_TEMP` directory under `umask 077`, removed
  on success/failure by both a trap and an `always()` step, and ultimately discarded with the ephemeral hosted runner
  on forced cancellation. No signing material may enter a worktree, cache or artifact.

## User Story 2 — Upstream channel publication workflow

- [x] Add one reusable workflow/job interface accepting only `stable` or `edge`; map those values internally to
  `--latest-stable` and `--latest-edge`.
- [x] Run the upstream build/test job without a GitHub environment containing signing or release secrets. Upload only
  unsigned APKs and pre-sign manifests as short-lived Actions artifacts.
- [x] Set build-job `permissions: contents: read`, use checkout with `persist-credentials: false`, validate the Gradle
  Wrapper, pin every third-party Action by commit SHA and upload an exact allowlist with `if-no-files-found: error`.
- [x] Run signing and publication in a separate trusted job after the build job succeeds. Decode the owner keystore
  below `$RUNNER_TEMP`, generate any required properties there, sign, verify and remove all temporary material.
- [x] Build both `gmsRelease` and `fossRelease` from the same resolved source SHA. Abort if the moving `edge` selector
  changes between the two builds; pin the first resolution and pass the exact SHA through the remaining jobs.
- [x] Add `workflow_dispatch` for an explicit channel run and a bounded scheduled poll for automatic discovery.
  Stable publication is a no-op when `upstream-vX.Y.Z` already exists with matching provenance. Edge publication is a
  no-op when the existing `upstream-edge` release already records the same source SHA and asset digests.
- [x] Gate publication on the exact source still being current for its channel. If upstream `edge` moves while a run is
  queued or building, skip the stale publication and let the next run publish.
- [x] Use channel-scoped concurrency. Never cancel a signing/upload operation mid-publication; apply a final freshness
  guard immediately before changing the rolling edge release.
- [x] Publish stable mirror releases immutably. A digest mismatch for an already existing stable mirror tag is an error,
  not permission to overwrite historical assets.
- [x] Update `upstream-edge` assets with `--clobber` only after all signed assets and the aggregate manifest have passed
  local verification. Back up and verify the previous assets first; on failure attempt a rollback and report an
  incomplete release if restoration cannot be proven. Do not claim atomicity.

## User Story 3 — Preserve the fork release stream

- [x] Keep the current fork `v*` stable workflow and fork `edge` rolling workflow behavior unchanged unless a separate
  migration decision explicitly replaces them.
- [x] Give upstream mirror assets and release titles an unmistakable `upstream` prefix.
- [x] Add release notes warning that mirror APKs omit fork-only administrator, Shizuku, trusted unlock/sleep and origin
  recovery extensions.
- [x] Warn that mirror APKs keep the package ID and use the fork owner's certificate: manual installation can replace a
  fork build and remove those features, while it may be signature-incompatible with official upstream binaries.
- [x] Assert the actual updater endpoint remains the official upstream repository's `/releases/latest`, so it cannot
  see releases in this fork. The mirror pre-release flag remains a mandatory second defense.
- [x] Do not deploy upstream mirror APKs to [REDACTED_DEVICE_ALIAS] or [REDACTED_DEVICE_ALIAS] as part of publication. Device promotion remains a separate,
  explicit, signer/version/config guarded action.

## User Story 4 — Verification and failure handling

- [x] Extend `scripts/tests/test-sync-build-deploy.sh` for stable/edge resolution, exact-SHA pinning, manifest
  uniqueness, unsigned-to-signed provenance, wrong-certificate rejection, missing-secret rejection and cleanup.
- [x] Add tests showing arbitrary branch/develop inputs are rejected.
- [x] Add workflow validation (`actionlint` or an equivalent pinned validator) and shell syntax checks.
- [x] Test that build jobs expose no ngrok/publishing secret and no persisted Git credential, and fail closed for extra
  assets, a tag without a release, a release without manifest and a same-SHA damaged asset set.
- [x] Exercise both channels without publication first: build unsigned GMS/FOSS Release artifacts, sign with a test
  keystore, verify package/version/certificate/native payload and compare aggregate provenance.
- [x] Perform one GitHub dry run that creates no release and prints only non-secret source labels, SHAs and artifact
  digests.
- [x] Publish one `upstream-edge` pre-release, download its assets anonymously and independently verify their digests,
  signer and manifest. Then repeat the same-source publication layer and prove it is an idempotent no-op.
- [x] Publish stable and edge mirrors only after the shared path passes local qualification. Re-running the same stable
  source must not overwrite it.
- [x] Audit tracked files, workflow logs, Actions artifacts and release assets for keystore material, passwords, tokens,
  PINs, OAuth identifiers and device configuration.
- [x] On failure before publication, leave the existing release untouched. On partial edge upload failure, restore the
  previously verified backup on a best-effort basis and fail with an explicit incomplete-state report if restoration
  cannot be proven.

## Documentation and delivery

- [x] Document the distinction between fork releases, upstream stable mirrors and upstream edge mirrors in the root
  README, including exact commands and the absence of fork-only features in mirror APKs.
- [x] Document required GitHub secrets and non-secret repository variables by name only; never record values.
- [x] Record the final tag naming, release URLs, source SHAs, APK digests and signer digest after acceptance.
- [x] Commit plan/review separately from implementation. Push workflow changes only after local tests and the no-publish
  dry run pass.

## Acceptance criteria

The work is complete when one reusable publication path builds through `--latest-stable` or `--latest-edge`; upstream
code never receives signing credentials; both GMS and FOSS Release APKs are signed and fully verified by a trusted
post-build stage; stable publication is immutable; edge publication is fresh, rolling and idempotent; mirror releases
cannot replace the fork's automatic-update release; arbitrary developer branches remain unsupported; no device is
deployed during publication; and no secret or signing material is tracked, cached, logged or uploaded.
