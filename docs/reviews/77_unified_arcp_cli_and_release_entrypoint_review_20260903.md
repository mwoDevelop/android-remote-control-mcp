# Independent review of Plan 77

Scope: `docs/plans/77_unified_arcp_cli_and_release_entrypoint_20260903.md`, current local `main` at `085af0d`,
`origin/main` at `8491bea`, official `upstream/main` at `16f3971`, the current owner channel refs, release workflow,
builder, ledger, publisher and shell contract suites. This review is independent from implementation and modifies no
production file.

## Decision

**Approve with changes.**

One routine CLI and one enabled publication workflow are the correct target. Keeping the low-level scripts as focused
implementation units, disabling inherited workflows through GitHub state rather than editing their content, and making
publication an explicit opt-in all improve operability without duplicating security boundaries.

Implementation and remote workflow-state mutation should not start until the four blocking findings below are applied
to the plan. As written, the CLI can follow the correct run while that run builds a different moving channel source,
cannot produce the promised exact run URL under `--no-wait`, advertises channel Release builds that normally fail in
the isolated worktree, and can report a successful `--publish` request that only performed a dry-run.

## Evidence checked

- `.github/workflows/arcp-channel-release.yml` is fork-only, manual, globally non-cancelling, and separates secretless
  build, protected live test and protected signing/publishing jobs. Its current inputs are `channel`, `revision` and
  `publish`; neither expected source SHA nor a request ID is currently bound to the dispatch.
- `scripts/sync-build-deploy.sh` resolves the official moving channel and `origin/release/<channel>` independently at
  execution time, checks both again after a build, and builds the owner ref in an isolated worktree.
- A normal channel `gmsRelease`/`fossRelease` build is treated as signed by the wrapper unless
  `--unsigned-release` is supplied. The isolated channel worktree does not receive ignored `keystore.properties`,
  while `--unsigned-release` itself requires explicit ledger-backed version metadata. Therefore the proposed uniform
  four-variant public channel contract is not currently real.
- In the workflow, `publish=true` allocates the ledger entry before qualification. `publish=false` previews the
  allocation and does not update the remote ledger. Gaps after a failed publishing run are already an accepted ledger
  property.
- The final job currently calls the non-mutating publisher whenever either the `publish` input or
  `ENABLE_ARCP_RELEASE_PUBLISHING` is not true; that branch exits successfully.
- GitHub currently reports four active workflows by path: `ci.yml`, `arcp-channel-release.yml`, `edge-release.yml` and
  `release.yml`. The latter two are known legacy publishers, but their enabled state is repository metadata rather
  than a Git-tracked invariant.
- The files added by this design (`scripts/arcp`, its test, Plan 77 and this review) can remain fork-only. The root
  `README.md` and `.github/workflows/ci.yml` already contain owner deltas from upstream, so further edits there should
  be kept to narrow owner-delimited additions.

## Blocking findings

### B1 — Exact run correlation does not freeze the source approved by the caller

Severity: **blocker**

The plan preflights `channel-info`, then dispatches only a channel name. A queued run can begin after the official
`edge` tag, newest stable tag, or `origin/release/<channel>` has moved. The request ID would still identify the correct
workflow run, but that run could build source different from the source observed and approved by the CLI. The global
concurrency group prevents publication overlap; it does not freeze refs while a run is queued or awaiting an
environment gate.

Required change:

- resolve `upstream_sha`, `upstream_label` and `local_sha` after an authoritative fetch in the CLI and pass at least
  both full SHAs as workflow inputs;
- call `channel-info --expected-source-sha ... --expected-local-sha ...` in the workflow so movement fails closed
  instead of silently changing the release identity;
- bind the requested full SHAs to the run summary and generated evidence; do not rely on short SHAs or the request ID
  as provenance;
- define manual UI dispatch explicitly: either blank expected-SHA inputs mean “resolve latest when the run starts”, or
  require the SHAs for every dispatch. Do not present manual-latest and CLI-pinned requests as equivalent;
- test a queued/mocked ref movement between CLI preflight and workflow resolve.

### B2 — `--no-wait` and resumable status are internally inconsistent

Severity: **blocker**

`workflow_dispatch` returns no Actions run ID. An exact run URL exists only after GitHub registers the run and the CLI
discovers its numeric ID. The plan nevertheless says that `--no-wait` prints a deterministic Actions URL, while
`release status` accepts no request/run ID with which to resume the exact invocation. Listing the newest run or a
generic workflow URL would reintroduce the race the request ID is intended to remove.

Required change:

- define `--no-wait` as “dispatch, perform bounded registration discovery, print exact run ID/URL/request ID, then do
  not watch completion”; it must still fail on registration timeout or ambiguous matches;
- add a resumable selector, for example
  `scripts/arcp release status --request-id <id> [--watch]` (or a separate `release watch <id>`), and retain a plain
  recent-run listing only as a distinct informational mode;
- match repository, workflow path/ID, event, exact request ID, target branch and workflow source SHA; fail if zero or
  more than one run matches;
- bound and document discovery/watch timeouts, propagate terminal failure/cancellation/timeout/action-required states,
  and print machine-usable `request_id`, `run_id` and `url` fields.

### B3 — The public build source/variant matrix promises channel Release builds the backend cannot safely provide

Severity: **blocker**

The proposed syntax allows every variant for `local`, `stable` and `edge`, but a channel Release build without
`--unsigned-release` is validated as signed. Its isolated worktree does not contain the ignored owner signing config,
so this normally fails signer inspection. Mapping it to `--unsigned-release` is not a transparent fix because that mode
requires ledger-backed `versionCode`/`versionName` and intentionally emits a pre-sign bundle, not an installable APK.
The plan would hide this because it tests stable/edge delegation only with mocks and explicitly skips a real build.

Required change:

- publish an explicit source/variant contract. Recommended: routine `scripts/arcp build stable|edge` defaults to
  `gmsDebug` and permits only debug variants; signed channel Release artifacts are produced only by
  `scripts/arcp release`;
- keep the ledger-backed unsigned pre-sign mode as an internal workflow/recovery interface rather than silently
  exposing it as a normal local Release APK;
- if local `gmsRelease`/`fossRelease` remains public, document its keystore dependency and whether the result is
  installable, and fail before the expensive build when signing configuration is absent;
- run at least one real representative channel debug build after the wrapper is added. Mocked delegation alone cannot
  prove the public build path or output contract.

### B4 — `--publish` can succeed without publishing

Severity: **blocker**

The current final workflow step performs the publisher dry-run when `REQUEST_PUBLICATION=true` but
`ENABLE_ARCP_RELEASE_PUBLISHING` is not exactly true. It then exits successfully. A simplified CLI called with
`--publish` could therefore report green completion although no release was created. This violates the public command
semantics and makes rollout verification unreliable.

Required change:

- fail early and clearly when publication was requested but the repository/environment activation variable is not
  true; reserve dry-run behavior exclusively for `publish=false`;
- after a successful publishing run, have the CLI query the expected immutable release/tag and verify its target and
  expected source identity rather than treating workflow success alone as publication proof;
- distinguish output states such as `dry_run_validated`, `published`, `existing_verified_noop` and `failed`; never
  label the first one as published;
- test `publish=false`, `publish=true + gate disabled`, a newly created release and an existing verified no-op.

## High-severity findings

### H1 — The request ID needs a workflow-enforced uniqueness and validation contract

Severity: **high**

A random CLI value is insufficient if manual callers can submit the same or malformed value. Unvalidated input in
`run-name` also makes log/UI correlation harder and could introduce control characters. The fallback for an empty UI
input creates multiple indistinguishable `manual` runs.

Recommendation:

- generate a high-entropy identifier with available system tooling and validate a short ASCII allowlist/length in both
  CLI and workflow; never evaluate or interpolate it into shell code;
- for non-empty IDs, include the exact value only through an environment/input expression and reject invalid values;
- make discovery fail on duplicates. For blank manual dispatches, include GitHub's unique run ID/attempt in the
  displayed name or document that they are not resumable by request ID;
- test invalid characters, overly long IDs, duplicate matches, delayed registration and two concurrent dispatches.

### H2 — Dry-run jobs retain write tokens and signing secrets

Severity: **high**

The default dry-run is logically non-mutating, but the current `resolve` and `sign-and-publish` jobs still receive
`contents: write`; the latter also enters the signing environment and receives the owner keystore. That is pre-existing
behavior, not a regression introduced by the wrapper, but promoting dry-run as the frequent default is a good point to
make the least-privilege distinction explicit.

Recommendation:

- preferably split preview/sign qualification from ledger reservation/publication so a `publish=false` run has only
  read permissions; keep the write-token job conditional on `publish=true`;
- if a signed dry-run intentionally remains necessary, document that it requires protected-environment approval and
  signing secrets, while still withholding `contents: write` from the signing-only path;
- keep every third-party action in the owner workflow pinned by full commit SHA and ensure no request-controlled ref or
  artifact can select executable signing/publishing code;
- add a workflow contract assertion that dry-run has no write-capable job, or explicitly record a scoped deferral if
  the job split is outside this change.

### H3 — “One publisher” must be an enforced precondition, not only a post-deployment setting

Severity: **high**

The plan applies GitHub configuration after pushing, but `scripts/arcp release` is not required to check that state.
If repository metadata drifts, an active manual legacy edge publisher remains another release writer. Also, checking
only display names is fragile because upstream can rename workflows while retaining their paths or add another
release-capable workflow.

Recommendation:

- address workflows by exact repository and workflow path/ID obtained from the Actions API, including disabled entries;
- make `release --publish` fail closed unless `arcp-channel-release.yml` and `ci.yml` are active and both known legacy
  paths are `disabled_manually`; a dry-run should at least report the drift prominently;
- have `github status` enumerate all workflows and separately flag unknown active workflows with release/tag write
  capability for human review rather than automatically disabling unknown files;
- require explicit owner repository and adequate authenticated permission before `github configure --apply`; never
  infer a mutation target only from the current directory;
- snapshot before/after states and print exact recovery commands if the multi-call enable/disable operation fails
  halfway. Do not claim it is atomic.

### H4 — Remote and branch guards need authoritative fetch semantics

Severity: **high**

Comparing local `main` with a possibly stale `origin/main` tracking ref can accept code GitHub has not received. The
plan also does not state that the CLI must be on `main`, nor whether SSH and HTTPS spellings of the exact owner remote
are supported. These details can cause either false safety or unnecessary failures.

Recommendation:

- require current branch `main`, a completely clean worktree, and an explicit `git fetch --no-tags origin main`
  immediately before comparing full SHAs;
- validate the normalized remote host, owner and repository exactly, supporting only deliberately tested HTTPS/SSH
  forms and rejecting near-match repositories;
- pin dispatch to `--ref main`, record the resulting expected workflow SHA, and reject a discovered run whose
  `headSha` differs;
- validate `gh auth status`, authenticated repository identity and required Actions/repository permissions before any
  mutation or dispatch.

## Medium-severity findings

### M1 — `release status` needs precise exit and output semantics

Severity: **medium**

It is unclear whether an informational list returns failure because one historical run failed, how a waiting protected
environment is represented, or whether output is intended for scripts.

Recommendation: define listing as read-only and successful when the query succeeds; define exact status/watch as
non-zero only for a terminal unsuccessful run or lookup ambiguity/timeout. Offer stable text fields or optional JSON,
and distinguish `queued`, `in_progress`, `waiting`, `action_required`, `success`, `failure`, `cancelled`, `timed_out`
and `startup_failure`.

### M2 — CI integration should minimize the upstream conflict surface

Severity: **medium**

The new CLI and its tests are owner-only, while `.github/workflows/ci.yml` and the root README are upstream-owned files
that already carry significant fork deltas. Adding a second active fork-only test workflow would contradict the
desired two-workflow state, but scattering larger test logic into upstream files will make future merges harder.

Recommendation: keep all test behavior in `scripts/tests/test-arcp-cli.sh` and add only the smallest owner-delimited
invocation to the existing CI shell-contract block. Keep detailed usage in `docs/ARCP_CHANNEL_RELEASES.md`; add only a
short, clearly bounded owner-fork pointer/examples section to README. Do not edit either legacy workflow file merely to
mark it disabled.

### M3 — GitHub configuration mutation and rollback need audit evidence

Severity: **medium**

Workflow state is not represented by the Git commit, and three enable/disable calls are not transactional. A final
verification detects partial mutation but does not help reconstruct it later.

Recommendation: make `github configure` print a deterministic before/desired/after table with path, workflow ID and
state; make a no-op apply explicitly idempotent; preserve run history; and record the post-apply readback in rollout
evidence without storing authentication material. Rollback should restore the captured pre-state, not blindly enable
all legacy workflows.

### M4 — Revision input should be bounded and its repair meaning retained

Severity: **medium**

The ledger validates only a positive decimal and converts it through JavaScript `Number`; an arbitrarily long CLI
value is unnecessary and complicates run names. Users may also increment revision before determining that the exact
source release genuinely needs repair.

Recommendation: bound the CLI/workflow revision to a documented small positive integer, preserve revision `1` as the
default, and describe `>1` as a deliberate same-source repair that creates a greater immutable version code. A dry-run
of a repair remains useful, but it must not reserve the ledger entry.

## Required verification additions

Before rollout, the updated plan should require all of the following:

1. Shell syntax and contract tests for argument parsing, literal publish opt-in, source/variant matrix, exact owner
   targeting, authoritative fetch, dirty/diverged main, request-ID validation, delayed/duplicate run discovery,
   bounded timeout, all terminal run states and partial GitHub configuration failure.
2. Workflow contract/actionlint tests for optional validated request ID, expected full source SHA inputs, pinned
   automation ref, dry-run/write-permission boundary, publication activation failure and legacy workflow state names.
3. Existing sync/build, ledger and sign/publish suites unchanged and green.
4. One real stable or edge debug build through `scripts/arcp build`; mock delegation for the other channel is
   sufficient if live `channel-info` proves both refs.
5. After push and green CI, an idempotent `github configure --apply` with before/after readback, followed by a second
   no-op apply.
6. A real non-publishing workflow dispatch through the CLI, exact registration discovery, resumable watch by request
   ID, successful completion and proof that neither GitHub Releases nor `release/version-ledger` changed.
7. No real `--publish` is necessary for this tooling-only change unless explicitly desired, but the mocked contract
   must prove that a requested publication cannot silently degrade to dry-run. No Android deployment is required.
8. A tracked-file audit for env files, tokens, keystores, PINs, browser/session material and generated artifacts before
   commit and push.

## Final verdict

The architecture is sound and upstream-friendly after the corrections above. The recommended implementation order is:
freeze the public source/variant and status contracts; bind immutable source SHAs plus a validated request ID into the
workflow; make requested publication fail closed; implement and test the wrapper; update narrowly scoped docs/CI;
push and obtain green CI; finally apply and verify the GitHub workflow-state convergence and run the exact dry-run E2E.

With B1–B4 incorporated, the design is suitable for implementation. Without them, the simplified interface would be
easier to invoke but less precise than the low-level mechanisms it replaces.
