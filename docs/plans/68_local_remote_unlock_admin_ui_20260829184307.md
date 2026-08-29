# Plan 68 — Local administrator UI for remote-unlock arming

## Status and upstream baseline

- Status: implemented, deployed, and accepted on [REDACTED_DEVICE_ALIAS] on 2026-08-29.
- Prepared on 2026-08-29 after `scripts/sync-build-deploy.sh sync --upstream-ref upstream/main --apply`.
- Official `upstream/main` is already integrated; the sync created no branch and changed no files.
- The `vendor/cloudflared` and `vendor/ngrok-java` remotes were fetched. Their pinned commits remain unchanged.
- This plan extends only fork-owned remote-unlock and `:shizuku-admin` code. It must not edit upstream UI classes such
  as `MainActivity`, `MainScreen`, upstream navigation, or upstream settings view models.

## Objective

Let a local administrator arm and disarm the existing secure remote-unlock operation from the installed ARCP APK,
without ADB for each arm, without exposing the PIN, and without weakening the current one-shot 15-minute policy.

The first production target is [REDACTED_DEVICE_ALIAS]. Initial PIN provisioning and OAuth-client binding remain ADB-only recovery and
setup operations.

Trust assumption: platform authentication proves possession of any strong biometric or device credential enrolled
for the current Android user; it does not identify a separate ARCP administrator. This is accepted for owner-operated
[REDACTED_DEVICE_ALIAS], where those credentials are administrator-controlled. It must be reassessed before enabling this UI on a child
or shared Android user.

## Non-goals

- Do not make arming automatic, persistent, remotely callable, or controllable by intent extras.
- Do not add PIN viewing, PIN export, arbitrary input injection, generic shell access, or Shizuku startup automation.
- Do not change the one-shot count, 15-minute lifetime, exact OAuth-client binding, or ChatGPT confirmation behavior.
- Do not deploy to [REDACTED_DEVICE_ALIAS] in this change.
- Do not modify official-upstream classes merely to add a navigation entry.

## OCP architecture

Treat the UI as a fork extension rather than a modification to upstream navigation:

1. Add a separate `RemoteUnlockAdminActivity` owned by the custom `:shizuku-admin` module.
2. Register it through `shizuku-admin/src/main/AndroidManifest.xml`, which is merged into the final APK. Expose a
   second launcher entry labelled `ARCP Administrator`; do not edit the upstream app manifest or `MainActivity`.
3. Make the activity depend on a small `RemoteUnlockAdminGateway` port. Its Android adapter calls the existing
   same-package remote-unlock `ContentProvider` through `ContentResolver`; the activity does not depend on app-module
   implementation classes.
4. Keep the exported provider protected by `android.permission.DUMP`. Same-UID calls from the extension activity are
   allowed, while third-party applications remain denied by Android.
5. Extend only fork-owned provider/store classes with explicit `disarm` and bounded `remaining_ms` status. Do not
   add generic mutation methods or caller-controlled durations.

The provider returns a bounded `remaining_ms`, not the persisted deadline, so UI code cannot accidentally reproduce
or weaken expiry logic.

This keeps the upstream UI closed for modification while the custom module is open for independently registered
administrator features.

## User experience

The administrator activity shows only bounded metadata:

- configured / not configured;
- enabled / disabled;
- armed / disarmed and a local countdown to expiry;
- rearm required after failure;
- Shizuku ready / unavailable.

Actions:

- `Arm one attempt for 15 minutes` — enabled only when configured and policy-enabled;
- `Disarm now` — always safe and requires no biometric confirmation;
- `Refresh status`.

Arming must first pass Android's system authentication using `BiometricPrompt` with strong biometric or device
credential. Cancellation, authentication failure, missing secure lock, provider failure, and backgrounding must fail
closed. The activity sets `FLAG_SECURE`, accepts no behavioral intent extras, never reads the PIN, and never logs the
OAuth client ID, ciphertext, or credential data.

The custom module manifest declares `android.permission.USE_BIOMETRIC`. The prompt uses
`BIOMETRIC_STRONG | DEVICE_CREDENTIAL` and does not configure a negative button, which is incompatible with device
credential fallback.

## State and security invariants

- Before adding UI, migrate the current wall-clock arm to a monotonic record: current Android `BOOT_COUNT` plus an
  `elapsedRealtime` deadline. Existing version-1 arm deadlines fail closed during migration.
- `arm()` writes the current boot count, monotonic deadline `now + 15 minutes`, and `rearm_required = false`.
- `consumeArm()` clears the monotonic deadline atomically before digit injection.
- A boot-count mismatch, elapsed deadline, malformed state, or clock-source failure is disarmed.
- `disarm()` only clears the active arm; it must not alter encrypted credentials, enabled policy, OAuth binding, or
  the failure latch.
- A failed unlock continues to clear the arm and set `rearm_required = true`.
- The UI obtains status through a typed adapter and displays no `authorized_client_id` value.
- Rotation/background refresh must not repeat an authenticated action.
- External callers without `DUMP` must remain unable to call `arm`, `disarm`, provisioning, policy, clear, or status.

## Implementation slices

### 1. Fork extension contract and UI

- Add the provider method/key contract, gateway interface, ContentResolver adapter, presentation model, and
  `RemoteUnlockAdminActivity` below `shizuku-admin/src/main`.
- Add a small lifecycle-safe coordinator and authenticator port. Start authentication only from a direct click, block
  repeated clicks, number attempts in memory, cancel `CancellationSignal` in `onStop`, and accept a callback only for
  the current attempt while the activity is `RESUMED`. Rotation invalidates the attempt and requires a new click.
- Add module-owned resources including Polish and default English strings.
- Add the launcher activity to the custom module manifest.
- Use platform Android widgets and platform `BiometricPrompt`; avoid adding Compose/navigation dependencies to the
  isolated module.

### 2. Fork-owned app adapter

- Add `disarm()` to the fork-owned `RemoteUnlockCredentialStore` and implementation.
- Replace the fork-owned store's wall-clock deadline with boot-count plus monotonic elapsed time and a fail-closed
  state migration.
- Extend the fork-owned `RemoteUnlockProvisioningProvider` with the fixed `disarm` operation and
  bounded `remaining_ms` status field, using the shared extension contract.
- Preserve all existing provisioning and MCP behavior.

### 3. Automated verification

- Unit-test presentation mapping and expiry/countdown behavior without Android UI dependencies.
- Unit-test the auth coordinator for success, cancellation, error, double callback, repeated click, background,
  rotation/invalidation, and provider exception.
- Unit-test `disarm()` preserving configuration, policy, and OAuth binding.
- Unit-test monotonic expiry, reboot mismatch, old-state migration, malformed-state failure, atomic consumption, and
  clock failure.
- Extend provider/manifest tests to cover the new fixed operation, launcher component, exported state, and `DUMP`
  protection.
- Run `ktlintCheck`, `detekt`, app/module unit tests, privacy tests, E2E Kotlin compilation, and a production APK build
  through the repository delivery script.
- Inspect the merged release manifest/APK, not only the source app manifest: require exactly two launcher entries,
  the fully qualified administrator activity with `exported=true`, `USE_BIOMETRIC`, and the unchanged exported
  `DUMP`-protected provider. Assert the app does not request `DUMP` itself.
- Add an Android live permission-boundary test: same-UID activity status/arm works, ADB shell still works, and a
  separate UID without `DUMP` receives `SecurityException`.
- Assert OCP against baseline `23c2800`: for each production class changed by this feature, verify that its path did
  not exist in `upstream/main`. Do not compare all historical fork changes with upstream.

### 4. [REDACTED_DEVICE_ALIAS] deployment and live acceptance

Deploy the owner-signed `gmsRelease` APK using `adb install -r`; never uninstall or clear app data.

Before implementation/deployment acceptance, run an ADB-only preflight of the existing build: exact OAuth client
match, Shizuku readiness, local arm, locked [REDACTED_DEVICE_ALIAS] screen, and one successful unlock. This separates existing Xiaomi
input feasibility from any new UI failure.

Before replacing the installed build, archive its base APK under ignored `build/rollback/[REDACTED_DEVICE_ALIAS]/` with SHA-256,
versionCode, and signing certificate. Prepare a known-good forward-versioned rollback APK from baseline `23c2800` and
validate its metadata/signature. Deployment is blocked unless a non-destructive rollback artifact is ready; do not
assume `adb install -r -d` can downgrade a production APK.

Live checks:

1. Existing configuration, encrypted credential, OAuth binding, server, tunnel, and Shizuku permission survive update.
2. The `ARCP Administrator` launcher entry starts the extension activity.
3. Status initially matches the provider and does not expose PIN/client/ciphertext.
4. Cancelling system authentication leaves `armed=false`.
5. Successful local device authentication changes status to `armed=true` with no more than 15 minutes remaining.
6. `admin_unlock_device` through the production [REDACTED_DEVICE_ALIAS] MCP path consumes the arm and unlocks the device.
7. A second remote attempt without rearming returns `temporarily_blocked`.
8. Local rearm followed by `Disarm now` returns to `armed=false` without losing configuration.
9. Public endpoint still requires authentication, loopback remains reachable, Wi-Fi port 8080 remains closed, and
   ordinary MCP tools still work.

Manual biometric/PIN confirmation is an expected local gate. No PIN will be entered through automation or printed in
test output.

## Independent review disposition

Independent review completed before implementation with `NEEDS AMENDMENTS`. Incorporated findings:

- declare and verify `USE_BIOMETRIC` and use a valid authenticator combination;
- document the current-user credential trust boundary;
- add a lifecycle-safe, single-callback authentication coordinator;
- replace wall-clock persisted arms with `BOOT_COUNT + elapsedRealtime` and expose only remaining duration;
- preflight existing [REDACTED_DEVICE_ALIAS] unlock feasibility;
- test same-UID, ADB-shell, and external-UID provider boundaries plus the merged manifest;
- prepare a real [REDACTED_DEVICE_ALIAS] rollback artifact before deployment;
- compare OCP changes against baseline `23c2800` rather than all historical fork changes;
- expand coordinator and store failure-path tests.

Rejected as unnecessary: a second provider, custom Android permission, separate administrator password/Keystore,
Compose, Hilt, retained fragment, or another Gradle module. The existing provider, one module-owned activity, a small
gateway, authenticator/coordinator, and platform views are sufficient.

## Documentation and delivery

- Update `docs/MCP_TOOLS.md`, the root README, and `myconf/[REDACTED_DEVICE_ALIAS]/README.md` with the new local administrator entrypoint,
  while retaining ADB as a recovery path.
- Record build/deployment evidence without committing APKs, generated deployment manifests, secrets, or device logs.
- After all automated gates and the [REDACTED_DEVICE_ALIAS] smoke test pass, stage only the reviewed feature, tests, plan, and
  documentation, then create one local commit. Do not push unless separately requested.

## Implementation and acceptance evidence

Completed on 2026-08-29:

- upstream, cloudflared, and ngrok-java refs were fetched before implementation; no new upstream commit required a
  merge;
- the production implementation is confined to fork-owned remote-unlock paths and the custom `:shizuku-admin`
  extension; an OCP audit against `upstream/main` found zero modified upstream production classes;
- `ktlintCheck`, `detekt`, all app/privacy/privacy-benchmark tests, and E2E Kotlin compilation passed. The ngrok
  integration test was run with the existing ignored [REDACTED_DEVICE_ALIAS] secret injected only into its process;
- the signed `gmsRelease` APK has versionCode `20009991`, retains the owner certificate, contains both native tunnel
  payloads, and passes the merged-manifest verifier;
- a signed forward-versioned baseline rollback APK was prepared from `23c2800` with versionCode `20009999` under the
  ignored `build/rollback/[REDACTED_DEVICE_ALIAS]/` directory before deployment;
- `adb install -r` preserved [REDACTED_DEVICE_ALIAS] application data and the existing encrypted PIN, enabled policy, OAuth binding,
  accessibility service, Shizuku permission, and tunnel configuration;
- the second launcher opens the isolated activity, reports Shizuku ready, and exposes no PIN, ciphertext, or OAuth
  client identifier;
- cancellation left the state disarmed; local biometric authorization armed one attempt for 15 minutes; an MCP call
  unlocked a sleeping [REDACTED_DEVICE_ALIAS] and consumed the arm; the next call returned `temporarily_blocked`;
- `Disarm now` cleared only the arm and preserved configuration. A separate restart check showed the monotonic arm
  survived a service restart while its remaining time decreased, after which it was explicitly disarmed;
- loopback returned HTTP 401 without credentials, public [REDACTED_DEVICE_ALIAS] MCP returned HTTP 401, and Wi-Fi TCP port 8080 remained
  closed.

The external-UID negative check is covered by the merged-manifest assertion that the exported provider retains
`android.permission.DUMP` while the application does not request that permission. A temporary independently signed
probe APK was additionally prepared, but MIUI rejected installing the new test package with
`INSTALL_FAILED_USER_RESTRICTED`; no test package was left on [REDACTED_DEVICE_ALIAS]. Same-UID UI access and ADB-shell access were both
verified live.

## Rollback

- Application rollback uses the prepared owner-signed, forward-versioned baseline APK through `adb install -r`.
- Functional rollback needs no APK change: `Disarm now` or the existing ADB status/arm controls remain available.
- If the new activity fails, MCP remote unlock remains governed by the unchanged controller and ADB arm path.

## Acceptance definition

The task is complete only when upstream synchronization is recorded, independent review findings are incorporated,
the feature changes no upstream classes, automated gates pass, the owner-signed release is installed on [REDACTED_DEVICE_ALIAS] without
data reset, local authenticated arming and disarming work, one remote unlock succeeds and consumes the arm, the second
unarmed attempt is blocked, endpoint/network invariants remain intact, and the resulting paths are committed locally.
