# Independent review of Plan 73

Scope: `docs/plans/73_local_fork_stable_edge_releases_20260901.md`, current `main` at `d219cac`, official stable
`v1.12.0` at `3777403`, official edge at `16f3971`, and the existing channel build/sign/publish/deploy scripts and
workflows. This review is intentionally separate from implementation and did not modify the plan.

## Decision

**Approve with changes.**

The central decision is correct: `stable` and `edge` must select an official upstream baseline but publish an
owner-feature-bearing local integration ref. Long-lived `release/stable` and `release/edge` branches are appropriate
for the real API split, and an isolated compatibility seam is preferable to copying privileged implementations.

Implementation and remote mutation should not start until the blocking findings below are incorporated into the
plan. In particular, `100000000 + GITHUB_RUN_NUMBER` and in-place replacement of a rolling edge asset set do not meet
the plan's own monotonicity, reproducibility and rollback claims.

## Evidence checked

- `v1.12.0` is still the newest strict official stable tag and uses Ktor `3.4.0`, MCP Kotlin SDK `0.8.3`, and the
  sessionful project-owned `McpStreamableHttpExtension`.
- Official edge `16f3971` uses Ktor `3.5.2`, MCP Kotlin SDK `0.15.0`, and `McpStatelessTransport`; it is 41 commits
  ahead of stable and contains stable as an ancestor.
- Current local `main` contains 57 commits after official edge, including the Shizuku administrator, authenticated
  client context, OAuth restoration, trusted unlock, remote sleep, tunnel/origin recovery, owner deployment tooling
  and the 500 MB default storage change.
- Current `sync-build-deploy.sh build --latest-*` checks out the detached official SHA and emits the
  `upstream_mirror_secretless` profile. Its `deploy` path accepts only a matching local `qualified_build` manifest
  under `build/deployments`; it cannot directly validate and install a downloaded channel release manifest.
- Current Git-derived codes are around 20 million. The proposed release namespace starts at 100 million, while an
  ordinary later owner build would still derive a code around 20 million and therefore be refused as a downgrade.
- Existing rolling publisher replaces several GitHub Release assets sequentially with `--clobber`; GitHub does not
  provide an atomic multi-asset replacement, and replacing assets does not by itself retarget the release's Git tag.

## Blocking findings

### B1 — `GITHUB_RUN_NUMBER` is not the required global, deterministic release allocator

Severity: **blocker**

`GITHUB_RUN_NUMBER` is scoped to one workflow definition, remains unchanged on a re-run, can be reset by workflow
replacement, and is allocated before a run succeeds. Publication completion order is not guaranteed to follow run
number order. It therefore is neither a durable repository-wide allocator nor a deterministic property of a local
integration SHA. Two attempts of the same source can also produce different bytes under the same code, or reuse the
same code after a failed partial publication.

Moving release builds to `100000000 + run_number` also strands every normal owner build on the existing approximately
20-million Git-count scheme. After the first channel release is installed, the current local build/deploy workflow
cannot update the device without an explicit downgrade or another override.

Required change:

- use one persisted, repository-visible allocation for every installable owner APK across both channels, with an
  atomic uniqueness check and an explicit Android maximum bound;
- bind the allocated code immutably to the channel, upstream SHA, local SHA and release tag before publication;
- make a repeated build of that release identity reuse the same allocation, while a repaired release receives a new
  identity and a greater code;
- pass the same explicit code to GMS and FOSS and assert it in both manifests/APKs;
- update ordinary owner Release builds to use the same namespace, or give non-release development builds a separate
  application ID so they cannot become accidental downgrade candidates;
- require `candidate > installed` for a different APK; equality is only an exact-hash no-op.

A small monotonic allocation ref/tag or a committed release ledger updated with compare-and-swap is preferable to a
workflow-local counter. Gaps left by failed allocations are acceptable; reuse is not.

### B2 — A mutable `arcp-edge` release cannot provide atomicity, immutable provenance or reliable rollback

Severity: **blocker**

The proposed rolling edge release inherits the existing non-atomic update problem. Uploading GMS, FOSS and a manifest
with `--clobber` exposes mixed old/new asset sets during the update and can be interrupted before best-effort rollback.
In addition, the current publisher never moves an already-created tag when it replaces release assets. A future
implementation that force-moves it introduces another race and makes a previously downloaded tag non-reproducible.

Required change:

- publish each edge bundle under an immutable namespaced tag, for example
  `arcp-edge-<upstream-short-sha>-<local-short-sha>-vc<code>`;
- create and fully validate the new release without modifying the last known-good release;
- optionally maintain `arcp-edge` only as a convenience pointer/index after the immutable release is complete; it
  must not be the provenance identity used for installation;
- make stable releases immutable under the same principle and verify an existing tag target plus complete asset set
  before treating publication as a no-op;
- if a rolling alias is retained, update it only after immutable publication and treat alias-update failure as a
  discoverability issue, not as damage to the valid release.

This removes the need to claim atomic rollback for an API that cannot supply it and preserves a usable old edge
release throughout a failed publication.

### B3 — The plan has no implementable released-APK download/deploy trust path

Severity: **blocker**

Phase 5 requires independent download verification and installation, but the current deploy command accepts only a
local build manifest whose `apk` field is an absolute local path. Passing a GitHub release APK either fails the
qualified-manifest lookup or encourages bypassing the established deployment guard.

Required change:

- add a dedicated `download-release`/`verify-release`/`deploy-release` path, or extend deploy with an explicit release
  manifest argument without weakening local-build validation;
- download by immutable release tag into a fresh `mktemp -d` directory, use an exact asset allowlist, and reject
  symlinks, path traversal, duplicate variants, extra files and manifest/asset disagreement;
- obtain the release/tag metadata independently from GitHub and verify repository, immutable tag target, upstream and
  local SHAs, allocated code, package ID, version name, APK digest, single owner signer, native payload and all
  qualification gates;
- re-check the remote immutable tag/manifest identity after download to close the freshness window;
- archive or identify the last known-good released APK and manifest before installation so device rollback uses a
  previously verified release, not an unrelated local build;
- preserve application data and config; never uninstall or clear data during promotion or rollback.

### B4 — Stable completeness is described as "selected owner commits" without a closed feature/patch contract

Severity: **blocker**

The stable incompatibility is wider than one transport filename. The local behavior spans transport dispatch,
authentication pipeline ordering, OAuth validation and caller classification, logged tool registration, ADB schema,
service/tunnel recovery, DI, privileged tool policy, manifests, native payloads and build tooling. A compile-only port
can silently omit a security restriction or expose a privileged tool to the wrong client class.

Required change:

- create a machine-readable owner patch/feature ledger that classifies every local runtime/build change as common,
  stable adapter, edge adapter, intentionally excluded documentation/config, or superseded;
- define a closed parity contract for required owner capabilities: expected tool schema, privileged authorization
  matrix, OAuth/static-bearer classification, protected-package rules, unlock/sleep policy, recovery behavior, 500 MB
  default, owner UI/manifest, and native tunnel payload;
- make both branches pass those same behavior tests, with only transport/session mechanics varying;
- test stable with real session lifecycle behavior as well as OAuth and static bearer calls. Do not infer compatibility
  from successful assembly or from an edge test suite compiled against MCP SDK 0.15;
- record any deliberate stable omission in the signed manifest and release notes; an omission of a required security
  or authorization behavior must fail the release.

## High-severity findings

### H1 — Cherry-pick-only sharing will accumulate duplicate patch histories and integration drift

Severity: **high**

`cherry-pick -x` provides traceability but gives equivalent shared fixes different commit identities and makes future
upstream merges rediscover the same conflicts twice. The plan also does not name the canonical source of a shared fix.

Recommendation:

- define one canonical owner change flow and a required promotion direction;
- prefer authoring common owner code in isolated owner modules/packages on a shared lineage, then merge that lineage
  into both integration branches; use `cherry-pick -x` only where the divergent upstream ancestry makes a merge
  impractical;
- maintain a patch ledger using origin commit, patch-id, dependencies and both resulting branch SHAs; CI should fail
  if a required common patch exists in only one channel;
- keep stable/edge-specific adapters as small terminal commits and prohibit copying whole upstream transport/auth
  classes into owner packages.

The current history supports this design: stable is an ancestor of edge, so common modules can be ported once while
the MCP/Ktor binding remains channel-specific.

### H2 — The branch-refresh procedure and meaning of `--latest-*` are incomplete

Severity: **high**

The builder correctly should not merge implicitly, but then `--latest-edge` and `--latest-stable` are freshness
assertions, not branch updaters. The plan provides no explicit procedure for advancing integration refs after an
official tag moves, nor for promoting a new common local change from `main`.

Recommendation:

- add a separate non-publishing `prepare-channel-update stable|edge` flow that resolves official and owner refs,
  creates a review branch/PR, runs compatibility tests, and never updates `release/*` directly;
- protect `release/*`, require reviewed fast-forward/merge updates, and let release selectors only build the exact
  remote integration ref after freshness proof;
- resolve `refs/remotes/origin/release/{stable,edge}`, verify the origin URL/repository and require local/remote SHA
  equality; do not trust a spoofable local branch of the same name;
- specify what happens when upstream stable advances: merge/port the new stable baseline, refresh the patch ledger,
  then qualify before moving `release/stable`.

### H3 — A live ngrok secret in a Gradle/build job weakens the intended signing boundary

Severity: **high**

Even though release refs are owner-controlled, Gradle plugins, tests, Makefiles and integration-branch code execute in
the build job. Supplying an account credential lets any compromised dependency or mistakenly merged test exfiltrate
it. Calling the code "trusted" is not a technical secret boundary.

Recommendation:

- keep compilation/unit/integration artifact production secretless;
- move live network/account validation to a separate protected environment after the unsigned APK and source
  provenance pass static qualification, using a dedicated least-privilege, revocable test credential;
- if the live ngrok test cannot be separated immediately, require environment approval, restrict branch/ref access,
  use a dedicated non-device credential, never expose signing/publication credentials, and record the exception in
  provenance;
- signing/publishing must execute only tooling from the trusted workflow commit, never scripts or binaries obtained
  from the integration artifact bundle.

### H4 — Freshness checks need one global publisher lock and remote compare checks

Severity: **high**

Per-channel concurrency is insufficient for a shared version allocator and convenience alias. A local `git rev-parse`
immediately before publication is not authoritative when another actor can move a remote ref.

Recommendation:

- use one non-cancelling concurrency group for all ARCP allocations/publications across stable and edge;
- query the GitHub refs API immediately before immutable tag creation and verify official upstream plus remote local
  integration SHA against the signed manifest;
- protect release branches/tags with rulesets and ensure exactly one workflow has tag/release write permission;
- create immutable tags without force and treat "already exists with different target" as fatal;
- rerun freshness verification after protected-environment approval, because approval can introduce a long delay.

### H5 — Security backports need an explicit stable policy

Severity: **high**

Edge contains later dependency and security changes, including the Netty tooling force. A local stable release based
strictly on `v1.12.0` may remain exposed to issues already fixed upstream edge. Conversely, blindly upgrading Ktor/MCP
SDK would erase the compatibility distinction.

Recommendation:

- define stable as "latest official stable functional baseline plus reviewed security/build backports" or explicitly
  document why a backport is not applicable;
- inventory edge commits since the stable tag for security, build-tool and native dependency fixes independently of
  feature/API upgrades;
- record every backport and dependency/submodule SHA in provenance and rerun the stable compatibility suite.

## Medium-severity findings

### M1 — Release identity and asset naming need the allocation and full provenance

Severity: **medium**

Short SHAs are useful labels but should not be the only collision boundary. Asset names that omit version code make
downloads and retained local evidence ambiguous.

Recommendation: use immutable tags/assets containing channel, upstream label or short SHA, local short SHA, allocated
code and flavor; retain full 40-character SHAs and submodule gitlink SHAs in the signed manifest. The manifest, not a
rolling alias, is the canonical identity.

### M2 — GMS/FOSS and source-tree equivalence need explicit guards

Severity: **medium**

Recommendation: create one clean isolated worktree per release identity, initialize exact submodules once, and build
both variants before destroying it. Assert identical local/upstream SHAs, version name/code, package ID and feature
contract in both outputs. Fail on a dirty top-level tree, dirty submodule, untracked generated signing configuration or
unexpected gitlink. Do not resolve the channel separately for the second variant.

### M3 — Device rollback and remote publication rollback are different operations

Severity: **medium**

Recommendation: describe them separately. Immutable publication makes remote rollback an alias/index change or no-op;
device rollback uses a previously downloaded and verified owner-signed GMS APK with `adb install -r -d`, preserves
data, and is allowed only from a recorded deployment manifest. A rollback should be tested before it is relied on, but
must not be triggered merely because a non-destructive post-install assertion is temporarily unavailable.

### M4 — "remote debugging disabled" is ambiguous during ADB deployment

Severity: **medium**

Recommendation: distinguish Android **Wireless debugging** from USB debugging and from the ARCP tunnel. Wireless
debugging must remain off. USB ADB may be used temporarily for the update and local metadata capture; final Cloudflare,
MCP, sleep/wake/unlock and ChatGPT/Codex regression must run after removing ADB forwarding/disconnecting the host so
success cannot be attributed to a development channel.

### M5 — End-to-end acceptance should cover actual remote consumers

Severity: **medium**

Recommendation: in addition to raw MCP initialize/tools/list, run representative ordinary and privileged calls through
Cloudflare using both the configured Codex MCP client and the ChatGPT connector when its schema is affected. Verify
unauthenticated denial, ordinary-client denial of privileged tools, administrator authorization, screen-off recovery,
and tunnel/service restart recovery. Any manual biometric/PIN gate remains manual and must be reported, not bypassed.

## Required plan amendments before implementation

1. Replace `GITHUB_RUN_NUMBER` with a persisted global allocation shared by every installable owner build and define
   equality/no-op plus downgrade rules.
2. Replace mutable edge assets as the canonical release with an immutable edge release identity; retain `arcp-edge`
   only as an optional post-publication alias/index.
3. Add a first-class released-artifact download, verification, deployment and known-good rollback path.
4. Add the owner patch/feature ledger and stable behavioral compatibility matrix before creating `release/stable`.
5. Define the canonical shared-change promotion flow and the separate reviewed integration-branch refresh procedure.
6. Move live credential testing behind a protected least-privilege boundary and use one global publication lock with
   authoritative remote freshness checks.
7. Add stable security-backport review, exact submodule provenance, GMS/FOSS equivalence and real remote-consumer E2E.
8. Clarify that final remote tests run without Wireless debugging, ADB forwarding or an active host dependency.

After these changes, the plan is coherent enough to implement iteratively. The first remote release should be the
qualified immutable edge build, because current `main` is already an edge integration. Stable publication should wait
until its independent compatibility port and full owner feature contract pass; a successful assembly alone is not
sufficient.
