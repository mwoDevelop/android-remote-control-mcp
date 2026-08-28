<!-- SACRED DOCUMENT — DO NOT MODIFY except for checkmarks ([ ] → [x]) and review findings. -->
<!-- You MUST NEVER alter, revert, or delete files outside the scope of this plan. -->
<!-- Plans in docs/plans/ are PERMANENT artifacts. There are ZERO exceptions. -->

# Plan 67 — Secure [REDACTED_DEVICE_ALIAS] remote unlock without disclosing the PIN

Add one narrowly scoped remote-unlock capability to the existing Android Remote Control MCP fork for Samsung Galaxy
A34 5G (`[REDACTED_DEVICE_ALIAS]`). The configured PIN remains local to the owner and the phone. ChatGPT calls a zero-argument MCP action
through the existing OAuth connection and Cloudflare tunnel; neither ChatGPT nor Cloudflare receives the PIN.

This plan extends the reviewed Shizuku boundary from Plan 66. It does not create another server, endpoint or tunnel,
does not expose a generic shell, and does not weaken the Android lock screen. Secure-screen input feasibility on the
actual [REDACTED_DEVICE_ALIAS] is a blocking spike: if Android rejects typed Shizuku input on the secure keyguard, implementation stops
with the tool disabled.

## Current-state finding

At plan creation time, `myconf/[REDACTED_DEVICE_ALIAS]/.env.secrets` had mode `0600`, but it did not contain a parseable `[REDACTED_DEVICE_ALIAS]_PIN=...`
assignment. Before provisioning, validate that the owner has saved the value using shell assignment syntax without
printing it. The value MUST NOT be requested in chat, copied into an issue, or displayed by validation scripts.

## Fixed security and architecture decisions

- The only public MCP endpoint remains `[REDACTED_OWNER_VALUE]` over the existing Cloudflare tunnel.
- Cloudflare configuration, DNS, tunnel token and ingress rules do not need a PIN and MUST NOT receive one.
- The MCP operation is named `admin_unlock_device`, has an empty input schema, and returns only a bounded status such as
  `unlocked`, `already_unlocked`, `disabled`, `not_configured`, `temporarily_blocked`, or `unavailable`.
- The PIN MUST NOT appear in an MCP argument/result, tool description, OAuth token/claim, URL, HTTP header, Cloudflare
  configuration, tracked JSON, Git history, Android log, server log, crash report, screenshot, test fixture, process
  argument vector, shell trace, Gradle property, environment exported to child processes, or ordinary DataStore value.
- `myconf/[REDACTED_DEVICE_ALIAS]/.env.secrets` is only an ignored owner-side provisioning source. It is not the application's runtime
  credential store. The file MUST remain owner-readable only (`0600`) and MUST NOT be committed.
- The app generates a device-bound, non-exportable Android Keystore key. Only ciphertext and non-secret key metadata
  are persisted in app-private, credential-encrypted storage and excluded from backup.
- Background decryption while the screen is locked requires a Keystore key that does not demand per-use user
  authentication. This protects against offline key extraction, but code executing as the app can request decryption;
  that residual risk MUST be documented in the administrator UI.
- Unlock before the first manual unlock after a reboot is OUT OF SCOPE. The app fails closed until Android
  credential-encrypted storage is available, the MCP service is running, and Shizuku is ready.
- Shizuku must inject typed key events through a typed backend API. The implementation MUST NOT execute
  `input text <PIN>`, construct a shell command containing the PIN, or pass it through process arguments.
- No root, Magisk, Sui, bootloader change, lockscreen removal, PIN change, credential verification command, Qustodio
  bypass, notification automation, or arbitrary `run_shell` is permitted.
- The existing administrator bearer remains authorized for all reviewed admin tools. OAuth remains denied for every
  privileged tool except `admin_unlock_device`, and that exception is limited to exact, explicitly configured OAuth
  client IDs.
- OAuth client display names, redirect URIs, ChatGPT plugin IDs and external connector IDs are not authorization
  identities. Authorization uses the server-issued `arc-...` client ID from a verified access-token claim and the live
  OAuth client registry.
- Remote unlock is default-off. An administrator must both provision a credential and explicitly enable the exact
  OAuth client policy. Revoking the OAuth client, clearing the credential, reinstalling the app, invalidating the
  Keystore key, or disabling the policy fails closed.
- Calls are serialized. A failed attempt that leaves the device locked disables further remote-unlock attempts until
  a local administrator or DUMP-gated ADB provisioning action rearms the feature. This avoids repeated attempts with a
  stale credential and Android lockout escalation.
- The real owner PIN MUST NOT be deliberately replaced with an incorrect value for live testing.
- [REDACTED_DEVICE_ALIAS] is the only deployment target in this plan. [REDACTED_DEVICE_ALIAS] is explicitly OUT OF SCOPE.

## Threat model

| Threat | Required control |
|---|---|
| Git or backup disclosure | Ignore plaintext source; persist only device-bound ciphertext; exclude it from backup |
| ChatGPT prompt injection | Tool has no PIN parameter; exact-client policy; normal tool confirmation/write controls remain enabled |
| Stolen OAuth token | Exact live client registry, revocation, dedicated tool allowlist, local enable switch, single-failure rearm |
| Cloudflare/log observation | No PIN crosses HTTP; redact credential operations and prohibit secret-bearing log fields |
| Local process inspection | No PIN in argv or exported environment; provisioning passes plaintext only over a private stdin pipe |
| Compromised ARCP process | Keystore limits extraction but cannot prevent authorized in-process decrypt; document residual risk |
| Repeated stale-PIN attempts | One in-flight call, cooldown, verify final keyguard state, disable on failure |
| Upstream merge conflict | Isolated credential/backend packages and one narrow extension to existing auth/request context |

## Scope boundary

Implementation may modify only these paths, plus this permanent plan:

- `docs/plans/67_secure_[REDACTED_DEVICE_ALIAS]_remote_unlock_20260828185020.md`
- `README.md`, `docs/ARCHITECTURE.md`, `docs/MCP_TOOLS.md`, `docs/PERMISSIONS.md`
- `app/src/main/AndroidManifest.xml` and backup/data-extraction rules under `app/src/main/res/xml/**`
- `app/src/main/kotlin/com/danielealbano/androidremotecontrolmcp/mcp/auth/**`
- `app/src/main/kotlin/com/danielealbano/androidremotecontrolmcp/mcp/oauth/OAuthAccessValidator.kt`
- `app/src/main/kotlin/com/danielealbano/androidremotecontrolmcp/mcp/McpStatelessTransport.kt`
- `app/src/main/kotlin/com/danielealbano/androidremotecontrolmcp/mcp/shizuku/**`
- `app/src/main/kotlin/com/danielealbano/androidremotecontrolmcp/security/remoteunlock/**` (new, isolated)
- `app/src/main/kotlin/com/danielealbano/androidremotecontrolmcp/services/mcp/AdbConfigHandler.kt`
- `app/src/main/kotlin/com/danielealbano/androidremotecontrolmcp/services/mcp/AdbConfigReceiver.kt`
- `app/src/main/kotlin/com/danielealbano/androidremotecontrolmcp/services/mcp/McpServerService.kt`
- `app/src/main/kotlin/com/danielealbano/androidremotecontrolmcp/ui/**` only for administrator credential/policy status
- `app/src/main/res/values/strings.xml`
- `shizuku-admin/src/main/kotlin/com/mwodevelop/androidremotecontrol/shizukuadmin/**`
- corresponding tests under `app/src/test/**`, `shizuku-admin/src/test/**`, and `e2e-tests/src/test/**`
- `myconf/[REDACTED_DEVICE_ALIAS]/.env.example`
- `myconf/[REDACTED_DEVICE_ALIAS]/README.md`
- `myconf/[REDACTED_DEVICE_ALIAS]/android/config.json` only for non-secret per-client authorization policy
- `myconf/[REDACTED_DEVICE_ALIAS]/android/provision-unlock-pin.sh` (new)
- `myconf/[REDACTED_DEVICE_ALIAS]/scripts/verify.sh`
- `scripts/sync-build-deploy.sh` only if a new [REDACTED_DEVICE_ALIAS] post-deploy gate is required
- shell contract tests under `scripts/tests/**`

Explicitly OUT OF SCOPE:

- changing `.env.secrets` contents or committing any secret;
- changing Cloudflare, Regery, ngrok, ChatGPT plugin registration or the public hostname;
- granting unlock to all OAuth clients or authorizing by mutable client name;
- adding a raw PIN field to existing ADB `CONFIG_ARGS`;
- generic key injection, arbitrary Shizuku command execution, PIN discovery, PIN rotation or lockscreen removal;
- deployment to [REDACTED_DEVICE_ALIAS] or resetting/uninstalling the [REDACTED_DEVICE_ALIAS] production app.

**Plan handling:** commit this document alone as `docs(plans): add plan 67`. Creating the plan does not authorize its
implementation or deployment.

---

## User Story 1 — Prove secure-lockscreen feasibility before storing a credential

**Why:** Samsung/Android may reject injected events on a secure keyguard. Credential work must not proceed until the
typed mechanism is proven without putting a PIN in a shell command.

### Task 1.1 — Add a non-secret typed input spike

- [x] Extend `PrivilegedAdminBackend` with an internal typed key-event operation that accepts only digit key codes and
  a final Enter action; do not expose a public generic key-event MCP tool.
- [x] Implement event injection directly through the Shizuku-privileged Android input service/API. No child process may
  contain entered digits in its command or arguments.
- [x] Bound the sequence length, timeout and accepted key-code set. Reject all non-digit text and metacharacters.
- [x] Keep the spike unreachable from production MCP registration.
- [ ] Unit-test validation, timeout, binder failure and cancellation.

### Task 1.2 — Live [REDACTED_DEVICE_ALIAS] feasibility gate

- [x] Use a temporary in-memory test sequence supplied locally by the administrator; do not persist or log it.
- [ ] Verify wake/display transition and digit entry on the actual Samsung secure PIN screen with screen on and screen
  off/dozing.
- [x] Verify the final state through `KeyguardManager`, not by assuming successful input means unlock.
- [ ] Inspect `logcat`, ARCP server logs and Shizuku process arguments for the test digits without printing them in the
  test report; record only pass/fail.
- [ ] If secure keyguard rejects direct typed input, STOP: keep the production tool absent and document the unsupported
  platform result. Accessibility typing, `input text`, root and lockscreen weakening are not fallbacks.

**Acceptance gate:** typed Shizuku events unlock the real [REDACTED_DEVICE_ALIAS] without a secret in any process argument or log. This is
a hard prerequisite for all later user stories.

---

## User Story 2 — Device-bound encrypted credential store

**Why:** A recoverable PIN cannot be hashed; it must be encrypted with a key unavailable outside the device/app trust
boundary.

### Task 2.1 — Define a narrow credential-store contract

- [ ] Add `RemoteUnlockCredentialStore` with only `publicProvisioningKey()`, `installCiphertext(...)`,
  `withDecryptedPin(...)`, `clear()`, and non-secret status methods.
- [ ] Represent a decrypted PIN as a mutable `CharArray`/`ByteArray`, never an immutable `String` where avoidable.
- [ ] Zero decrypted buffers in `finally`, including backend error and coroutine cancellation paths.
- [ ] Define stable states: `NotConfigured`, `Ready`, `StorageLocked`, `KeyInvalidated`, `CorruptCiphertext`, and
  `Unsupported`.

### Task 2.2 — Android Keystore implementation

- [ ] Generate a device-bound RSA-OAEP provisioning key in Android Keystore with a versioned alias and non-exportable
  private key. Prefer hardware-backed/StrongBox when available, with an explicitly logged non-secret security-level
  status and a compatible fallback.
- [ ] Store only randomized OAEP ciphertext, key version and integrity metadata in a dedicated app-private file. Do not
  use ordinary Settings/DataStore keys for the PIN or decrypted value.
- [ ] Exclude the credential file from Android backup/data extraction. Restored/mismatched ciphertext fails closed.
- [ ] Do not enable Direct Boot storage. Before first user unlock after reboot, return `StorageLocked`.
- [ ] Treat Keystore invalidation or app reinstall as `NotConfigured`; never fall back to plaintext.
- [ ] Add tests using a fake crypto provider for round-trip, corrupted ciphertext, wrong key, invalidation, cancellation,
  buffer zeroing and backup exclusion.

### Task 2.3 — Local administrator status and clearing

- [ ] Show only configured/not-configured, key security level, remote policy state and last non-secret outcome.
- [ ] Add an explicit local action to clear ciphertext and disable remote unlock.
- [ ] Never render, copy, reveal or export the PIN after provisioning.

**Acceptance gate:** a storage dump contains no plaintext PIN, backup excludes the ciphertext, and reinstall/key
invalidation requires provisioning again.

---

## User Story 3 — Safe owner-side provisioning from `.env.secrets`

**Why:** The existing [REDACTED_DEVICE_ALIAS] configuration broadcasts bearer/tunnel values as arguments. That pattern is not acceptable
for a lockscreen credential.

### Task 3.1 — DUMP-gated public-key endpoint

- [ ] Add a narrowly typed ADB action protected by `android.permission.DUMP` that returns only the device public key,
  key version and credential status.
- [ ] Add a second DUMP-gated action that accepts only bounded base64 ciphertext plus matching key version.
- [ ] Reject malformed, oversized, stale-key and replayed provisioning envelopes before changing current state.
- [ ] Installing new ciphertext automatically disables/rearms the OAuth unlock policy until explicitly enabled.
- [ ] Receiver logs say only `remote unlock credential provisioned/cleared`; no lengths that reveal PIN format.

### Task 3.2 — `provision-unlock-pin.sh`

- [ ] Create a separate script; do not append PIN handling to the ordinary `apply-config.sh` `CONFIG_ARGS` array.
- [ ] Require an unambiguous ADB serial and validate Samsung model/device identity before mutation.
- [ ] Require `.env.secrets` to be a regular owner-owned file with mode `0600`, source it with xtrace disabled, and
  validate `[REDACTED_DEVICE_ALIAS]_PIN` without echoing value or length.
- [ ] Keep `[REDACTED_DEVICE_ALIAS]_PIN` as a non-exported shell variable. Feed it to a pinned/audited encryption helper over stdin; only
  ciphertext may be passed to `adb shell am broadcast` arguments.
- [ ] Clear the shell variable after encryption and prevent core dumps/temporary plaintext files.
- [ ] Support explicit `--status`, `--provision`, and `--clear`; mutation requires an explicit flag.
- [ ] Add shell tests with fake ADB proving device mismatch refusal, mode refusal, missing/empty secret refusal, no
  plaintext in argv/stdout/stderr, and ciphertext-only broadcast.
- [ ] Add `[REDACTED_DEVICE_ALIAS]_PIN=` to `.env.example` with warnings, never a sample real-looking PIN.

### Task 3.3 — Configuration and recovery documentation

- [ ] Document correct assignment syntax, provisioning, clearing, reinstall/key-loss recovery and how to rotate without
  disclosing the value.
- [ ] Record only non-secret policy/key-version metadata in `myconf/[REDACTED_DEVICE_ALIAS]`; no ciphertext is required in Git.
- [ ] Ensure repository secret scans reject `[REDACTED_DEVICE_ALIAS]_PIN` with a non-empty tracked value.

**Acceptance gate:** provisioning can be repeated from the ignored owner file, but neither host process arguments nor
tracked files contain plaintext.

---

## User Story 4 — Authenticated OAuth principal and exact ChatGPT authorization

**Why:** The current request context carries only `STATIC_BEARER` versus `OAUTH`. It cannot distinguish the approved
ChatGPT DCR client from another valid OAuth client.

### Task 4.1 — Propagate verified OAuth identity

- [ ] Replace the boolean-only OAuth validation result with a non-secret authenticated principal containing the client
  class and verified server-issued OAuth `clientId` from the signed access-token claims.
- [ ] Populate the principal only after signature/type/audience validation and confirmation that the client still
  exists in `OAuthClientRepository`.
- [ ] Carry the principal from the Ktor auth phase into the MCP request coroutine without exposing the token.
- [ ] Preserve current `STATIC_BEARER`, `OPEN`, `EXCLUDED` and `UNKNOWN` behavior and fail closed if context is absent.
- [ ] Add unit/integration tests for bearer, OAuth client A, OAuth client B, revoked client, invalid audience, invalid
  token and missing context.

### Task 4.2 — Per-client privileged policy

- [ ] Add a non-secret policy model mapping exact `arc-...` client IDs to an explicit privileged-tool set. The initial
  and maximum OAuth set is `{admin_unlock_device}`.
- [ ] Reject client names, redirect URIs, plugin IDs, connector IDs and wildcards as policy identifiers.
- [ ] Restore the policy through the existing DUMP-gated ADB configuration using tracked `config.json`; validate that
  each client ID is syntactically valid and exists in the restored OAuth registry.
- [ ] Configure only the [REDACTED_DEVICE_ALIAS] ChatGPT server-issued client ID for `admin_unlock_device`.
- [ ] Keep `admin_get_top_window`, `admin_request_shizuku_permission`, `admin_uninstall_app` and all future privileged
  tools OAuth-denied.
- [ ] Removing/revoking the OAuth client immediately removes unlock authorization.

### Task 4.3 — Authorizer regression suite

| Caller | `admin_unlock_device` | Other privileged tools |
|---|---:|---:|
| Administrator static bearer | allow when feature policy is enabled | unchanged: allow |
| Exact configured ChatGPT OAuth client | allow when feature policy is enabled | deny |
| Any other/re-registered OAuth client | deny | deny |
| Revoked, invalid, absent or unknown principal | deny | deny |

- [ ] Prove denial happens before credential decryption and before Shizuku backend invocation.
- [ ] Prove audit output contains client class and a safe stable client fingerprint, not tokens or PIN data.
- [ ] Consider a dedicated OAuth scope only if ChatGPT compatibility is proven; exact client policy remains mandatory
  and MUST NOT be replaced by a broad `mcp` scope check.

**Acceptance gate:** one restored ChatGPT `arc-...` identity can reach only the unlock handler, while all other OAuth
clients remain outside the privileged boundary.

---

## User Story 5 — Zero-argument remote unlock operation

### Task 5.1 — Typed orchestration and fail-closed state machine

- [ ] Add `admin_unlock_device` with an empty schema and no optional secret/input fields.
- [ ] Check, in order: authenticated policy, feature enabled, cooldown/rearm state, credential ready, Shizuku ready,
  keyguard locked. Return `already_unlocked` without decrypting when appropriate.
- [ ] Serialize calls with a mutex and reject concurrent calls.
- [ ] Wake the display, present the PIN surface using fixed bounded navigation if required, decrypt only immediately
  before typed injection, inject digits plus Enter, then zero the buffer.
- [ ] Verify final state with `KeyguardManager` after a bounded wait; do not infer success from command completion.
- [ ] If still locked, record a safe failure and disable further attempts until local/ADB rearm.
- [ ] Never return distinctions that reveal PIN correctness beyond a generic `unlock_failed_rearm_required`.

### Task 5.2 — Operational controls

- [ ] Default the feature to disabled even when a credential exists.
- [ ] Provide administrator-only enable/disable/rearm controls and clearly show the authorized OAuth client fingerprint.
- [ ] Disable automatically on credential replacement/clear, key invalidation, OAuth client removal and app data reset.
- [ ] Preserve enable state across ordinary service restart only after a security review; always require revalidation
  after app reinstall. Document the final decision.
- [ ] Keep the existing visible tool-call indicator and ChatGPT write-action confirmation behavior enabled.

### Task 5.3 — Logging and privacy

- [ ] Audit timestamp, safe client identity, outcome, duration and whether rearm is required.
- [ ] Do not log arguments, digit count, keypad events, ciphertext, public key, PIN, UI dump or lockscreen screenshot.
- [ ] Add a regression that plants a unique fake secret and scans captured app/server logs and process arguments for it.

**Acceptance gate:** the tool never accepts or emits credential material, verifies actual unlock state, and one failed
attempt cannot create an unattended retry loop.

---

## User Story 6 — Automated, integration and live acceptance tests

### Task 6.1 — Host and JVM quality gates

- [ ] Run formatting, lint, detekt, app unit tests, Shizuku module tests and GMS release assembly.
- [ ] Run existing authentication, OAuth, privileged-tool exact-surface, protected-package and service-survivability
  regressions unchanged.
- [ ] Add tests that `SHIZUKU_ADMIN_TOOL_NAMES` expands by exactly `admin_unlock_device` and no generic input/shell tool.
- [ ] Add tests for disabled tool policy and per-client policy restoration/validation.
- [ ] Run repository secret scan and shell contract tests.

### Task 6.2 — [REDACTED_DEVICE_ALIAS] deployment preflight

- [ ] Require a clean reviewed source SHA and owner-signed GMS release.
- [ ] Compare installed/candidate signing certificates and use only `adb install -r`; signature mismatch, uninstall and
  data reset are hard stops.
- [ ] Archive the currently installed owner-signed APK and configuration recovery metadata without secrets.
- [ ] Deploy only to the validated Samsung [REDACTED_DEVICE_ALIAS] serial using the existing guarded workflow.
- [ ] Reapply ordinary configuration, verify loopback binding and tunnel health, then provision the PIN separately.

### Task 6.3 — Live acceptance matrix

| Scenario | Expected result |
|---|---|
| Unauthenticated public MCP | HTTP 401 |
| Ordinary ChatGPT OAuth tool | unchanged success |
| Approved ChatGPT client, feature disabled | unlock denied before decrypt |
| Approved ChatGPT client, screen already unlocked | `already_unlocked`, no decrypt/input |
| Approved ChatGPT client, screen on and PIN-locked | unlock succeeds |
| Approved ChatGPT client, screen off/dozing | wakes and unlocks within bound |
| Different/re-registered OAuth client | denied before decrypt/backend |
| Approved OAuth client calling other admin tool | denied |
| Administrator bearer calling existing admin tools | unchanged success |
| Shizuku stopped | stable unavailable; MCP/tunnel/ordinary tools stay alive |
| First boot before manual unlock | fail closed; no Direct Boot credential access |
| Service/tunnel restart after first unlock | policy behavior remains documented and deterministic |
| Wi-Fi address port 8080 | connection refused; loopback-only preserved |

- [ ] Perform no intentional wrong-PIN live test. Mocked tests cover stale/incorrect credential behavior.
- [ ] Scan device logs and running process arguments for the owner PIN locally without writing the searched value to
  report output or shell history; record only pass/fail.
- [ ] Exercise OAuth revocation and prove immediate denial.
- [ ] Rescan/reconnect the private ChatGPT connector if its cached tool schema does not include the new action.

### Task 6.4 — Rollback

- [ ] Roll back with the archived owner-signed APK using `adb install -r`; never uninstall or clear app data.
- [ ] Disable the OAuth policy and clear the encrypted credential before rollback if the older app cannot interpret the
  new state safely.
- [ ] Verify ordinary MCP, Cloudflare and ChatGPT OAuth remain operational after rollback.

**Acceptance gate:** all automated gates pass and the approved ChatGPT session unlocks the real [REDACTED_DEVICE_ALIAS] through Cloudflare
without the PIN entering network traffic, logs or process arguments.

---

## User Story 7 — Documentation, upstream maintainability and completion

### Task 7.1 — Documentation

- [ ] Document provisioning, enable/disable/rearm, OAuth-client rotation, Shizuku/reboot limitations, key invalidation,
  app reinstall recovery, rollback and residual app-compromise risk.
- [ ] Clearly state that Cloudflare does not store or require the PIN and ChatGPT never receives it.
- [ ] Update MCP tool documentation with the empty schema, authorization matrix and stable non-secret results.
- [ ] Update [REDACTED_DEVICE_ALIAS] verification documentation and snapshot only with non-secret state.

### Task 7.2 — Upstream-conflict review

- [ ] Keep crypto/storage under the new isolated `security/remoteunlock` package and typed input inside
  `shizuku-admin`; do not modify unrelated upstream UI/tool implementations.
- [ ] Restrict existing auth changes to a generalized authenticated-principal seam reusable by future policies.
- [ ] Verify an upstream merge can resolve through the single auth-context and tool-registration seams without moving
  owner configuration into upstream-owned code.
- [ ] Add no fork-specific secret or [REDACTED_DEVICE_ALIAS] hostname to reusable production classes.

### Task 7.3 — Definition of Done

- [x] Feasibility passed on the real secure Samsung keyguard without shell argv secrets.
- [ ] Device-bound encryption, backup exclusion and provisioning tests passed.
- [ ] Exact ChatGPT OAuth client authorization and all negative authorization tests passed.
- [ ] Owner-signed [REDACTED_DEVICE_ALIAS] deployment and complete live matrix passed.
- [ ] No PIN or secret-bearing artifact exists in Git, logs, reports, process arguments or Cloudflare configuration.
- [ ] Documentation and rollback procedure are complete.
- [ ] Final source SHA, APK hash, version and non-secret test outcomes are recorded.

## Stop conditions

Implementation MUST stop and leave `admin_unlock_device` unregistered if any of these occurs:

- secure keyguard rejects direct typed Shizuku input;
- the only working mechanism places the PIN in a shell command, argv, accessibility text action, log or MCP payload;
- the OAuth request context cannot reliably carry a verified exact client ID;
- Keystore decryption requires weakening the lockscreen or storing plaintext for background availability;
- deployment would require uninstall, app-data reset, signature bypass, root or Qustodio bypass;
- tests detect PIN material outside the bounded in-memory decrypt/inject operation.

---

## Independent review findings and normative amendments — 2026-08-28

An independent read-only review challenged this plan against the current OAuth registry/restore behavior, shell
scripts, Shizuku backend and MCP tool-registration path. The original plan is not implementation-ready without the
following amendments. These findings are normative and supersede conflicting wording above.

### RF-001 — CRITICAL: revoked OAuth clients can currently be restored

`myconf/[REDACTED_DEVICE_ALIAS]/android/apply-config.sh` restores tracked OAuth registrations on every apply. The current repository
restore operation can recreate a deleted `arc-...` entry; an old access token becomes valid again if its signing state
is still valid and the same client ID reappears. Therefore, live-registry membership alone does not make revocation
durable.

Required amendment:

- OAuth revocation/eviction records a durable tombstone or monotonically increasing registration generation.
- A normal configuration apply MUST NOT resurrect a tombstoned client ID.
- Revocation atomically removes the client's privileged policy and active arm/latch state.
- Reconnecting after revocation uses a newly generated `arc-...` ID and requires an explicit policy update and arm.
- Add a regression proving an old token remains denied after revoke, MCP restart and repeated `apply-config`.
- An application data reset also deletes the unlock credential and policy, so a restored registration after a reset
  cannot unlock until the complete credential/policy/arm onboarding is repeated.

Implementation scope is expanded to the OAuth repository/model and revocation paths under
`app/src/main/kotlin/com/danielealbano/androidremotecontrolmcp/data/repository/**` and their tests, but only for durable
revocation and the exact-client unlock policy.

### RF-002 — CRITICAL: existing scripts would export `[REDACTED_DEVICE_ALIAS]_PIN` to child processes

`myconf/[REDACTED_DEVICE_ALIAS]/scripts/verify.sh` uses `set -a; source .env.secrets`, and the deployment script has generic secret-file
loading behavior. Once `[REDACTED_DEVICE_ALIAS]_PIN` is present, an unrelated Node/Gradle/ADB child could inherit it even if the new
provisioning script is correct.

Required amendment:

- Never `source` the PIN file in provisioning. Parse only an exact, single `[REDACTED_DEVICE_ALIAS]_PIN=...` assignment as data, rejecting
  duplicate, malformed, command-substitution, multiline and non-digit values.
- The accepted PIN format is 4–16 ASCII digits; validation output MUST NOT reveal value or length.
- Existing verification/deployment scripts selectively load/export only variables they require and explicitly remove
  `[REDACTED_DEVICE_ALIAS]_PIN` from every child environment.
- Add fake-child tests that inspect their environment and fail if `[REDACTED_DEVICE_ALIAS]_PIN` is inherited.
- `scripts/sync-build-deploy.sh`, `myconf/[REDACTED_DEVICE_ALIAS]/scripts/verify.sh` and
  `myconf/[REDACTED_DEVICE_ALIAS]/android/apply-config.sh` are unconditionally in scope for this remediation, not only for a
  post-deploy gate. None of them may execute the secrets file as shell code or export `[REDACTED_DEVICE_ALIAS]_PIN` to children.

### RF-003 — CRITICAL: client-side tool approval is not a security boundary

ChatGPT/Codex approval settings may be permissive, cached or bypassed by a compromised/prompt-injected session. Tool
annotations and client confirmation remain useful UX, but they do not authorize remote unlock.

Required amendment:

- Add a server-side one-shot arm created only by a local administrator UI action or DUMP-gated local ADB action.
- Default arm lifetime is 15 minutes, cannot exceed 15 minutes in this plan, and permits at most one unlock attempt.
- Success, failure, timeout, OAuth revoke, credential replacement/clear, reboot, key invalidation or explicit disarm
  consumes the arm.
- A failed attempt persists a rearm-required latch; restarting MCP/tunnel/app processes MUST NOT permit another try.
- Mark the tool as a destructive/write action where supported and verify ChatGPT behavior, but never rely on the client
  prompt for enforcement.

### RF-004 — HIGH: use a narrow Shizuku UserService, not `newProcess` or app-side hidden APIs

The current backend has only reflective `Shizuku.newProcess`. It cannot inject input without exposing digits in a
child command. The official Shizuku API recommends `UserService` for privileged Java code and notes that UserService
runs as shell/root without normal app-process hidden-API restrictions.

Required amendment:

- Implement a non-daemon, versioned, stable-tag Shizuku UserService behind an AIDL interface exposing exactly one
  bounded digit-sequence-plus-Enter operation and its `destroy` transaction.
- Prefer public `Instrumentation` key injection from the shell-UID UserService. Do not add a hidden-API-bypass library,
  app-side `IInputManager` reflection, raw Binder transaction, generic input method or `newProcess` fallback.
- Validate Shizuku UID is shell (`2000`); root/Sui execution is not required by this [REDACTED_DEVICE_ALIAS] plan and fails closed unless
  separately reviewed.
- Handle bind timeout, disconnect, binder death, service version replacement and explicit destruction. The UserService
  is non-daemon and retains no credential between calls.
- Zero the digit/key-code arrays in both app and UserService processes in `finally`. Binder kernel buffers are a
  documented residual exposure but never persist to filesystem, logs or argv.
- Verify the UserService path on the actual [REDACTED_DEVICE_ALIAS]/installed Shizuku version because OEM/MediaTek behavior may differ.

Implementation scope is expanded to `shizuku-admin/build.gradle.kts`, `shizuku-admin/src/main/aidl/**`, UserService
sources/tests, `app/build.gradle.kts`, necessary DI bindings and R8/consumer rules.

### RF-005 — HIGH: the original feasibility test has no safe PIN-input path

A secure-keyguard test cannot precede all credential transport work while also forbidding ADB extras/argv. The test
must not motivate a temporary plaintext channel.

Required amendment and execution order:

1. Implement and unit-test the narrow UserService using non-secret digit sequences on an unlocked test surface.
2. Add a debug/local administrator screen with a numeric-only `FLAG_SECURE` input, an in-memory one-shot buffer and a
   delayed test action that lets the administrator lock the phone. It MUST NOT persist or expose the test PIN and MUST
   be absent/inert in the release surface.
3. Run the real [REDACTED_DEVICE_ALIAS] secure-keyguard feasibility gate.
4. Only after the gate passes, implement persistent Keystore provisioning, OAuth policy and production MCP tool.

If the secure-keyguard gate fails, remove/disable the debug harness and stop; do not proceed to production credential
storage or tool registration.

### RF-006 — HIGH: arm/latch persistence semantics are now fixed

The following state rules replace the undecided persistence wording in Task 5.2:

- Ciphertext, Keystore alias/version and exact-client allowlist survive process/service restart and owner-signed APK
  update, but never application data reset/reinstall.
- One-shot arm deadline and failure/consumed latch survive MCP/tunnel/app process restart within the same Android boot.
- Persist arm state atomically with Android `BOOT_COUNT` and an `elapsedRealtime` deadline; a boot-count mismatch
  expires it before decrypt.
- Reboot, success, failure, deadline expiry, revoke, credential replacement/clear and key invalidation all consume arm.
- Credential replacement clears the old failure latch but leaves policy disarmed; the administrator must arm again.
- `KeyInvalidated` remains a distinct fail-closed status; it is not silently mapped to `NotConfigured`.
- Since the app is not Direct-Boot-aware, the live reboot expectation is that MCP is unavailable until the first local
  unlock. `StorageLocked` remains a unit/state-model case rather than a guaranteed public response before that unlock.

### RF-007 — HIGH: provisioning replay needs a concrete envelope

Key version alone does not stop reinstalling old ciphertext.

Required amendment:

- The device issues a one-use random challenge and current monotonic credential generation with its public key.
- The host encrypts a versioned envelope containing challenge, next generation, PIN and fixed context string.
- The device atomically verifies/consumes the challenge and requires exactly `currentGeneration + 1`; a replay or
  skipped generation fails without altering the active credential.
- Pin crypto parameters exactly to RSA-OAEP SHA-256 with MGF1-SHA-256 and an empty label on host and Android. Add a
  host–Android interoperability fixture that contains only a fake test PIN.
- Provisioning status may expose key/envelope/generation versions, never the PIN or its length.

### RF-008 — MEDIUM: exact OAuth principal needs an atomic contract and revoke-race check

Required amendment:

- Introduce a sealed authenticated principal, including `OAuth(clientId)`, returned directly from one access-token
  verification operation; do not verify the token twice or infer identity later.
- Require the signed `sub` and `client_id` claims to match, the audience to match, and the exact client to exist.
- Immediately before decrypt, re-check the live client registry, tombstone/generation and tool policy atomically enough
  that concurrent revoke wins or causes the call to fail closed.
- A new DCR registration always produces a new ID and never inherits policy or an active arm.

### RF-009 — MEDIUM: secret-leak verification must not leak through the scanner itself

The owner PIN MUST NOT be placed in an `rg`/`grep`/shell command argument while scanning logs or process lists.

Required amendment:

- Implement the leak scanner as a small reviewed helper that receives the search value only on stdin and receives log
  paths/streams separately; it returns only found/not-found.
- Do not enable shell xtrace, write a pattern file, echo the value, report offsets/counts, or retain captured buffers.
- Test the scanner using a fake PIN and inspect its own process arguments/environment.

### RF-010 — BLOCKER: provisioning prerequisite is currently absent

At review time the ignored secrets file still had correct owner/mode `0600` but no parseable non-empty `[REDACTED_DEVICE_ALIAS]_PIN`.
Implementation may build and run all non-secret/unit phases, but the live secure-keyguard test and provisioning remain
blocked until the owner saves `[REDACTED_DEVICE_ALIAS]_PIN='...'` without disclosing it in chat.

### Revised critical path

1. Commit this reviewed plan as a standalone plan artifact.
2. Remediate child-environment leakage in existing scripts and add regression tests before adding `[REDACTED_DEVICE_ALIAS]_PIN` support.
3. Implement the narrow non-daemon AIDL Shizuku UserService and debug `FLAG_SECURE` one-shot feasibility harness.
4. Build/install an owner-signed [REDACTED_DEVICE_ALIAS] update and pass the real secure-keyguard gate without persistent credential state.

### RF-009 — LIVE FINDING: pointer injection must target the system input service

The first [REDACTED_DEVICE_ALIAS] feasibility attempt proved that `Instrumentation.sendPointerSync` cannot present Samsung's secure PIN
surface because Android confines that API to windows owned by the instrumented application. The digit key events were
not the failing primitive; the fixed upward gesture failed before digit injection.

Applied amendment:

- Keep the gesture fixed, bounded and caller-unconfigurable inside the shell-UID Shizuku UserService.
- Inject its `MotionEvent` sequence directly through Android's input service from that privileged process; do not add a
  hidden-API bypass library, app-process reflection, raw Binder calls, a generic input interface, or a shell fallback.
- Continue using typed digit key events and zero every digit buffer in `finally`.
- The corrected path passed the real [REDACTED_DEVICE_ALIAS] secure-keyguard test and `KeyguardManager` confirmed the unlocked state.
5. Implement device-bound storage, replay-safe provisioning and one-shot arm/latch semantics.
6. Implement sealed OAuth principal, durable revocation/tombstones and exact-client unlock policy.
7. Register the zero-argument production tool, complete automated/security tests, deploy with `adb install -r`, provision
   separately, arm locally, and pass the public ChatGPT/Cloudflare matrix.

Until step 4 passes, `admin_unlock_device` MUST remain absent from production `tools/list`.
