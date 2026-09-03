<!-- IMPLEMENTED — independently reviewed; B1-B6 findings incorporated; external resources and credentials were not rotated. -->
<!-- Never copy plaintext credentials, real infrastructure identifiers, account emails, device endpoints or private topology into the public repository or its CI logs. -->

# Plan 78 — split public ARCP code from private owner configuration

## Goal

Keep the upstream-friendly ARCP fork public while moving every owner-specific device, infrastructure and service
snapshot out of its Git tree into a standalone private configuration repository. Preserve routine build, release,
verification and deployment commands through one configurable boundary instead of hard-coded `myconf/` paths.

This plan deliberately does **not** rotate or recreate any Cloudflare, registrar, ngrok, ChatGPT, OAuth, Android or
other external resource, identifier, hostname, credential or token. Such rotation is a separate operational decision.

## Verified baseline

- The owner repository is a public fork; a fork cannot independently be made private while it remains in the public
  upstream network.
- The current tree tracks 50 files under `myconf/` (about 155 KB), and 30 commits have touched that directory.
- The first `myconf/` commit is reachable from `main`, `release/edge` and multiple release/source tags. Removing the
  directory from the next commit therefore stops current-tree publication but does not erase historical disclosure.
- The public README currently publishes the managed-device inventory and deployment status.
- Owner tooling directly assumes `$REPO_ROOT/myconf/<device>` in deployment, release-install and validation paths;
  device aliases, capabilities and at least one network address are also hard-coded outside `myconf/`.
- Public GitHub secret scanning and push protection are enabled. They protect credentials but do not classify the
  non-secret infrastructure metadata covered by this plan.
- In addition to the three ignored `.env.secrets` files, ignored runtime content currently includes Terraform state,
  a saved plan and provider cache beneath one device profile. Provider cache is disposable and must not be migrated;
  state/plan require separate protected inventory and handling.
- ARCP channel release static builds already use a secretless mode that skips live device-configuration verification.
  The complete public release workflow is not secretless: its existing protected live-ngrok and signing jobs consume
  scoped secrets. It must remain independent of the private configuration repository and receive no private-repo PAT.

## Target architecture

### Public ARCP fork

The public repository retains only:

- application and owner-extension source code;
- upstream integration branches and release automation;
- configuration schemas and reusable validation logic;
- synthetic phone/TV fixtures using `example.com`, RFC 5737/3849 documentation addresses and unmistakably fake IDs;
- generic documentation for attaching an external configuration root.

The public repository must not retain a real `myconf/` tree, device inventory, endpoint table, live snapshots,
registrar/account records, connector inventories, real device aliases or exact private-network topology.

### Private configuration repository

Create a new standalone private repository, referred to in this plan as `<PRIVATE_CONFIG_REPO>`. It must not be a fork
and its actual repository name need not be published in the public tree. Use this logical layout:

```text
devices/
  <profile>/
    profile.json
    README.md
    snapshot.json
    android/
    cloudflare/
    chatgpt/
    ngrok/                 # optional capability, not a mandatory common directory
    registrar/             # optional capability
    scripts/
secrets/
  <profile>.env.sops       # optional encrypted backup; never plaintext Git content
runtime/                   # ignored; materialized mode-0600 files only
schemas.lock.json          # public-code/schema revision required by this config revision
```

The private repository owns environment inventories, actual Terraform values, live snapshots, service/account
metadata, current runbooks and device-specific deployment policies. Plaintext runtime secrets remain ignored. If
versioned recovery of secrets is required, store only SOPS-encrypted files using an `age` recipient whose private key
is backed up outside both repositories and GitHub.

### Configuration-root boundary

Add one owner-side adapter, for example `scripts/lib/arcp-config-root.sh`, without modifying upstream application
classes. Only commands that actually act on a device resolve configuration, and they do so lazily in this order:

1. explicit `--config-root <absolute-directory>`;
2. `ARCP_CONFIG_ROOT` environment variable;
3. fail closed with a concise setup message.

There is no fallback to a repository-local real configuration directory. Canonicalize the path, require a readable
directory, reject symlinks where secrets are consumed, and never print its contents or resolved secret values.
Only public profile/adapter contract tests supply the synthetic fixture root explicitly.

The resolver is required for `check`, `deploy`, `rollback`, the deployment portion of `all`, artifact `deploy` and
retained device helpers. It must not be evaluated by `sync`, `channel-info`, any ordinary/channel `build`,
`scripts/arcp build`, `scripts/arcp release`, artifact `download`/`verify`, version ledger, signing or publishing.
Synthetic roots are supplied only to profile/adapter contract tests, never as a hidden build prerequisite.

## Profile and command contract

1. Replace device-name conditionals in owner scripts with `--profile <name>` plus a validated private `profile.json`.
2. Define a public JSON schema for non-secret profile structure. At minimum it contains:
   - expected Android identity and supported ABI/API constraints;
   - application ID and permitted deployment mode;
   - ADB serial source, never an embedded real default;
   - supported tunnel/connectivity capabilities;
   - optional PIN, ngrok and first-install capability flags;
   - paths to configuration, verifier and apply adapter relative to the profile root.
3. Validate profile names against a conservative allowlist, resolve every relative path beneath the configuration
   root and reject traversal, duplicate profiles, unknown capability values and ambiguous device matches.
4. Keep destructive deployment fail-closed: an explicit `--apply`, a qualified APK manifest, exact package/certificate
   expectations and live device-identity match remain mandatory.
5. Make the following owner tools consume the shared resolver instead of `$REPO_ROOT/myconf` or device literals:
   - `scripts/sync-build-deploy.sh`;
   - `scripts/arcp-release-artifact.sh`;
   - `scripts/verify-device-configs.sh`;
   - device proof-of-concept/deployment helpers still retained after inventory review.
6. Preserve current low-level command compatibility temporarily by accepting the old device option as a deprecated
   alias resolved by private inventory. Do not keep aliases, addresses or mappings in the public repository. Remove
   the compatibility path after one successful release/deployment cycle from the private repository.
7. Prefer explicit environment credentials such as `NGROK_AUTHTOKEN`; any file fallback must resolve under the private
   root and use the existing strict single-assignment parser and mode-0600 checks.
8. Remove the existing configuration verification call from ordinary `build`. Device configuration is validated by
   explicit profile tests and immediately before device operations, not as a prerequisite for compiling an APK.

## Migration work

### Phase 1 — inventory and protected bootstrap

1. Produce a machine-readable inventory over all `git ls-files`, including application/debug sources, owner scripts,
   docs, plans, reviews and `myconf/`. Report only category, file and line—not the matched value—and use narrow,
   documented allowlists for generic tests and source-package ownership.
2. Create an encrypted offline backup of the current configuration and ignored plaintext secret files. Verify the
   backup before changing either repository.
3. Create `<PRIVATE_CONFIG_REPO>` as private and immediately verify its visibility through the GitHub API before any
   content push. Disable public forking and restrict collaborators/actions as appropriate for the account plan.
4. Install the private repository's `.gitignore` and tracked-file policy before importing content. Import only the
   exact list returned by `git ls-files myconf`; never recursively copy `myconf/` and then run a broad `git add`.
5. Preserve configuration history privately if useful by extracting the tracked subdirectory in a disposable clone;
   never force-push the public repository during this phase. Do not create `profile.json` until the transitional public
   schema has been pushed and pinned in Phase 3.
6. Inventory every ignored file by path/type/mode/size only. Move `.env.secrets`, Terraform state and saved plans
   directly between protected local directories without printing values. Do not import `.terraform/`, caches or
   provider binaries. Either keep runtime files ignored and mode 0600 or encrypt the required recovery data with SOPS
   before the first private push.
7. Audit the private Git index before first push. If any current-tree, ignored-file or history scan finds an actual
   credential, stop this plan and open a separately authorized incident-response/rotation task; unchanged credentials
   cannot be accepted merely because rotation is out of this plan's normal scope.

### Phase 2 — public adapter, schema and synthetic fixtures

1. Implement the single configuration-root resolver and thread it through the owner scripts listed above.
2. Convert hard-coded per-device behavior to schema-validated capability policies. Preserve the existing safety gates
   and package/certificate/device identity checks.
3. Add synthetic fixtures for at least a generic phone, a phone with optional fallback transport and a 32-bit TV-like
   target. Fixture values must have no relationship to the real environment.
4. Refactor `verify-device-configs.sh` to discover profiles from the supplied root and validate schema/capabilities
   rather than a fixed device list and filenames.
5. Change public unit/contract tests to create temporary fixture roots. Tests must cover explicit option precedence,
   environment fallback, missing root, path traversal, symlink rejection, malformed profiles, capability dispatch and
   absence of repository-local fallback.
6. Run every configuration-independent command with both `--config-root` absent and `ARCP_CONFIG_ROOT` unset. Prove
   that sync/channel-info, ordinary and stable/edge builds, `scripts/arcp` build/release, artifact download/verify,
   ledger, sign and publish neither read `myconf/` nor resolve/fetch `<PRIVATE_CONFIG_REPO>`.
7. Keep static channel builds secretless and the complete public release workflow independent of private
   configuration. Preserve the existing separately protected ngrok/signing secret boundaries without broadening them.

### Phase 3 — private automation

1. Add a private validation workflow that accepts only a full 40-character SHA already reachable from an explicitly
   trusted owner branch/tag allowlist, checks out that exact revision, and validates `devices/` against its schema. A
   public PR, arbitrary ref or `pull_request_target` event must never choose code executed with private data/secrets.
   The job must not upload configuration snapshots to artifacts/cache/step summary or echo matched values.
2. Store the expected public schema/source revision in `schemas.lock.json`; fail when private configuration and public
   tooling are incompatible instead of silently using `main`.
3. Create and schema-validate one explicit `profile.json` for every imported target against the pinned transitional
   public schema.
4. Add private wrapper commands for validate, check, deploy preview and apply. They set `ARCP_CONFIG_ROOT` and invoke
   the public scripts at the pinned revision instead of copying their implementation.
5. Split private automation into a read-only, credential-free validation job and a separate manual decrypt/apply job
   protected by environment approval. If remote deployment later needs decrypted secrets, decrypt to a mode-0600
   temporary directory with reliable cleanup. Initial migration should prefer local deployment so no new secret
   distribution channel is introduced.

### Phase 4 — remove current-tree metadata and document the boundary

1. Remove the tracked public `myconf/` directory only after the private copy and its validation are proven.
2. Replace the public managed-device README section with generic external-configuration documentation and synthetic
   examples. Do not name the private repository, accounts, devices, services or endpoints.
3. Review every path returned by `git ls-files`, including application/debug sources, scripts, plans, reviews and
   documentation, for real emails, domains, IP addresses, account IDs, connector/tunnel/record IDs, device inventory
   and live security posture. Move operational detail to the private repository; retain only sanitized engineering
   decisions useful to the public code.
4. Add an ignored local pointer/example file only if environment-variable setup is insufficient. It may contain the
   local path but never credentials and must be covered by the tracked-file policy test.

### Phase 5 — prevent recurrence

1. Add `scripts/verify-public-metadata.sh` and run it in public CI and the developer pre-push path. It reports only a
   category and location and never the matched value.
2. Fail on forbidden live-snapshot/account/connector file classes, real email addresses, exact RFC1918 host addresses,
   non-example domains and provider-specific identifier shapes outside an explicit narrow test allowlist.
3. Keep generic code/test UUIDs possible through path-aware allowlists; do not build a brittle global UUID ban.
4. Run a second, private denylist check against a checkout of the public tree. The denylist can contain actual owner
   domains/identifiers but must live and execute only in the private repository, with redacted failure output.
5. Retain GitHub secret scanning and push protection. Add a local tracked-file audit covering `.env.secrets`, Terraform
   state, keystores, decrypted SOPS output, browser state, APKs and signing material.
6. Configure future commits to use the GitHub `noreply` address. A `.mailmap` may improve display but must not be
   represented as removing the original email from Git objects.

## History policy

This plan removes metadata from the current public tree and prevents recurrence; it does not claim to erase data that
has already been published. The default execution must **not** rewrite Git history, move existing tags, recreate
releases or delete Actions history. Those operations would affect signed/provenance-bearing releases and still could
not remove other clones or cached objects.

As a mandatory closeout, produce a separate read-only impact report covering every affected branch, tag, release,
workflow artifact and pull-request reference. Any history rewrite or clean-room repository replacement requires a new
plan, explicit authorization, verified backups and a release/provenance migration design.

## Verification matrix

### Public repository

- shell syntax, ShellCheck and focused resolver/profile contract tests;
- existing build, release-ledger and channel-release suites;
- `actionlint` for changed workflows;
- public metadata policy against every tracked current-tree file;
- secret/tracked-artifact audit;
- representative local and edge debug builds;
- GitHub CI green at the exact pushed SHA;
- release dry-run proves stable/edge publication remains independent of private configuration.

### Private repository

- repository visibility verified as private before and after push;
- all current profiles pass schema and device-specific verifier checks;
- SOPS decrypt/encrypt round-trip, if enabled, without plaintext Git or log output;
- `schemas.lock.json` rejects an incompatible public revision;
- deploy preview for every profile uses the expected artifact, application ID, certificate and target identity;
- read-only live `check` against each reachable target;
- one owner-authorized deployment smoke may be used only if adapter changes cannot otherwise be proven; no external
  service/resource rotation is allowed by this plan.

### Boundary assertions

- a fresh public clone builds and runs CI without access to the private repository;
- a private checkout plus the pinned public revision can validate and deploy without a public-tree `myconf/`;
- public workflow logs/artifacts contain no private configuration or derived inventory;
- current public tracked content contains no real owner email, environment hostname, exact private IP, provider ID or
  named device inventory;
- `git ls-files` contains no plaintext secrets, decrypted SOPS files, Terraform state or signing material.
- every configuration-independent command passes with `ARCP_CONFIG_ROOT` unset and with no repository-local
  configuration tree available.

## Commit and rollout sequence

1. Private bootstrap: create and verify the private skeleton, ignore/policy rules and safe tracked-only import. Stop if
   visibility or index audit fails.
2. Transitional public commit: add the lazy configuration-root adapter, schemas, synthetic fixtures and tests while
   the existing `myconf/` still exists. Push it and require green public CI at its exact full SHA.
3. Private migration commit: create every `profile.json`, wrappers and `schemas.lock.json` pinned to the full trusted
   transitional public SHA. Push it, require green private read-only validation, then run local read-only checks.
4. Final public commit: remove `myconf/`, sanitize all current tracked files and add metadata policy checks. Push it,
   require green public CI plus a release dry-run at the exact final SHA.
5. Final private lock commit: update `schemas.lock.json` to the full final public SHA, rerun private validation/check and
   prove operation with no public-tree `myconf/`. This is the required end-state proof, not an optional follow-up.
6. Record exact public/private commit SHAs and test evidence in their respective repositories without copying private
   identifiers into the public closeout note. Every numbered stage is a stop gate; do not batch the pushes.

## Acceptance criteria

- No real owner/environment configuration remains in the current public tree.
- Routine public build and release behavior works without private-repository access.
- Local/private verification and deployment work through `--config-root` or `ARCP_CONFIG_ROOT` with no repository-local
  fallback.
- Per-target behavior comes from validated private profiles rather than public aliases, addresses or account data.
- Public CI uses only synthetic fixtures; private CI never publishes configuration artifacts or unredacted matches.
- Existing deployment identity, certificate, provenance and explicit-apply safety gates remain effective.
- Plaintext secrets remain untracked in both repositories; any versioned secret recovery data is SOPS-encrypted.
- External resources and credentials remain unchanged, as required by this plan's explicit scope exclusion.
- Historical exposure is documented accurately and no destructive history rewrite is performed implicitly.
- Private automation executes only an allowlisted full owner SHA; validation has no secrets, while decrypt/apply is a
  separate manual protected job.

## Rollback

- Keep the verified offline backup until two successful private validation/deployment cycles are complete.
- Roll back forward-only: fix the public adapter in a new commit, or pin the private repository to the last known-good
  public SHA and use the backup in an isolated local checkout. Never revert/push a commit that restores `myconf/` to
  the public tree.
- Restore the private repository from the encrypted backup without copying it into the public checkout.
- Retain the old command compatibility adapter for one release cycle, then remove it only after recorded success.
- Do not force-push history, move tags or republish prior releases as rollback actions.

## Explicitly out of scope

- rotating or recreating tunnels, DNS records, domains, service accounts, OAuth clients/connectors, tokens, PINs,
  certificates, signing keys or Android security configuration;
- changing externally visible endpoints or deploying replacement infrastructure;
- rewriting published Git history, tags or releases;
- requesting GitHub cache/support purges;
- making upstream application classes depend on owner-specific infrastructure.
