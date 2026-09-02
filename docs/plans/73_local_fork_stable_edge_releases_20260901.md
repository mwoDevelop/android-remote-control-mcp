<!-- COMPLETE — independently reviewed, implemented, released and qualified on [REDACTED_DEVICE_ALIAS]. -->
<!-- Never commit keystores, passwords, tokens, PINs, OAuth credentials, generated secret properties or device dumps. -->

# Plan 73 — Local-fork stable and edge release channels

Replace the misleading pure-upstream meaning of `--latest-stable` and `--latest-edge`. A channel selector chooses the
official upstream baseline, but every produced APK must come from a reviewed local integration ref and retain the
fork-only Shizuku administrator, trusted unlock, remote sleep, tunnel/origin recovery and owner configuration support.

## Current problem and verified baseline

- `--latest-stable` currently builds detached official tag `v1.12.0` (`3777403`) and `--latest-edge` builds detached
  official edge commit `16f3971`; both omit every local application extension.
- Current local `main` is based on the edge commit and contains the owner extensions. It is therefore the starting
  point for the edge integration, not a valid stable integration.
- Stable uses Ktor `3.4.0`, MCP SDK `0.8.3` and `McpStreamableHttpExtension`; edge uses Ktor `3.5.2`, MCP SDK `0.15.0`
  and `McpStatelessTransport`.
- A three-way application probe of the local runtime delta onto `v1.12.0` failed at the transport and conflicted in
  bearer authentication and ADB configuration. Stable requires an explicit compatibility port, not relabelling edge.
- Existing `upstream-v*` and `upstream-edge` releases are historical pure-upstream mirrors. They must never be used for
  managed-device delivery and will not be overwritten or deleted by this plan.

## Fixed branch, tag and artifact model

1. `main` remains the development branch for the newest reviewed local code.
2. `release/edge` is the reviewed local edge integration. Initially it points at the qualified `main` commit and may
   advance only when it contains the freshly resolved official edge SHA.
3. `release/stable` is based on the freshly resolved strict upstream stable tag and contains selected owner commits
   plus stable-only compatibility code. It must not contain the official edge commit.
4. Common owner code has one canonical source on `main` in isolated owner modules/packages. It is promoted to
   `release/edge` by reviewed fast-forward/merge and to `release/stable` by a recorded merge when histories permit or
   `cherry-pick -x` only when the upstream split makes a merge impractical. Edge-only and stable-only compatibility
   commits remain terminal commits on their respective branches.
5. One selector builds one APK per requested flavor. Running both selectors produces two alternative app versions,
   not two side-by-side installations: release APKs retain the same application ID and owner signing certificate.
6. New release tags are namespaced away from official-upstream and legacy fork tags:
   - stable: immutable `arcp-stable-<upstream-label>-<local-short-sha>-vc<code>`;
   - edge: immutable `arcp-edge-<upstream-short-sha>-<local-short-sha>-vc<code>` pre-release.
   An optional `arcp-edge` pointer/index may be updated only after the immutable release is complete; it is never the
   provenance identity used for download, verification or installation and carries no canonical replaceable bundle.
7. Release asset names start with `android-remote-control-mcp-arcp-`. Release notes and manifests explicitly say that
   owner extensions are included and identify both upstream and local SHAs.

## Compatibility/OCP design

- Keep privileged implementations in the owner `shizuku-admin` module and owner packages. Do not duplicate those
  implementations between branches.
- Isolate transport-specific request-context plumbing behind one small owner compatibility seam:
  - edge adapter wraps `McpStatelessTransport` and the Ktor 3.5/MCP SDK 0.15 pipeline;
  - stable adapter wraps the legacy `McpStreamableHttpExtension` request dispatch and Ktor 3.4/MCP SDK 0.8 pipeline.
- Keep the authentication classification contract common (`McpAuthClientClass`, verified OAuth client ID and coroutine
  context). Each branch supplies only the transport/pipeline binding appropriate to its upstream API.
- Port ADB/OAuth configuration by behavior and tests, not by blindly copying edge source. Stable preserves its own
  upstream schema while accepting the owner-only OAuth client restoration and unlock provisioning fields.
- Add `config/arcp-channel-features.json`, a machine-readable closed feature/patch ledger. Every local runtime/build
  change records its canonical owner commit or patch-id, dependencies, stable/edge integration SHA, classification
  (`common`, `stable_adapter`, `edge_adapter`, `excluded_non_runtime` or `superseded`) and required tests.
- The required parity contract covers tool schemas, ordinary/privileged authorization matrix, OAuth/static bearer
  classification, protected packages, unlock/sleep policy, service/tunnel/origin recovery, 500 MB default, owner UI
  and manifest declarations, native tunnel payload and application/signing identity. A missing required capability is
  a release failure, not an undocumented stable exception.
- Existing unavoidable integration edits to upstream files must be minimal, documented and covered by tests. New
  branch-specific behavior belongs in owner files/adapters so future upstream merges replace adapters rather than
  forking complete upstream classes.

## Build and provenance contract

- `scripts/sync-build-deploy.sh build --latest-stable` resolves official stable, then builds the exact reviewed
  `release/stable` commit in an isolated worktree after proving that the official stable SHA is its ancestor and the
  official edge SHA is not.
- `scripts/sync-build-deploy.sh build --latest-edge` resolves official edge, then builds the exact reviewed
  `release/edge` commit after proving that the official edge SHA is its ancestor.
- Channel resolution is fail-closed and records: channel, upstream repository/label/SHA, local repository/ref/SHA,
  variant, application ID, version name/code, hashes, signer state and qualification gates.
- The builder never merges, rebases or updates a release branch implicitly. A missing, stale, dirty, ambiguous or
  unpushed integration ref is an error with an actionable message.
- Compilation, static analysis, unit/integration tests and unsigned artifact production remain secretless. A separate
  protected, least-privilege live-test job receives only a dedicated revocable ngrok test credential after source and
  unsigned artifacts pass static qualification. Signing/publication secrets are never available to that job. The old
  `upstream_mirror_secretless` profile is not valid provenance for an ARCP release.
- The protected signing job signs only APKs built from an exact integration SHA already present in the repository.
  It receives the owner keystore only after build/test succeeds, and signing material remains outside every worktree.
- Release builds pass an explicit version name containing channel, upstream label and local short SHA.
- Release `versionCode` comes from a repository-visible append-only ledger on a dedicated protected
  `release/version-ledger` ref. One non-cancelling global publication lock performs compare-and-swap allocation. An
  entry binds an immutable release identity to channel, upstream SHA, local SHA, release tag and code; retrying that
  identity reuses its code, while a repaired identity allocates a greater code. Gaps are allowed, reuse is forbidden,
  and Android's maximum is checked.
- Both GMS and FOSS receive the same explicit allocated code. Every installable owner Release build, including legacy
  local/fork release paths, must use this ledger; release Gradle tasks fail without an explicit ledger-backed code.
  Debug builds retain their suffixed application IDs and cannot become update/downgrade candidates.

## GitHub workflow and release behavior

- Add/replace one manual/scheduled ARCP channel workflow with inputs `stable|edge` and `publish`.
- The workflow first resolves both upstream and local SHAs, then builds GMS and FOSS from the same local worktree and
  exact explicit version metadata.
- The build job may receive only the live test secret required by trusted owner tests. Signing and publication secrets
  remain restricted to the protected release environment/job.
- Stable and edge publication are immutable per full release identity. The workflow checks for an existing complete
  matching remote manifest before rebuilding; a matching identity is a no-op and any tag/target/asset mismatch is
  fatal. No canonical APK asset is replaced with `--clobber`.
- One global non-cancelling publisher lock covers both allocation and publication. Immediately after any protected
  environment approval and again before tag creation, query GitHub and official-upstream APIs for the authoritative
  remote integration/upstream SHAs. Immutable tags are created without force.
- A failed immutable publication leaves the previous release untouched. Optional alias/index update happens last;
  its failure is a discoverability error and never corrupts the valid immutable release.
- Disable scheduled publication of the misleading pure-upstream mirror workflow. Keep its scripts/releases only for
  historical verification until a later explicit cleanup.
- Do not let the legacy `edge-release.yml` also mutate an ARCP channel tag. There must be exactly one writer for
  `arcp-edge`.

## Stable security and refresh policy

- Stable means the latest official stable functional baseline plus reviewed security/build/native backports that do
  not replace its Ktor/MCP transport generation. Inventory every official edge commit since the stable tag as
  `backport`, `not_applicable`, `already_present` or `deferred_with_reason` in the feature/patch ledger.
- Add a non-publishing `prepare-channel-update stable|edge` command. It fetches authoritative refs, creates a review
  branch, updates the patch ledger and runs the channel compatibility suite; it never moves `release/*` or publishes.
- Release selectors resolve only `refs/remotes/origin/release/{stable,edge}`, verify the origin repository URL and
  require local/remote SHA equality. Missing protection, stale baseline or an unexpected merge ancestry fails closed.
- Protect both integration branches and the version-ledger/tag namespaces. Upstream advancement is integrated on a
  review branch and reaches a release ref only after the full channel behavior suite passes.

## Released-artifact trust and device rollback contract

- Add explicit `download-release`, `verify-release` and `deploy-release` operations; do not weaken the existing local
  `qualified_build` deployment path.
- Download only by immutable tag into a fresh temporary directory. Enforce an exact regular-file allowlist and reject
  links, duplicate variants, traversal, extra files and manifest disagreement.
- Independently verify repository/tag target, full upstream/local/submodule SHAs, version-ledger binding, package,
  version, digest, exactly one owner signer, native payload, feature-contract hash and mandatory gates, then re-query
  the remote identity after download.
- Before installation, preserve the previously deployed immutable release manifest/APK identity as last-known-good.
  Device rollback is distinct from publication handling: it may use `adb install -r -d` only with that previously
  verified owner release and never uninstalls or clears data.
- Candidate code must be greater than the installed code unless package/version/hash are an exact no-op. Equal code
  with different bytes and every unintended downgrade are rejected.

## Implementation sequence

### Phase 1 — Plan and independent review

- [x] Record the branch/tag/channel/version/provenance decisions in this plan.
- [x] Obtain a separate independent review focused on Git topology, stable compatibility, release races, secrets,
  reproducibility, downgrade protection and rollback.
- [x] Apply accepted findings here before changing production scripts or branches.

Independent review: `docs/reviews/73_local_fork_stable_edge_releases_review_20260901.md` — decision
`approve-with-changes`. All four blocking findings and the applicable high/medium findings are incorporated above:
persisted global version ledger, immutable edge identities, first-class released-APK trust/deploy path, closed feature
ledger/parity tests, canonical common-code flow, explicit refresh workflow, protected live credential test, global
publisher lock, security backport inventory, exact submodule provenance and host-independent final E2E.

### Phase 2 — Channel resolver and contract tests on `main`

- [x] Change `--latest-stable` / `--latest-edge` from official detached-source builds to reviewed local integration
  builds while retaining official baseline resolution.
- [x] Add exact local-ref/SHA guards and explicit version-name/version-code inputs for release builds.
- [x] Replace upstream-only manifest fields/profile/names with dual upstream/local ARCP provenance.
- [x] Add protected append-only version-ledger allocation/lookup and require its explicit code for every installable
  owner Release build.
- [x] Add `download-release`, `verify-release` and `deploy-release` with immutable-tag and known-good rollback checks.
- [x] Add contract tests for correct refs, stale/missing branches, stable containing edge, upstream drift, local-ref
  drift, dirty tree, ledger races/retries/max/equality, immutable identity, release asset attacks, secret boundaries and
  one-selector/one-artifact behavior.

### Phase 3 — Create and qualify both integration branches

- [x] Create `release/edge` from the qualified local `main` commit.
- [x] Create `release/stable` from official stable `v1.12.0` and port the final owner runtime/build delta without the
  intervening upstream edge commits.
- [x] Create and validate the machine-readable owner patch/feature ledger, closed capability parity matrix and stable
  security/backport inventory before declaring the stable branch complete.
- [x] Implement stable transport/auth/ADB compatibility adapters and keep branch-specific changes narrow.
- [x] Run formatting, static analysis, unit/integration tests, E2E compilation and signed GMS/FOSS build qualification
  independently on both branches.
- [x] Push branches only after local qualification and audit their tracked files for secrets/signing material.

### Phase 4 — ARCP release workflow

- [x] Add trusted signing and publisher support for ARCP dual-source manifests, exact submodule provenance and
  immutable namespaced tags/assets.
- [x] Update the GitHub workflow, repository variables/environment and activation guard without exposing secrets.
- [x] Preserve exact allowlists, independent signer/package/native-payload verification, immutable stable/edge
  releases, authoritative freshness and optional post-publication alias handling.
- [x] Validate shell syntax, actionlint and all release contract tests. Run a no-mutation dry run for both channels.

### Phase 5 — Remote release, download and [REDACTED_DEVICE_ALIAS] promotion

- [x] Commit and push the reviewed automation changes to `main`; wait for required GitHub CI checks.
- [x] Publish qualified `arcp-edge` from `release/edge`; qualify stable through the non-publishing workflow before a
  future stable promotion.
- [x] Download the GMS release APK and manifest from GitHub into a fresh directory, without reusing the local build.
- [x] Independently verify release tag/ref, upstream/local/submodule SHAs, version-ledger binding, hashes, package ID,
  version name/code, certificate, feature contract, native payload and absence of extra assets.
- [x] Resolve [REDACTED_DEVICE_ALIAS] unambiguously. Use an explicit configured ADB serial when ADB is available; otherwise use the
  authenticated device-side download and Android Package Installer path, never a different attached device.
- [x] Before install, record package/version/signer, MCP config availability and service state. Refuse downgrade,
  signature mismatch, package mismatch or a build whose manifest skipped mandatory gates.
- [x] Install the downloaded owner-signed GMS APK as an update without uninstalling or clearing application data.
- [x] Confirm installed version/signer/config preservation, restart/start ARCP only as needed, then test loopback-only
  listener, Cloudflare health/auth, MCP initialize/tools/list and representative basic plus privileged tools.
- [x] Remove every ADB forward and disconnect the host after installation. Exercise Cloudflare/Codex/ChatGPT plus
  screen-off sleep/wake/unlock regression with Android Wireless debugging disabled; temporary USB ADB used for install
  must not be the path that makes final tests succeed. Do not bypass manual PIN/biometric policy.

### Phase 6 — Failure loop and closure

- [x] On any deterministic failure, stop publication/deployment, diagnose, add a regression test, make the smallest
  fix on the appropriate common or compatibility branch, then repeat build → qualification → release → independent
  download verification → [REDACTED_DEVICE_ALIAS] install → post-install tests.
- [x] Do not overwrite an immutable stable or edge release to repair it; publish a new identity with a greater ledger
  code. A failed optional alias update does not invalidate the immutable release.
- [x] Update README/channel documentation, mark historical pure-upstream releases as non-device artifacts, record
  final branch/tag/run/APK/device evidence here, audit tracked files for secrets, commit and push final documentation.

## Implementation and rollout evidence

- Official baselines: stable `v1.12.0` at `3777403`; edge at `16f39717ce0969aa81a4ec132ba1cad861ba46cc`.
  Published integration refs are `release/stable` at `[REDACTED_RESOURCE_ID]` and
  `release/edge` at `[REDACTED_RESOURCE_ID]`. The shared ledger ref is
  `[REDACTED_RESOURCE_ID]`.
- Release automation landed through `d350c16`, followed by fail-closed fixes `906d24d`, `1f8fc46`, `3caaf06` and
  `07e5946`. Each deterministic release-path failure received a regression test before the cycle was repeated.
  `9b6afd1` disabled automatic execution of the mutable legacy edge publisher and added a contract guard.
- Local contract suites passed: sync/build/deploy `33/33`, version ledger `6/6`, release/sign/publish `8/8`.
  Stable and edge non-publishing workflow qualification passed, including stable run `33565947690`. Main CI run
  `33605437408` passed lint/actionlint/release contracts, unit/integration tests, emulator E2E and both GMS/FOSS
  builds. Only the manual immutable `ARCP channel release` workflow is the active publication authority.
- Two immutable edge identities were created during the repair loop. The retained final release is
  `arcp-edge-16f39717ce09-07e5946270d8-vc21000001`, created by run `33573018363`, targeting the exact edge integration
  SHA with ledger code `21000001`. Its exact asset set is one signed GMS APK, one signed FOSS APK and
  `release-manifest.json`; a fresh download passed the independent release verifier. The earlier immutable identity
  remains untouched as audit and rollback evidence.
- The final GMS release was downloaded on [REDACTED_DEVICE_ALIAS] through authenticated ARCP storage and installed by Android's system
  Package Installer as an update to the existing package. No uninstall or data clear occurred. Post-install MCP and
  health report `com.danielealbano.androidremotecontrolmcp`, `arcp.edge.edge.07e5946270d8.r1`, code `21000001`.
  Existing Cloudflare/OAuth configuration survived; public health stayed `healthy`, and unauthenticated `/mcp`
  remained `401`.
- Codex exercised application listing, storage listing, screen state, remote sleep and trusted remote unlock. The
  Cloudflare tunnel stayed healthy while the screen was off and unlock returned `unlocked`. LAN ports `8080` and
  `5555` were closed. [REDACTED_DEVICE_ALIAS] was absent from host ADB; the only attached ADB target identified itself as `SM-S901E`, so
  neither it nor an ambiguous serial was used for the install or final tests.
- The first ChatGPT attempt exposed stale connector state after the update and reported a transient 502 while the
  endpoint itself remained healthy. Refreshing the installed `[REDACTED_DEVICE_ALIAS]` plugin through CDP 9222 restored its tool set.
  A new project chat then returned the exact package, version name and version code above via the plugin with no
  device mutation.
- Tracked-file audit found no `.env.secrets`, keystore, signing properties or `local.properties`; device secret files
  remain ignored. The temporary APK was no longer present in ARCP-owned Downloads after installation.

## Acceptance criteria

The work is complete only when both local integration refs are explicit and reproducible; both selectors build owner
feature-bearing APKs associated with their official upstream baseline; stable incompatibilities, parity and security
backports are isolated and tested; one GitHub workflow publishes immutable namespaced ARCP releases with a persisted
global monotonic version ledger; an independently downloaded released GMS APK passes the first-class trust path and is
installed on [REDACTED_DEVICE_ALIAS] without data reset; Cloudflare/Codex/ChatGPT/basic/privileged and screen-off regression tests pass
without Wireless debugging, ADB forwarding or host dependency; no tracked/released asset contains a secret or signing
file; and all final commits, protected refs and release evidence required for reproduction are pushed.
