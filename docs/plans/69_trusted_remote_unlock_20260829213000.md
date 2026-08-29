# Plan 69 — Persistent trusted remote unlock for [REDACTED_DEVICE_ALIAS]

## Status and baseline

- Status: implementation and automated qualification complete; live deployment target is only `[REDACTED_DEVICE_ALIAS]`.
- Prepared on 2026-08-29 after fetching `upstream/main`; the official upstream contains no commits missing from the
  current fork branch.
- Baseline: `dca467d`, with the one-shot policy from Plans 67–68 and the fork-owned `:shizuku-admin` extension.
- The plan must not modify official-upstream production classes. New behavior stays in fork-owned
  `security/remoteunlock/**` and `shizuku-admin/**` paths.

## Objective

Add a locally authorized `TRUSTED` policy that permits repeated zero-argument remote unlocks without a 15-minute
lease or one-attempt arm. Enabling the policy requires local strong biometric or device-credential authentication.
The policy remains active until explicitly disabled, the credential/policy is replaced or cleared, app data is reset,
or the Keystore state becomes invalid. It may survive an ordinary process, service, or phone restart, but Android
credential-encrypted storage and Shizuku still require the first normal post-boot unlock/startup path.

The existing `ONE_SHOT` mode remains available and is the fail-closed migration/default for every existing state.
The public MCP contract remains `android_admin_unlock_device` with an empty input schema and bounded status output.

## Fixed security decisions

- PIN handling, Keystore encryption, exact OAuth-client binding, Cloudflare topology, tool name and empty input schema
  do not change.
- `TRUSTED` can be enabled only by the same-UID administrator activity after Android system authentication. An ADB
  shell/provider call must not be able to enable it. Disabling is always allowed through the existing local/DUMP-gated
  recovery boundary.
- Successful unlocks do not consume `TRUSTED`. Failures do not silently fall back to one-shot or disable Android's
  keyguard.
- Trusted attempts are serialized, separated by at least 30 seconds, and limited to three failed attempts per
  boot-bound ten-minute window. Rate-limit state uses `BOOT_COUNT` and `elapsedRealtime`, not wall-clock time.
- A credential replacement, policy-client change, policy disable, clear, corrupt state, or migration error resets to
  `ONE_SHOT` and disarmed. Version-2 state migrates without losing ciphertext or OAuth binding.
- Every result remains bounded (`unlocked`, `already_unlocked`, `temporarily_blocked`, etc.). No PIN, ciphertext,
  OAuth token/client ID, accessibility dump, lockscreen screenshot, or entered digit is logged or rendered.
- Existing privileged tools remain bearer-only. The exact configured ChatGPT OAuth client may invoke only remote
  unlock, as before.
- No root, generic shell, remote arming, biometric automation, lockscreen weakening, Shizuku automation, data reset,
  uninstall, signing-key change, or deployment to [REDACTED_DEVICE_ALIAS] is in scope.

## Architecture and implementation

### 1. Policy model and persistent state

- [x] Add a stable `RemoteUnlockMode` (`ONE_SHOT`, `TRUSTED`) and expose only bounded mode/cooldown metadata in status.
- [x] Introduce a small authorization-policy strategy/decision boundary so the controller does not grow mode-specific
  PIN/backend behavior.
- [x] Preserve one-shot arm/consume semantics unchanged.
- [x] Add boot-bound trusted attempt/failure state, 30-second spacing and the three-failures/ten-minute limiter.
- [x] Migrate version-2 JSON to version 3 as `ONE_SHOT`; unknown/malformed mode fails closed.
- [x] Clear trusted state on provisioning, OAuth-policy replacement/disable and credential clear.

### 2. Controller behavior

- [x] Authorize an attempt only after configuration, enablement, Shizuku readiness and actual keyguard state checks.
- [x] Consume a one-shot authorization before decryption; retain trusted authorization after success.
- [x] Record success/failure through the policy boundary and preserve the existing generic failure result.
- [x] Keep mutex serialization, bounded settle time and zeroing of decrypted buffers unchanged.

### 3. Local administrator UI

- [x] Extend the shared provider contract with bounded `mode`, `trusted_active` and `cooldown_remaining_ms` fields.
- [x] Add fixed `enable_trusted` and `disable_trusted` operations. Enabling must reject every caller UID except the
  application UID; the activity calls it only after successful local authentication.
- [x] Retain one-shot Arm/Disarm controls and add authenticated `Enable trusted unlock` plus safe `Disable trusted
  unlock`.
- [x] Clearly render that trusted mode allows repeated unlocks until disabled and that Shizuku remains required.
- [x] Preserve `FLAG_SECURE`, lifecycle cancellation, single-callback behavior and absence of secret/client metadata.

### 4. Automated tests and regressions

- [x] Unit-test mode parsing/default migration policy, trusted persistence, limiter boundaries, reboot behavior, success reset, failure
  blocking, one-shot compatibility, policy replacement and corrupt-state fail-closed behavior.
- [x] Unit-test controller decisions for one-shot, trusted, cooldown, unavailable Shizuku, already-unlocked and failed
  injection paths.
- [x] Unit-test UI mapping/coordinator behavior for enable, disable, authentication cancellation/error, lifecycle
  invalidation and duplicate callbacks.
- [x] Test provider same-UID enforcement and merged-manifest `DUMP` boundary.
- [x] Run repository shell tests, all JVM/module tests, privacy tests, `ktlintCheck`, `detekt`, E2E compilation, secret
  scans, signed `gmsRelease` build and merged-manifest verification.
- [x] Assert changed production paths remain absent from `upstream/main` or are pre-existing fork-owned paths.

### 5. Documentation and configuration

- [x] Update root/tool documentation and `myconf/[REDACTED_DEVICE_ALIAS]` with mode semantics, recovery, rate limits and post-reboot
  Shizuku requirement.
- [x] Keep tracked configuration non-secret. Do not write the PIN, ciphertext, tokens, browser cookies or CDP data.
- [ ] Record exact APK version, Git SHA, digest, certificate and live acceptance outcome after deployment.

## Delivery and live acceptance on [REDACTED_DEVICE_ALIAS]

1. Commit this plan separately.
2. Implement and commit reviewed code/tests/docs, then push the accumulated local branch to `origin/main` as requested.
3. Build an owner-signed, forward-versioned `gmsRelease` APK and prepare an ignored, signature-checked rollback artifact.
4. Temporarily enable Wireless debugging only for deployment, verify the exact Xiaomi identity, and use `adb install -r`
   without uninstalling or clearing app data. Disable USB/Wireless debugging again after verification.
5. Confirm ciphertext/configuration, OAuth binding, Accessibility, Shizuku permission, server and tunnel survived.
6. In the local administrator UI, authenticate and enable `TRUSTED`; cancellation must leave the previous state intact.
7. Lock [REDACTED_DEVICE_ALIAS] and invoke `android_admin_unlock_device` twice in separate lock cycles without re-enabling trusted mode.
   Both attempts must unlock. A deliberately invalid PIN is forbidden.
8. Verify the limiter through deterministic unit/integration tests, not by risking real Android lockout.
9. Through the already authenticated browser on CDP `127.0.0.1:9222`, open the [REDACTED_DEVICE_ALIAS] ChatGPT connector chat, submit a
   concise unlock prompt, observe the connector tool call/result and verify the real keyguard becomes unlocked. Do not
   expose CDP or browser credentials.
10. Re-run ordinary tools, four bearer admin tools, OAuth/Cloudflare discovery, unauthenticated 401 behavior, closed
    Wi-Fi port 8080, closed Wireless ADB ports and log/crash checks.
11. Record non-secret evidence in this plan/configuration, commit it, and push the final commit.

Manual biometric/device-credential confirmation and temporarily enabling Wireless debugging are expected gates. If
[REDACTED_DEVICE_ALIAS] cannot be unlocked locally for either gate, implementation and local tests continue, but deployment/E2E must be
reported incomplete rather than bypassing device security.

## Rollback

- Functional rollback: locally select `ONE_SHOT`/disable trusted mode; encrypted credential and OAuth binding remain.
- Binary rollback: install the prepared owner-signed forward-versioned baseline with `adb install -r`.
- If trusted authorization or rate limiting is ambiguous, fail closed to `ONE_SHOT`, keep the MCP status bounded and do
  not deploy.

## Acceptance definition

Complete means: plan and implementation are committed and pushed; automated gates pass; the owner-signed APK is
installed only on [REDACTED_DEVICE_ALIAS] without data loss; trusted mode is locally authenticated; two separate remote unlocks succeed
without rearming; ChatGPT performs a real unlock through the [REDACTED_DEVICE_ALIAS] connector over Cloudflare; ordinary/admin/OAuth and
network regressions pass; Wireless debugging is off again; and non-secret deployment evidence is committed and pushed.
