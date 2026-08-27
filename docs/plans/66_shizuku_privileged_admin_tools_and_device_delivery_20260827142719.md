<!-- SACRED DOCUMENT — DO NOT MODIFY except for checkmarks ([ ] → [x]) and review findings. -->
<!-- You MUST NEVER alter, revert, or delete files outside the scope of this plan. -->
<!-- Plans in docs/plans/ are PERMANENT artifacts. There are ZERO exceptions. -->

# Plan 66 — Shizuku privileged admin tools and safe device delivery

Extend the existing Android Remote Control MCP fork with an opt-in, auditable Shizuku administration layer for
Samsung Galaxy A34 5G (`[REDACTED_DEVICE_ALIAS]`), then make the same build reproducibly deployable to Xiaomi 11T (`[REDACTED_DEVICE_ALIAS]`). The current
MCP server, bearer/OAuth authentication, Cloudflare tunnel, foreground service, logging, tool-permission model, and
device configuration remain authoritative. There MUST be no second public MCP server and no second inbound Android
port in the production architecture.

The privileged implementation uses the Apache-2.0 `stixez/droid-mcp` Shizuku module behind a local adapter. It MUST be
consumed as an exact, reviewed dependency rather than importing the second project's Git history or copying its whole
server. Updates from `danielealbano/android-remote-control-mcp` and updates of `droid-mcp` are two independent flows.

This plan also adds one guarded local automation script for upstream synchronization, validation, building, signing
preflight, installation, configuration restoration, service restart, and live deployment verification.

## Fixed architecture and security decisions

- The existing Android Remote Control MCP HTTP transport remains the ONLY production server and continues to listen
  on `127.0.0.1:8080` on managed devices.
- The existing Cloudflare tunnel and public URLs remain authoritative:
  - `[REDACTED_DEVICE_ALIAS]`: `[REDACTED_OWNER_VALUE]`;
  - `[REDACTED_DEVICE_ALIAS]`: `[REDACTED_OWNER_VALUE]`.
- Shizuku tools are registered in the existing MCP server through a narrow adapter; `droid-mcp`'s Ktor/HTTP server,
  mDNS advertisement, TLS implementation, token store, and foreground server service MUST NOT be started.
- Shizuku grants Android `shell` UID 2000, not root. Root, Magisk, Sui, `/system` writes, and access to other apps'
  private `/data/data` directories are OUT OF SCOPE.
- Typed administration tools are enabled individually. Arbitrary `run_shell` is disabled by default and remains
  default-deny even for an authenticated client until an explicit allowlist is configured.
- The normal ChatGPT OAuth scope MUST NOT silently gain privileged execution. Initial privileged access is restricted
  to the locally managed administrator bearer credential. If the current request context cannot reliably distinguish
  that credential from OAuth clients, implementation MUST stop for a plan amendment; it MUST NOT weaken the gate.
- Every privileged invocation is logged with tool name, outcome, duration, and authenticated client class. Tokens,
  command arguments, file contents, notification contents, and other secrets MUST NOT be logged.
- Shizuku cannot be made reliably persistent across reboot without root. The app reports `unavailable` until Shizuku
  is restarted and permission is valid; it MUST NOT claim privileged readiness merely because the MCP service listens.
- A release signed with a different certificate MUST NOT automatically uninstall or overwrite the installed app.
  Signature mismatch is a hard stop requiring the explicit one-time migration procedure in User Story 7.
- [REDACTED_DEVICE_ALIAS] is the canary device. [REDACTED_DEVICE_ALIAS] deployment occurs only after the [REDACTED_DEVICE_ALIAS] acceptance gates pass and the owner explicitly
  approves promotion.
- No token, keystore, password, OAuth client secret, tunnel credential, or `.env.secrets` content may enter Git, build
  logs, deployment manifests, command traces, or test fixtures.

## Upstream model

| Source | Role | Update mechanism |
|---|---|---|
| `upstream/main` → `danielealbano/android-remote-control-mcp` | Application, MCP transport, OAuth, tunnel and UI | Merge on a temporary `sync/upstream-*` branch; never rebase or force-push shared `main` |
| `stixez/droid-mcp` exact release/commit | Shizuku shell backend and typed admin behavior | Explicit Gradle version/hash bump in a dedicated dependency PR |
| `origin/main` | Owner's deployable fork | PR from tested feature/sync branches; `origin` must exist before automation may push |

The local repository currently has a fetch-only `upstream` remote and no `origin`. Creation of the GitHub fork and
addition of `origin` are required before push/PR automation can be enabled. The existing uncommitted `myconf/` move
MUST be completed or otherwise resolved before any upstream merge is attempted.

## Scope boundary

This plan may create or modify only the following paths:

- `docs/plans/66_shizuku_privileged_admin_tools_and_device_delivery_20260827142719.md`
- `docs/PROJECT.md`
- `README.md`
- `LICENSES/` or `THIRD_PARTY_NOTICES.md` for required Apache-2.0 attribution
- `settings.gradle.kts`
- `gradle/libs.versions.toml`
- Gradle dependency verification/locking files, if the dependency spike proves they are required
- `shizuku-admin/**` (new isolated Android library module)
- `app/build.gradle.kts`
- `app/src/main/AndroidManifest.xml`
- `app/src/main/kotlin/com/danielealbano/androidremotecontrolmcp/di/**` only for Shizuku bindings
- `app/src/main/kotlin/com/danielealbano/androidremotecontrolmcp/data/model/**` only for privileged-tool settings
- `app/src/main/kotlin/com/danielealbano/androidremotecontrolmcp/data/repository/**` only for those settings
- `app/src/main/kotlin/com/danielealbano/androidremotecontrolmcp/mcp/**` only for authenticated-client context and
  privileged tool registration/gating
- `app/src/main/kotlin/com/danielealbano/androidremotecontrolmcp/services/mcp/McpServerService.kt`
- `app/src/main/kotlin/com/danielealbano/androidremotecontrolmcp/ui/**` only for Shizuku status, permission and policy UI
- `app/src/main/res/values/strings.xml`
- corresponding tests under `app/src/test/**`, `shizuku-admin/src/test/**`, and `e2e-tests/src/test/**`
- `scripts/sync-build-deploy.sh` (new)
- `scripts/tests/test-sync-build-deploy.sh` (new; shell-level contract tests)
- `scripts/verify-device-configs.sh`
- `.gitignore`
- `myconf/README.md`
- `myconf/[REDACTED_DEVICE_ALIAS]/README.md`, `myconf/[REDACTED_DEVICE_ALIAS]/android/**`, `myconf/[REDACTED_DEVICE_ALIAS]/scripts/verify.sh`
- `myconf/[REDACTED_DEVICE_ALIAS]/README.md`, `myconf/[REDACTED_DEVICE_ALIAS]/android/**`, `myconf/[REDACTED_DEVICE_ALIAS]/scripts/verify.sh`

Explicitly OUT OF SCOPE:

- changes to Cloudflare DNS, tunnel IDs, tunnel tokens, public hostnames, ingress rules, Regery or ngrok resources;
- changes to the existing OAuth protocol, DCR redirect policy or ChatGPT connector registration;
- a separate public `/admin/mcp` service or a separate production port;
- automatically starting Shizuku by simulating UI taps, notification clicks or wireless-debugging pairing;
- Qustodio policy mutation;
- unattended CI deployment to physical phones;
- automatic uninstall, factory reset, root enablement, bootloader unlocking or signature-bypass techniques.

**Plan document handling:** this file is a tracked, permanent artifact and MUST be committed alone as
`docs(plans): add plan 66`. Creating this document does not authorize implementation outside the scope above.

---

## User Story 1 — Dependency, license and compatibility spike

**Why:** `droid-mcp` uses its own tool abstractions and also ships an HTTP server that must not compete with the current
application. Before implementation, prove that only the Shizuku/backend portion can be consumed and adapted without
starting a second server or weakening authentication.

### Task 1.1 — Pin and verify the upstream artifact

- [ ] Record the reviewed `droid-mcp` release, signed tag/commit SHA, module coordinates and license.
- [ ] Add JitPack only in `dependencyResolutionManagement`; project repositories remain forbidden.
- [ ] Pin an exact version or commit. Dynamic versions (`+`, ranges, `latest.*`, snapshots) are prohibited.
- [ ] Verify the resolved artifacts and transitive Shizuku dependencies. Record hashes using the repository's chosen
  Gradle verification/locking mechanism.
- [x] Add the Apache-2.0 notice required for redistributed object code without changing the project's MIT license.
- [x] Confirm the module supports the project's Android minimum SDK, Kotlin/AGP versions, R8 release build, and both
  `gms` and `foss` variants.

### Task 1.2 — Prove the adapter boundary

- [x] Build a compile-only spike in `shizuku-admin` demonstrating access to Shizuku permission status and one harmless
  read-only operation.
- [x] Prove that no `droid-mcp` HTTP transport, mDNS registration, token store or service is instantiated.
- [x] Map `droid-mcp` success/error results into the existing `McpToolException` taxonomy without leaking raw stack
  traces or binder details to clients.
- [x] Confirm cancellation and timeouts propagate through the adapter and do not block the MCP server thread.
- [ ] If the library API cannot provide this boundary, STOP. Copying sources or enabling its server requires an explicit
  review finding and user-approved plan amendment.

**Acceptance gate:** both flavors compile with an exact dependency, license obligations are recorded, and one local
read-only adapter test passes without opening a network socket.

---

## User Story 2 — Isolated Shizuku administration module

**Why:** Keeping privileged code outside `:app` localizes upstream merge conflicts and makes the trust boundary
reviewable.

### Task 2.1 — Define application-owned interfaces

- [x] Create `PrivilegedAdminBackend` with typed methods rather than exposing raw library classes to `:app`.
- [ ] Create a sealed readiness state covering: Shizuku missing, service stopped, permission required, ready, binder
  died, unsupported and internal failure.
- [ ] Create application-owned request/result DTOs with bounds on package names, permission names, setting namespaces,
  command length, output size and execution timeout.
- [ ] Make mutating methods explicit; read methods MUST NOT be mislabeled as destructive and destructive methods MUST
  carry the existing MCP destructive annotations.

### Task 2.2 — Implement the Shizuku backend

- [ ] Delegate typed operations to the pinned `droid-mcp-shizuku` implementation.
- [ ] Register binder received/dead and permission-result listeners without retaining an Activity.
- [ ] Handle binder death deterministically: mark tools unavailable, cancel in-flight calls, and allow recovery when the
  binder returns.
- [x] Never interpret Shizuku availability as MCP server availability or vice versa.
- [x] Enforce per-operation timeouts and bounded stdout/stderr. Truncation is reported to the caller.

### Task 2.3 — Typed privileged surface

Implement and test the following typed capabilities, subject to platform support:

- [ ] list application permissions;
- [ ] grant and revoke runtime permission;
- [ ] force-stop application;
- [ ] enable and disable application;
- [ ] install a staged APK;
- [x] uninstall an application for Android user 0 through a fixed `pm uninstall --user 0` argument vector;
- [ ] clear application data, with an explicit destructive marker;
- [x] read top-window information;
- [ ] read/write approved `secure`, `global` and `system` settings keys;
- [ ] read/set standby bucket and inactive state;
- [ ] quiet screen capture, only if it materially adds to existing capture behavior.

`run_shell` is separate:

- [ ] It is absent from `tools/list` when disabled.
- [ ] Its default allowlist is empty.
- [ ] Allowlist entries use command plus argument constraints; a prefix-only string check is insufficient.
- [ ] Shell metacharacters, nested shells, command substitution, redirection and uncontrolled pipelines are rejected
  unless a future reviewed rule explicitly supports them.
- [ ] Timeout, output cap and audit behavior are tested.

### Task 2.4 — Module tests

| Test class | Required coverage |
|---|---|
| Backend readiness | missing/stopped/ungranted/ready/binder-death/recovery states |
| Input validation | malformed package/permission/setting names, oversized inputs and traversal-like APK paths |
| Error mapping | permission denied, Shizuku unavailable, timeout, binder failure and command failure |
| Shell policy | default deny, exact allowed command, rejected metacharacters, rejected extra args and timeout |
| Resource safety | listener removal, cancellation, bounded output and no Activity leak |

**Acceptance gate:** privileged code has no network permission or listener, all module tests pass, and the module can be
removed from `settings.gradle.kts` without modifying Cloudflare/OAuth implementation.

---

## User Story 3 — Existing MCP server integration and client authorization

**Why:** Authentication to `/mcp` is not by itself authorization for Android shell privileges. Admin calls require a
stronger policy than ordinary accessibility tools.

### Task 3.1 — Propagate authenticated client class

- [x] Identify requests authenticated by the configured primary administrator bearer token versus OAuth access tokens.
- [x] Expose only a non-secret client class/label to the tool execution context; never expose the token itself.
- [x] Define `PrivilegedToolAuthorizer` with the initial rule: administrator bearer is eligible; ordinary OAuth and
  unauthenticated callers are denied.
- [x] Use constant-time token verification already provided by the authentication layer; do not compare plaintext
  credentials again inside tool implementations.
- [x] If reliable identity propagation cannot be implemented with the current MCP SDK, STOP for a plan amendment.

### Task 3.2 — Register tools with one upstream-conflict seam

- [x] Add one call from `McpServerService.registerAllTools`, conceptually:

  ```kotlin
  registerShizukuAdminTools(registrar, privilegedAdminBackend, privilegedToolAuthorizer, toolNamePrefix, perms)
  ```

- [x] Put all schemas, handlers, validation and authorization under the isolated privileged tool package/module.
- [x] Preserve the device slug naming convention and existing tool disable/parameter policy.
- [x] Denied privileged calls return a stable permission error and do not invoke the backend.
- [x] Unready Shizuku calls return a stable readiness error with a short administrator-facing recovery hint.
- [x] Ensure privileged tool results pass through the existing logging and tool-call indicator mechanisms.

### Task 3.3 — Security policy and audit tests

| Test | Expected result |
|---|---|
| Administrator bearer + enabled typed tool + ready Shizuku | backend called once; result returned |
| OAuth token + privileged tool | denied before backend call |
| Invalid/absent credential | rejected by existing transport authentication |
| Disabled tool | absent or blocked according to current tool-permission contract |
| Shizuku stopped | stable unavailable error; ordinary MCP tools remain operational |
| Destructive tool call | audit contains client class, tool, outcome and duration, but no arguments/secrets |
| `run_shell` disabled | absent from `tools/list` |
| `run_shell` enabled with empty allowlist | every command denied |

**Acceptance gate:** the existing ChatGPT connector cannot execute privileged tools, while the explicitly configured
administrator bearer can execute enabled typed tools. Existing OAuth and accessibility E2E tests remain green.

---

## User Story 4 — On-device permission, status and policy UI

**Why:** The administrator needs a clear way to grant and inspect Shizuku access, while a 12-year-old should not be
misled into believing that the privileged layer is always available.

### Task 4.1 — Shizuku permission lifecycle

- [ ] Add required Shizuku manifest integration and consumer rules; no exported unprotected component is introduced.
- [ ] Add an administrator action that opens Shizuku when missing/stopped and requests app permission when service is
  active. Permission result updates state immediately.
- [ ] Display separate statuses for MCP server, Cloudflare tunnel and privileged Shizuku backend.
- [ ] After reboot, show `Shizuku must be started` until the binder is actually available.
- [ ] Do not automate pairing, notification taps or Restricted Settings bypass.

### Task 4.2 — Privileged policy controls

- [ ] Add a master `privileged_tools_enabled` switch, off by default for fresh installs.
- [ ] Add per-tool switches using the existing tool-permission model.
- [ ] Keep arbitrary shell separately controlled and off by default.
- [ ] Provide an editable structured allowlist or ship a fixed reviewed allowlist; never accept a free-form comma-split
  policy without validation.
- [ ] Require explicit administrator confirmation before enabling clear-data, uninstall or arbitrary shell.
- [ ] Persist configuration through the existing repository with a backwards-compatible default migration.

### Task 4.3 — UI and persistence tests

- [ ] Unit-test default values, persistence round-trip and migration from current settings.
- [ ] Test permission result refresh and binder death/recovery.
- [ ] Verify ordinary server startup succeeds while Shizuku is stopped.
- [ ] Manually verify the administrator screen on [REDACTED_DEVICE_ALIAS] and [REDACTED_DEVICE_ALIAS]; record screenshots only if they contain no secrets.

---

## User Story 5 — Guarded sync, build and deployment script

**File:** `scripts/sync-build-deploy.sh`

**Why:** Upstream synchronization and device deployment must be repeatable without allowing a script to overwrite a
dirty tree, deploy to the wrong phone, leak credentials, erase app data or silently promote an untested build.

### Task 5.1 — Command contract

Implement the following interface:

```text
scripts/sync-build-deploy.sh check  --device <[REDACTED_DEVICE_ALIAS]|[REDACTED_DEVICE_ALIAS]>
scripts/sync-build-deploy.sh sync   [--upstream-ref upstream/main] --apply
scripts/sync-build-deploy.sh build  [--variant gmsDebug|fossDebug|gmsRelease|fossRelease]
scripts/sync-build-deploy.sh deploy --device <[REDACTED_DEVICE_ALIAS]|[REDACTED_DEVICE_ALIAS]> --artifact <apk> --apply
scripts/sync-build-deploy.sh all    --device <[REDACTED_DEVICE_ALIAS]|[REDACTED_DEVICE_ALIAS]> [--variant ...] --apply
scripts/sync-build-deploy.sh rollback --device <[REDACTED_DEVICE_ALIAS]|[REDACTED_DEVICE_ALIAS]> --artifact <known-good-apk> --apply
```

- [x] `--help` documents mutation boundaries, prerequisites and examples.
- [x] `check` is read-only.
- [x] `sync`, `deploy`, `all` and `rollback` make no mutation without the literal `--apply` flag.
- [x] There is no implicit device and no `all devices` default. A future `--device all` must additionally require
  `--confirm-all-devices`.
- [x] Unknown flags, variants, devices and additional positional arguments fail closed.

### Task 5.2 — Repository synchronization phase

- [x] Require a completely clean worktree, including staged, unstaged and untracked files, before `sync`/`all`.
- [x] Verify that `upstream` fetch URL is the official repository and that push is disabled.
- [x] Run `git fetch upstream --prune`, resolve `upstream/main` to an exact SHA and create
  `sync/upstream-YYYYMMDD-HHMMSS` from the current local `main`.
- [x] Merge with `git merge --no-ff upstream/main`; never use rebase, force-push, reset-hard or automatic conflict
  resolution.
- [x] On conflict, stop on the sync branch and print recovery instructions. Do not abort or discard the user's work.
- [x] Do not merge the sync branch back to `main` and do not push unless a separately documented explicit push flag is
  later approved. The initial implementation prints the PR commands only.
- [ ] Record local base SHA, upstream SHA and resulting merge SHA for the deployment manifest.

### Task 5.3 — Validation and build phase

The script runs in fail-fast order:

```text
scripts/verify-device-configs.sh
./gradlew ktlintCheck detekt
./gradlew :app:test :privacy:test :privacy-benchmark:test
./gradlew :e2e-tests:compileTestKotlin
./gradlew assemble<SelectedVariant>
```

- [ ] `all` runs every gate; individual `build` supports `--skip-e2e-compile` only as an explicitly reported local
  developer override and MUST mark the artifact unqualified for deployment.
- [ ] Deployment refuses an artifact produced with any skipped mandatory gate.
- [ ] Resolve exactly one APK and verify application ID, version code/name, variant and signing certificate.
- [ ] Compute SHA-256 and store an untracked build manifest below `build/deployments/`.
- [ ] Never source or print device secrets during build-only operations.

### Task 5.4 — Device identity and signing preflight

- [ ] Resolve ADB serial from explicit `--serial` or the selected device's local ignored secret file. Ambiguous ADB
  device selection is a hard error.
- [ ] Compare actual manufacturer/model/device identity with non-secret expected metadata under `myconf/<device>/`.
- [ ] Confirm the target is booted, authorized and not an emulator unless an explicit test-only flag is used.
- [ ] Read installed package ID, version and certificate digest. Compare it with the candidate APK certificate.
- [ ] Signature mismatch stops before install and links to User Story 7. The script MUST NOT run `adb uninstall`.
- [ ] Downgrade is rejected unless `rollback` was explicitly selected with a known-good artifact.
- [ ] Verify `.env.secrets` is ignored, mode `0600`, and required variables are non-empty without printing their values.

### Task 5.5 — Installation, configuration and restart

- [ ] Install with the least destructive supported `adb install -r` mode and preserve app data.
- [ ] Confirm the installed version and certificate after installation.
- [ ] Run `myconf/<device>/android/apply-config.sh --restart` with the selected serial.
- [ ] Do not automatically grant Restricted Settings, Shizuku access, accessibility access or Qustodio policy changes
  by UI automation. Report them as manual gates when required.
- [ ] A failed configuration application or service restart fails deployment; do not report partial success as ready.

### Task 5.6 — Post-deployment verification

- [ ] Run `myconf/<device>/scripts/verify.sh --live`.
- [ ] Verify the local server is bound only to loopback and that port 8080 is not directly reachable through Wi-Fi.
- [ ] Verify Cloudflare `/mcp`, OAuth discovery, bearer authentication and an ordinary read-only MCP call.
- [ ] Verify privileged readiness independently: Shizuku state, grant, typed read-only admin call, OAuth denial and
  administrator-bearer success.
- [ ] Verify `run_shell` is absent unless explicitly enabled and allowlisted.
- [ ] Verify the foreground notification, screen-off survival and one service restart. Reboot survival is a separate
  manual gate because Shizuku itself requires reactivation.
- [ ] Write only non-secret results to `build/deployments/<timestamp>-<device>.json`: Git SHAs, dependency version,
  APK hash, package version, certificate digest, redacted device identity, gates run and pass/fail states.

### Task 5.7 — Rollback behavior

- [ ] `rollback` accepts only an explicit existing APK whose hash and certificate match a previous successful local
  deployment manifest.
- [ ] It verifies package/signature/device identity exactly as deployment does.
- [ ] It never uninstalls the app and never uses downgrade flags outside this explicit subcommand.
- [ ] After rollback, reapply device configuration and run the same live verification gates.

### Task 5.8 — Shell contract tests

**File:** `scripts/tests/test-sync-build-deploy.sh`

Use temporary Git repositories and fake `git`, `adb`, `gradlew`, `apksigner`/`apkanalyzer`, and verifier executables;
tests MUST NOT contact a real device or network.

| Test | Expected result |
|---|---|
| dirty worktree | sync/all rejected before fetch |
| wrong upstream URL | rejected |
| missing `--apply` | mutation commands print preview and make no changes |
| merge conflict | preserved sync branch; no reset/abort/discard |
| two ADB devices without serial | rejected |
| device identity mismatch | rejected before install |
| APK application ID mismatch | rejected before install |
| signing certificate mismatch | rejected; uninstall never called |
| skipped mandatory gate | deployment rejected |
| missing/unsafe secrets file | rejected without printing secret content |
| successful canary deployment | exact ordered phases and deployment manifest |
| failed live verification | non-zero exit and no success marker |
| rollback with unknown artifact | rejected |

**Acceptance gate:** all shell contract tests pass, a dry-run shows every command, and a real `check` against [REDACTED_DEVICE_ALIAS] is
read-only. No production deployment happens in this user story.

---

## User Story 6 — Reproducible per-device configuration

### Task 6.1 — Non-secret deployment identity

- [x] Add the minimum non-secret expected device metadata required by the script under each `myconf/<device>/android/`.
- [ ] Keep ADB serial overrides and every credential in the existing ignored `.env.secrets` contract.
- [x] Extend `scripts/verify-device-configs.sh` so [REDACTED_DEVICE_ALIAS] and [REDACTED_DEVICE_ALIAS] must have the same deployment schema.
- [x] Preserve the existing boundary: [REDACTED_DEVICE_ALIAS] is Cloudflare-only; [REDACTED_DEVICE_ALIAS] retains optional ngrok fallback.

### Task 6.2 — Privileged policy snapshot

- [ ] Extend `android/config.json` schema equally for both devices with Shizuku/admin policy fields that contain no
  bearer token or sensitive command material.
- [ ] Store an allowlist only if it contains reviewed non-secret command policy. Never store interpolated credentials,
  private paths or user data.
- [ ] Update `apply-config.sh` to restore privileged flags only after the application supports the schema.
- [ ] Make old APK detection fail with a clear compatibility message rather than partially applying unknown extras.

### Task 6.3 — Documentation

- [ ] Document required local tools, signing configuration location, device selection and common failure modes.
- [ ] Document that Shizuku activation after reboot remains manual on non-rooted devices.
- [ ] Document the distinction between ordinary OAuth clients and the administrator bearer.
- [ ] Add check/build/deploy/rollback examples without real credentials or stable ADB serials.

---

## User Story 7 — Signing migration and staged rollout

**Why:** A custom fork cannot normally update an APK signed by the upstream author's key. The first production install
may therefore require a controlled package migration even though later owner-signed updates can use `adb install -r`.

### Task 7.1 — Parallel POC without replacing production

- [ ] Build `gmsDebug` with its existing debug application ID suffix and install it alongside the production app on
  [REDACTED_DEVICE_ALIAS].
- [ ] Use ADB forwarding or another explicitly local-only test path; do not expose the POC on Wi-Fi or add production
  Cloudflare ingress.
- [ ] Grant Shizuku to the debug package manually and run the US2–US4 functional/security tests.
- [ ] Remove the POC only after results and logs are captured without secrets.

### Task 7.2 — Owner release signing

- [ ] Create/use an owner-controlled release keystore outside Git; record only certificate digest and recovery/storage
  instructions, never the keystore or passwords.
- [ ] Verify reproducible release build and signed APK metadata.
- [ ] Archive the signed artifact and SHA-256 in a protected local release location.
- [ ] Confirm both target devices currently have the same or different signing identity and record the result.

### Task 7.3 — Explicit one-time [REDACTED_DEVICE_ALIAS] cutover, only if required

- [ ] Capture and validate the current [REDACTED_DEVICE_ALIAS] configuration using `myconf/[REDACTED_DEVICE_ALIAS]` and a live verification snapshot.
- [ ] Confirm Cloudflare/OAuth tokens are recoverable from the local ignored secret file before any removal.
- [ ] Obtain explicit user approval for the downtime and data-reset boundary.
- [ ] Stop the MCP service and tunnel.
- [ ] If and only if signature mismatch makes replacement impossible, manually uninstall the old package, install the
  owner-signed release, reapply configuration and perform every manual Android permission step.
- [ ] Restore Qustodio/battery/background allowances as needed without changing unrelated Qustodio policy.
- [ ] Verify ordinary MCP, Cloudflare, OAuth, administrator bearer, Shizuku typed tools and Wi-Fi non-exposure.
- [ ] Mark deployment `READY` only after every required live check passes; otherwise mark `PENDING` with exact blockers.

### Task 7.4 — Promotion to [REDACTED_DEVICE_ALIAS]

- [ ] Require a successful [REDACTED_DEVICE_ALIAS] canary including screen-off/service restart, Shizuku binder recovery and Cloudflare
  reconnection.
- [ ] Require explicit owner approval before selecting [REDACTED_DEVICE_ALIAS] in the deployment script.
- [ ] Repeat signing preflight; do not assume the installed certificate matches [REDACTED_DEVICE_ALIAS].
- [ ] Deploy, reapply `myconf/[REDACTED_DEVICE_ALIAS]`, verify primary Cloudflare and preserve the documented ngrok fallback.

---

## User Story 8 — Upstream maintenance workflow

### Task 8.1 — Application upstream merges

- [ ] Finish and commit the current `myconf/` reorganization before starting this plan's implementation branch.
- [ ] Create the personal GitHub fork and configure `origin`; retain `upstream` as fetch-only/push-disabled.
- [ ] Keep Shizuku work in small commits: dependency/module, backend, authorization/tools, UI/settings, automation,
  device docs. Avoid mixing upstream merges with feature edits.
- [ ] Perform upstream merges only on `sync/upstream-*` branches created by the automation script.
- [ ] Resolve conflicts manually, run all quality gates and use a PR into `origin/main`.
- [ ] Never rebase published `main` and never force-push it.

### Task 8.2 — `droid-mcp` dependency updates

- [ ] Treat every version bump as privileged supply-chain review, not routine automatic dependency maintenance.
- [ ] Review release notes and diffs for Shizuku backend, shell policy, transitive dependencies and Android components.
- [ ] Update exact version/commit and verification hashes in a dedicated PR.
- [ ] Run module, app, E2E compile, both-flavor release builds and the [REDACTED_DEVICE_ALIAS] canary gates.
- [ ] Do not combine a `droid-mcp` version bump with an application-upstream merge unless required to restore build
  compatibility and explicitly documented in the PR.

### Task 8.3 — Conflict minimization review

- [ ] Verify the application integration still has one privileged registration seam in `McpServerService`.
- [ ] Keep device-owned configuration under `myconf/`; upstream code must not gain device hostnames or credentials.
- [ ] When upstream implements an equivalent Shizuku feature, compare security and migration behavior, then either
  retire the adapter in a dedicated plan or continue it deliberately. Do not leave two privileged backends active.

---

## User Story 9 — Final quality and release gates

### Task 9.1 — Automated gates

- [ ] `scripts/tests/test-sync-build-deploy.sh`
- [x] `scripts/verify-device-configs.sh`
- [x] `./gradlew ktlintCheck detekt`
- [ ] `./gradlew :app:test :privacy:test :privacy-benchmark:test`
- [x] `./gradlew :e2e-tests:compileTestKotlin`
- [x] `./gradlew assembleGmsDebug assembleFossDebug assembleGmsRelease assembleFossRelease`
- [ ] `make test-e2e` where the required rootful Podman environment is available; otherwise record it as a required CI
  gate, not silently skipped.

### Task 9.2 — Security review

- [ ] No listener other than the existing loopback MCP server.
- [ ] No additional Cloudflare hostname, port or tunnel process.
- [ ] Ordinary OAuth cannot execute privileged tools.
- [ ] Bearer/OAuth failures do not reveal whether Shizuku is installed or ready.
- [ ] `run_shell` is absent/default-deny and parser tests cover common escape techniques.
- [ ] Logs, manifests and test output contain no credentials or private device content.
- [ ] Exported Android components and manifest permissions receive an explicit review.
- [ ] Dependency version, commit and hashes are reproducible and license notices are present.

### Task 9.3 — Definition of Done

- [ ] [REDACTED_DEVICE_ALIAS] runs the owner-signed build and remains reachable only through the documented Cloudflare tunnel.
- [ ] Existing accessibility/UI MCP tools and ChatGPT connector remain operational.
- [ ] Administrator bearer can use enabled typed Shizuku tools; ordinary OAuth cannot.
- [ ] Service availability and Shizuku readiness are reported separately and accurately after screen-off and reboot.
- [ ] The automation script can check, sync, build, deploy and rollback with all documented safety boundaries.
- [ ] [REDACTED_DEVICE_ALIAS] is either successfully promoted and verified or explicitly marked `PENDING`; it is never silently treated as
  deployed because [REDACTED_DEVICE_ALIAS] passed.
- [ ] `README.md`, `docs/PROJECT.md`, `myconf/README.md` and both device READMEs describe the final architecture and
  maintenance workflow.
- [ ] The plan-compliance review confirms no file outside the scope boundary was changed.

---

## Review findings — separate architecture and logic challenge, 2026-08-27

The findings below amend the earlier plan wherever they are more restrictive. They were produced before feature
implementation by inspecting the current authentication pipeline, tool-registration API, Gradle dependency graph,
device configuration scripts, and the `droid-mcp` 0.10.1 source/artifacts.

### RF-001 — BLOCKER: authenticated client class is not currently visible to MCP tool handlers

`McpAuthPlugin` validates static bearer and OAuth requests but currently returns without attaching a principal/client
class. `LoggedToolRegistrar` receives only `CallToolRequest`; therefore the proposed `PrivilegedToolAuthorizer` cannot
yet distinguish bearer from OAuth at execution time.

**Binding amendment:** before adding the Shizuku dependency or registering any privileged tool, implement a small
request-scoped authentication context and an integration test proving that it reaches the MCP handler for concurrent
bearer and OAuth requests without cross-request leakage. The context MUST be established only after constant-time
bearer verification or successful OAuth validation. If the MCP SDK breaks coroutine-context propagation, STOP; do not
approximate identity from request parameters, global mutable state, IP address, or timing.

### RF-002 — BLOCKER: the Shizuku AAR transitively brings a second MCP/Ktor server stack

The published `droid-mcp-shizuku:0.10.1` POM resolves `droid-mcp-shell-core`, `droid-mcp-core`, Shizuku API/provider,
and through `droid-mcp-core` Ktor server 3.1.2. This application already uses Ktor 3.4.0 and its own MCP server. Merely
not calling the second server is insufficient: it creates dependency/version and APK-size risk.

**Binding amendment:** consume only the public `ShizukuShellBackend`/`ShellBackend` boundary and exclude
`droid-mcp-core` plus its Ktor graph. A dependency report and both debug/release R8 builds MUST prove no second Ktor
version or droid HTTP transport is packaged. If the AAR cannot operate with that exclusion, STOP for a plan amendment
to implement the backend directly against the official Shizuku API; do not silently accept the duplicate server stack.

### RF-003 — HIGH: upstream `ShellAllowlist` does not meet this plan's shell policy

`droid-mcp` 0.10.1 implements process-global `command.startsWith(prefix)` checks. This can authorize unintended
arguments and is weaker than the structured command/argv constraints required above.

**Binding amendment:** `run_shell` is excluded from the first production milestone, not merely switched off. No class
from `droid-mcp`'s `RunShellTool`/`ShellAllowlist` may be registered or used. A future structured shell capability needs
a separate plan after typed tools are stable.

### RF-004 — HIGH: direct reuse of upstream tool objects bypasses application policy

The upstream `ShizukuTools.all()` returns `droid-mcp` tool objects with its own schemas, validation, errors and global
state. Passing raw argument maps through those objects would bypass this application's authorization and validation
boundary.

**Binding amendment:** the adapter may use only the shell backend/result/exception primitives. Every public MCP tool
schema, input validator, protected-package rule, settings-key policy and error mapping remains application-owned.

### RF-005 — HIGH: destructive package operations need an immutable protected-package policy

Typed operations can still disable, clear, stop or uninstall the MCP app, Shizuku, Qustodio/device-policy components,
System UI, launcher or package installer and strand remote administration.

**Binding amendment:** add a non-user-editable protected-package resolver covering at least the current app package,
Shizuku, active device-policy owners/admins, Qustodio components, System UI, current launcher, Settings and package
installer. `disable`, `uninstall`, `clear data` and `force stop` MUST reject protected targets before invoking Shizuku.
Tests use resolved package identities rather than only a static Samsung-specific list.

### RF-006 — HIGH: generic settings writes are too broad

Even typed `settings put` calls can disable networking, debugging, DNS, accessibility or other safety controls.

**Binding amendment:** the first milestone exposes no generic settings writer. Each permitted namespace/key is an
explicit application-owned policy entry with type/range validation. Mutations capture the previous non-secret value
for response/rollback while audit logs still omit values. Private DNS changes remain owned by `myconf` deployment
scripts, not by a general agent tool.

### RF-007 — HIGH: `install_apk` has no safe staging contract yet

The upstream tool expects a filesystem path usable by `pm install`, while this application primarily exposes SAF/media
storage. App-private and SAF paths are not automatically readable by shell UID and accepting arbitrary paths is unsafe.

**Binding amendment:** APK installation is deferred from the first milestone until a bounded staging design verifies
source authorization, size, package ID, signing certificate and cleanup. Uninstall remains eligible subject to RF-005.

### RF-008 — HIGH: repository sync and device deployment must not be one unreviewed transaction

The original `all` wording could merge a newly fetched upstream commit and immediately install it on a phone, bypassing
human diff review.

**Binding amendment:** `sync` only creates/updates a review branch and never deploys. `all` means check + test + build +
deploy the already checked-out, reviewed commit; it MUST NOT fetch or merge. A sync branch becomes deployable only after
review/PR merge or an explicit exact-SHA canary override recorded in the deployment manifest.

### RF-009 — HIGH: signing comparison needs a concrete installed-APK method

`dumpsys package` output is not a stable source for the full installed signing certificate digest across Android/OEM
versions.

**Binding amendment:** signing preflight resolves the installed base APK with `adb shell pm path`, pulls it to a
`mktemp -d` directory, and compares `apksigner verify --print-certs` digests for installed and candidate APKs. Temporary
content is removed via a trap using the exact validated temporary path. If pull or digest extraction fails, deployment
stops; it never guesses compatibility.

### RF-010 — MEDIUM: the debug POC would otherwise collide with production port/configuration

The debug application ID can coexist with production, but both cannot own `127.0.0.1:8080` and the existing
`apply-config.sh` defaults to the production package/port/tunnel.

**Binding amendment:** POC uses the debug package, loopback port 8081, tunnel disabled, OAuth disabled, a temporary
administrator bearer, and `adb forward`. Production `myconf` is not applied to the debug package. The POC receives a
dedicated helper invocation/config generated in a temporary directory and deleted afterward.

### RF-011 — MEDIUM: initial milestone must be smaller than the full 17-tool surface

Simultaneously adding every operation, UI, deployment automation and two-device rollout makes failures difficult to
attribute.

**Binding amendment and sequence:**

1. prove RF-001 request-scoped client identity;
2. prove RF-002 dependency isolation and a read-only `get_top_window` POC;
3. add protected-package policy plus `list_app_permissions`, permission grant/revoke, force-stop, enable/disable and
   uninstall;
4. add only reviewed settings mutations and standby controls;
5. add UI/persistence;
6. implement/test automation script;
7. run parallel [REDACTED_DEVICE_ALIAS] debug POC;
8. perform owner-signed [REDACTED_DEVICE_ALIAS] cutover, then separately promote [REDACTED_DEVICE_ALIAS].

`clear_app_data`, APK install, quiet capture and arbitrary shell remain deferred until their specific safety contracts
are implemented and reviewed.

### RF-012 — MEDIUM: external controllers may block an otherwise correct deployment

Qustodio, Android Restricted Settings, OEM battery policy and Shizuku state can prevent grants/background operation.

**Binding amendment:** automation reports these as separate `MANUAL_GATE`/`PENDING` results. It MUST NOT bypass or
modify them. A technically successful APK install is not a successful deployment until required manual gates and live
checks pass.

### RF-013 — BLOCKER: the published backend buffers command output without a bound

`droid-mcp` 0.10.1 `ShizukuShellBackend` drains stdout/stderr into unbounded `ByteArrayOutputStream` instances and
exposes one fixed 30-second timeout. An adapter can truncate only after that allocation, which does not protect the
phone process from a command producing unbounded output. The backend also reaches the package-private
`Shizuku.newProcess` API reflectively, so its failure mode must remain isolated and replaceable.

**Binding amendment superseding the dependency wording in RF-002 and User Story 1:** do not ship the
`droid-mcp-shizuku` binary in the first production milestone. Create the isolated module directly against the exact
official Shizuku API/provider dependencies. Port only the reviewed minimal process-launch approach needed for the
backend, with Apache-2.0 source attribution to `stixez/droid-mcp` commit
`6bb968ea551d9de28e41185412391802f0b3bfc6` and its license notice. The application-owned runner MUST bound retained
stdout/stderr while continuing to drain discarded excess, support per-operation timeout, destroy the process on
cancellation/timeout, and expose truncation state. No `droid-mcp-core`, Ktor, MCP server, tool object or global
allowlist is packaged. Future `droid-mcp` changes are reviewed as source/reference updates rather than automatic
Gradle bumps unless a later audited release provides a safe narrow backend artifact.

### Review conclusion

The architecture remains viable only with RF-001, RF-002 and RF-013 proven first. The revised first deliverable is a narrow,
read-only vertical slice using the existing server and administrator bearer, followed by selected typed operations.
The review rejects direct reuse of upstream tool objects, prefix-based arbitrary shell, generic settings writes,
unsafe APK staging, and sync-to-device in one unreviewed command.

### RF-014 — Implementation checkpoint: reviewed blockers are proven, release exposure remains closed

The request-scoped client class passed concurrent bearer/OAuth integration tests without cross-request leakage. The
isolated `:shizuku-admin` runtime dependency report contains only the official Shizuku API/provider, AndroidX
annotation, Kotlin and coroutines; it contains no `droid-mcp`, Ktor or MCP SDK artifact. Bounded-output tests,
top-window parser/readiness tests, app authorization/error/audit tests, ktlint and detekt pass. GMS/FOSS debug and
release APKs all assemble successfully.

The first `admin_get_top_window` registration is intentionally debug-only and still respects the existing per-tool
permission map. OAuth is denied before backend invocation; the primary bearer succeeds in tests. Release registration
remains closed until the master opt-in setting and administrator UI are implemented, so this checkpoint does not
claim production Shizuku readiness.

### RF-015 — Implementation checkpoint: delivery automation is usable but physical canary remains pending

The guarded script now implements the declared command split, literal `--apply`, clean-tree sync/all gates, official
fetch-only upstream verification, review-branch merge behavior, qualified build manifests, explicit ADB identity,
installed-APK pull plus signing comparison, no-uninstall policy, configuration restart, loopback check, live verifier,
rollback manifest requirement and explicit manual-gate output. Eight isolated shell contract tests pass, and both
device configurations share validated non-secret deployment identity fields. [REDACTED_DEVICE_ALIAS] restoration now targets loopback
instead of Wi-Fi exposure.

The [REDACTED_DEVICE_ALIAS] production canary was not installed from this worktree: no [REDACTED_DEVICE_ALIAS] ADB serial is currently available, the debug
port-8081 helper/UI policy are not complete, and signing migration has not received the explicit cutover approval
required by User Story 7. The existing [REDACTED_DEVICE_ALIAS] Cloudflare MCP endpoint still answers an ordinary read-only tool call.
Full app tests completed 2,273 cases with only the two environment-dependent real-tunnel tests initially failing;
ngrok passed after loading the ignored local token, while Cloudflare remains a host prerequisite because the
`cloudflared` executable is absent. These are recorded as environment/manual gates, not silently treated as green.

### RF-016 — [REDACTED_DEVICE_ALIAS] debug uninstall canary prepared; physical access gates confirmed

The debug-only MCP surface now contains `admin_uninstall_app` and
`admin_request_shizuku_permission`. Both require the request-scoped primary administrator bearer; OAuth is rejected
before policy/backend invocation. Uninstall accepts only a syntactically valid package name, uses the fixed
`pm uninstall --user 0 <package>` command vector, requires the Package Manager `Success` result and reports that a
system-partition APK is not modified. The application-owned protected-package policy rejects the MCP package and its
debug variants, Shizuku, Qustodio, System UI, Settings, package installers, the active launcher and active device
administrators before Shizuku is called. The permission tool only requests Shizuku's standard visible dialog; it
does not grant or bypass anything.

`scripts/deploy-[REDACTED_DEVICE_ALIAS]-debug-poc.sh` now provides the missing canary path. It requires an explicit ADB serial and literal
`--apply`, validates Samsung `[REDACTED_OWNER_VALUE]/a34x` plus the debug application ID, installs beside production, configures
bearer-only loopback `127.0.0.1:8081`, disables OAuth/tunnels, starts the foreground server, creates only an ADB
forward and verifies that no wildcard listener exists. It does not alter Qustodio or grant Shizuku. Its three contract
tests and the eight main delivery-script contract tests pass. Focused Shizuku/app unit tests, ktlint, detekt and
`assembleGmsDebug` also pass.

The physical canary remains `PENDING_MANUAL_GATES` on 2026-08-27. Read-only checks found the production Cloudflare MCP
healthy, Qustodio's `Device locked` time-limit overlay active, no [REDACTED_DEVICE_ALIAS] entry in `adb devices`, refusal on the previously
known `[REDACTED_PRIVATE_ENDPOINT]`, and no `moe.shizuku.privileged.api` entry in the installed-app inventory. The earlier
removal list still contains AppCloud, Samsung application recommendations, all three Meta services, Bixby components,
Galaxy Avatar, Samsung Visit In, Samsung Kids Installer, Gaming Hub, Link to Windows, OneDrive, Android Auto, Meet,
Smart Switch, Wearable Manager and optional wallpaper services; `upday` is absent. No uninstall was attempted from the
new implementation because its APK cannot be installed and Shizuku cannot run until the administrator unlocks [REDACTED_DEVICE_ALIAS],
enables/authorizes wireless ADB and restores/starts Shizuku.

### RF-017 — [REDACTED_DEVICE_ALIAS] physical canary completed; live gaps folded back into the implementation

The administrator explicitly authorized a temporary Qustodio maintenance window on 2026-08-27. Wireless ADB was
paired to the verified Samsung `[REDACTED_OWNER_VALUE]/a34x`, official Shizuku v13.6.0 was installed and started as shell, and the
debug application was installed beside production. The canary remained bearer-only on
`[::ffff:127.0.0.1]:8081`; a direct probe to the phone's Wi-Fi address on port 8081 failed, while production remained
separately bound to loopback port 8080 and available through its Cloudflare endpoint.

The physical test exposed three implementation gaps, all fixed in the fork-owned isolation layer or deployment
helper rather than upstream-owned application code:

1. Samsung reports the manufacturer as lowercase `samsung`; the identity gate now normalizes case.
2. Server startup is asynchronous and Android may render an IPv4 loopback listener as IPv6-mapped; the helper now
   performs a bounded 15-second poll and accepts only the normalized loopback form while still rejecting wildcards.
3. The official API dependency does not add `ShizukuProvider` automatically. The provider declaration now lives in
   `:shizuku-admin` with `${applicationId}.shizuku`, keeping it valid for debug/release IDs and isolated from upstream
   manifest conflicts. The Shizuku process check was also changed to avoid a false negative caused by `grep -q` under
   `pipefail`.

The standard visible Shizuku dialog granted the debug package access. `admin_get_top_window` returned the active
window, an unauthenticated local request returned HTTP 401, and the protected-package test rejected Qustodio before
backend invocation. The previously unsuccessful system-app tests then removed AppCloud
(`com.aura.oobe.samsung.gl`), Application recommendations (`com.samsung.android.mapsagent`) and Recommended apps
(`com.samsung.android.app.omcagent`) for Android user 0. Each response reported `removed_for_user=true` and
`system_partition_modified=false`; independent package-manager checks confirmed all three absent while Qustodio,
Shizuku, production MCP and debug MCP remained installed.

After the test, Qustodio's Shizuku rule was restored to `Blocked`, Android Settings protection was restored, and the
Thursday daily limit was restored from the temporary four hours to its original two hours. The debug foreground
server remains running for the current boot on loopback port 8081. Reboot persistence is deliberately not claimed:
on this non-rooted device Shizuku still requires the documented manual startup gate after a reboot. Five canary-script
contract tests and the focused Shizuku unit tests plus `assembleGmsDebug` pass with the provider present in the merged
APK manifest.

### RF-018 — Owner decision: no long-lived canary; deploy the reviewed tools directly to [REDACTED_DEVICE_ALIAS] production

The owner confirmed on 2026-08-27 that this is a small, locally managed project and a separate canary phase would add
process overhead without a useful risk reduction. RF-014–RF-017 remain the historical record of the completed debug
technical proof, but their canary terminology no longer defines the rollout architecture. The debug package on port
8081 is temporary test evidence, not a deployment tier, and MUST be removed after the production acceptance checks
pass.

**Binding amendment superseding the canary and UI promotion requirements in Fixed architecture, User Story 4,
User Story 7, User Story 8.2, RF-014 and RF-015:**

- [REDACTED_DEVICE_ALIAS] is the first and direct production target. There is no required canary environment or promotion step between
  the completed debug proof and [REDACTED_DEVICE_ALIAS] production.
- Register only the three already reviewed typed tools in the production release:
  `admin_get_top_window`, `admin_request_shizuku_permission` and `admin_uninstall_app`. Remove the current
  `BuildConfig.DEBUG` registration condition. Do not add `run_shell`, generic settings mutation, APK installation,
  clear-data or any other broad privileged operation.
- A new master switch and a dedicated administrator settings screen are optional future improvements, not release
  gates for this owner-operated deployment. The existing per-tool `disabledTools` policy remains authoritative.
  Privileged tools still require the primary administrator bearer, reject OAuth before backend invocation, enforce
  the immutable protected-package policy and use the bounded application-owned Shizuku runner.
- Use the existing production MCP service on loopback port 8080 and the existing [REDACTED_DEVICE_ALIAS] Cloudflare tunnel. Do not expose
  port 8081, create another public endpoint or enable direct Wi-Fi access.
- ChatGPT remains connected through OAuth and therefore cannot call privileged tools. Add or repair a separate local
  Codex MCP connection using the synchronized production administrator bearer so the privileged tools can be used by
  the local administrator.
- Preserve all safety gates that still reduce material risk: owner-controlled signing, installed/candidate signature
  comparison, configuration and secret recovery snapshot, explicit approval before any signature-mismatch uninstall,
  restoration of Android/Qustodio/background permissions, Wi-Fi non-exposure, Cloudflare and ordinary-tool checks,
  bearer success, OAuth denial, protected-package rejection, Shizuku binder recovery and screen-off/service-restart
  verification.
- After production passes, stop and uninstall the debug MCP package and remove its ADB port-8081 forward. This cleanup
  does not remove Shizuku and does not alter the production app's data.
- Shizuku startup after a phone reboot remains a documented manual administrator action on this non-rooted device.
  The production MCP service and ordinary tools MUST continue to work while Shizuku is stopped, with privileged tools
  returning a stable unavailable result.
- [REDACTED_DEVICE_ALIAS] is a separate optional later deployment, not part of completing the [REDACTED_DEVICE_ALIAS] production task. It requires its own
  signing and live checks but no [REDACTED_DEVICE_ALIAS] canary terminology or promotion ceremony.

**Revised remaining critical path:**

1. Remove the debug-only registration guard and verify the three typed tools are present in a release build only for
   the primary bearer; rerun focused authorization, protected-package, bounded-runner, lint and release-build tests.
2. Prepare the owner-signed production APK, compare its certificate with the installed production package and choose
   either an in-place update or the already documented explicit one-time migration path.
3. Capture the current [REDACTED_DEVICE_ALIAS] configuration/secrets recovery snapshot, synchronize the production bearer in the app and
   ignored local configuration, and configure the local Codex MCP connection to send that bearer.
4. Deploy directly to the production package, restore required Android/Qustodio/background settings and start the
   existing loopback port-8080 service and Cloudflare tunnel.
5. Run live acceptance: ordinary MCP plus ChatGPT OAuth, privileged bearer calls, OAuth denial, protected-package
   rejection, no Wi-Fi listener, Cloudflare reachability, screen-off/service restart and Shizuku binder stop/start
   recovery. Record reboot-time Shizuku startup as the remaining manual operational procedure.
6. When every production gate is green, remove the debug package/port-8081 forward and update the final device and
   maintenance documentation. Keep [REDACTED_DEVICE_ALIAS] explicitly `PENDING` unless separately requested.

### RF-019 — Independent consistency review of the direct-production path

An independent read-only review challenged RF-018 against the current signing configuration, deployment scripts,
device snapshot, Codex configuration and live-verification coverage. The direct [REDACTED_DEVICE_ALIAS] production decision remains
appropriate, but the following amendments are required before it can be reported `READY`.

#### Signing, state loss and rollback boundaries

- Commit this reviewed plan amendment separately, then keep implementation/documentation in a small follow-up commit.
  Production deployment requires a clean `main` and records the exact source SHA; a dirty-tree version is not eligible.
- Before changing the installed production package, prepare the owner keystore outside Git and an owner-signed
  `gmsRelease`, extract the installed APK certificate, and archive the known-good installed APK with its SHA-256 and
  certificate digest. Do not expose keystore paths, aliases or passwords in logs or tracked files.
- Distinguish rollback before signing migration from rollback after it. Before migration, the installed upstream-signed
  app can only accept the same signing identity. After migration, rollback MUST use an owner-signed earlier artifact.
  Returning to the upstream-signed APK after a manual uninstall would require another uninstall and another data loss;
  it is not a transparent rollback.
- A signature-mismatch migration requires a separate explicit owner confirmation immediately before uninstall. The
  confirmation states that app DataStore and package-owned data will be irreversibly removed. The automation remains
  forbidden from running that uninstall.
- `myconf/[REDACTED_DEVICE_ALIAS]/android/apply-config.sh` does not preserve the OAuth JWT secret, DCR client/token registry, SAF grants,
  Restricted Settings, accessibility, notification access or the package-specific Shizuku grant. After a destructive
  signing migration, explicitly repeat ChatGPT connector authorization/registration as needed and restore every Android,
  Shizuku, Qustodio, battery/background and SAF permission before acceptance. A JSON snapshot alone is insufficient.

#### Credentials and client separation

- The production bearer is currently a known failed precondition: the ignored local snapshot was rejected with HTTP
  401 and the existing `android_[REDACTED_DEVICE_ALIAS]` Codex entry uses OAuth. Synchronize one newly generated or verified bearer between
  the ignored secret file and production app before cutover, then prove it locally through ADB forwarding and through
  Cloudflare without printing it.
- Preserve `android_[REDACTED_DEVICE_ALIAS]` as the ordinary OAuth connection. Add a separate `android_[REDACTED_DEVICE_ALIAS]_admin` Codex MCP entry whose
  bearer is read from a dedicated environment variable supported by Codex configuration; never place the bearer value
  in `config.toml`. Restart/reload Codex and prove that the administrator connection succeeds while OAuth remains denied
  for the privileged handlers.

#### Verification and fail-closed release surface

- Removing the master opt-in is an explicit owner choice for exactly these three hard-coded handlers. Because an empty
  `disabledTools` set enables newly registered tools, add a release regression asserting that the privileged registration
  surface contains exactly `admin_get_top_window`, `admin_request_shizuku_permission` and `admin_uninstall_app`, and no
  generic or future privileged operation. Per-tool `disabledTools` must still remove each handler when configured.
- Apply the RF-017 IPv4/IPv6-mapped loopback normalization to the main production deployment verifier. Also perform an
  actual bounded connection attempt to port 8080 through the device Wi-Fi address; checking only for wildcard listeners
  does not prove Wi-Fi non-exposure.
- `myconf/[REDACTED_DEVICE_ALIAS]/scripts/verify.sh --live` currently proves only endpoint status/discovery, not authenticated ordinary or
  privileged tool behavior. Extend it or add a separate acceptance helper. It MUST NOT emit `READY` until it has recorded:
  bearer success, ordinary OAuth/ChatGPT success, OAuth denial for an admin tool, top-window success, protected-package
  rejection before backend, Cloudflare reachability, Wi-Fi non-exposure, Shizuku binder stop/start recovery,
  screen-off survival and MCP service restart. Manual observations may be recorded explicitly, but may not be inferred.
- When Shizuku is stopped, the production MCP server and ordinary tools must stay operational. On reboot, temporarily
  change the Qustodio Shizuku rule to `Allow`, start Shizuku through its documented user-visible flow, confirm the MCP
  package grant, restore the rule to `Blocked`, and verify that restoring the rule does not kill the already running
  Shizuku service or revoke production MCP access.

#### Documentation and debug cleanup

- Before deployment, update `README.md`, `docs/PROJECT.md` and `myconf/[REDACTED_DEVICE_ALIAS]/README.md` so they no longer describe the UI,
  master opt-in or a release-disabled Shizuku surface as current requirements. Preserve `shizuku-canary.md` as a clearly
  labelled historical debug proof until cleanup is complete; do not present it as the production runbook.
- After production is `READY`, clean up with explicit ADB operations: force-stop and uninstall
  `com.danielealbano.androidremotecontrolmcp.gms.debug`, remove host forward `tcp:8081`, and verify both the package and
  listener are absent. Do not attempt this through `admin_uninstall_app`, whose protected-package policy correctly blocks
  all MCP variants.

**Revised execution order:** commit RF-018/RF-019; enable the exact release surface and its regression; repair production
loopback/acceptance checks; prepare signing and rollback artifacts; synchronize bearer and configure the separate Codex
administrator connection; capture state and obtain any required migration confirmation; deploy/re-onboard; pass the full
production acceptance; remove the debug package and finalize documentation. Lack of an authorized [REDACTED_DEVICE_ALIAS] ADB connection
blocks only physical signing/deployment/acceptance work, not the local implementation and automated test phases.

### RF-020 — Direct-production implementation checkpoint and live preflight

RF-018/RF-019 were committed separately as `ba8b9ba`. The follow-up implementation removes the `BuildConfig.DEBUG`
registration gate, centralizes a closed set of exactly three reviewed handlers and adds a regression proving both the
exact surface and individual `disabledTools` removal. `run_shell`, generic settings, clear-data and APK installation
remain absent. `ktlintCheck`, `detekt`, focused app/Shizuku tests and `assembleGmsRelease` pass. The full GMS debug suite
completed 2,279 tests with only the existing environment-dependent ngrok and Cloudflare real-tunnel tests failing.

The independent-review delivery findings were also implemented: the production listener verifier accepts Android's
IPv6-mapped loopback form, rejects wildcard binding and performs a bounded Wi-Fi TCP connection attempt; nine shell
contract tests pass. Device restoration now uses the application's actual `disabledTools`/`disabledParams` JSON names
and quotes empty/JSON values through the second ADB shell, preventing silent argument shifting.

Live [REDACTED_DEVICE_ALIAS] preflight used the explicit `[REDACTED_PRIVATE_ENDPOINT]` serial and confirmed Samsung `[REDACTED_OWNER_VALUE]/a34x`. The currently
installed upstream-signed APK was archived below ignored `build/rollback/[REDACTED_DEVICE_ALIAS]/` with SHA-256 and certificate metadata.
Its certificate does not establish an owner signing path. The local bearer was reapplied without printing it;
authenticated MCP initialize, tools/list and `android_get_screen_state` now succeed locally and through Cloudflare,
while unauthenticated access remains HTTP 401.

The live configuration test exposed two pre-existing restoration bugs. A spaced `--edge` value was truncated by the
ADB remote shell and, once quoted correctly, the installed app appended it after `tunnel run`, causing cloudflared to
show help and exit with code 0. The configuration no longer uses that broken workaround. On [REDACTED_DEVICE_ALIAS], the embedded Go
resolver also cannot establish a fresh tunnel while Private DNS presents an unavailable `[::1]:53`; restart now uses
system DNS only for bounded tunnel startup and restores `family.adguard-dns.com` on success or error. The repaired
workflow was tested live: the tunnel reconnected, Private DNS was restored, public unauthenticated access returned 401
and the synchronized bearer returned 405 for an authenticated GET. `verify.sh --live` passes.

A reproducible `--admin-smoke` gate now exercises MCP initialize, exact privileged tools/list, an ordinary call,
`admin_get_top_window` and protected Qustodio uninstall rejection without logging credentials. Against the still-old
production package it intentionally fails with `unexpected privileged tool surface (0 tools)`: the server currently
exposes 57 ordinary tools and must not be marked production-Shizuku ready before the new APK is installed.

The remaining hard blocker is signing, not implementation. `keystore.properties` is absent, so Gradle produced
`app-gms-release-unsigned.apk`; it MUST NOT be deployed. Completion still requires an owner-controlled keystore and
recovery decision, signed clean-SHA artifact, installed/candidate certificate comparison, explicit data-loss approval
if the signatures differ, production install/re-onboarding, full automatic/manual acceptance and only then ADB cleanup
of the debug package and forward 8081. The separate `android_[REDACTED_DEVICE_ALIAS]_admin` Codex entry is configured to read
`ANDROID_[REDACTED_DEVICE_ALIAS]_ADMIN_BEARER_TOKEN`, but the Codex process must be restarted from an environment containing that variable
before its live administrator call can be verified.
