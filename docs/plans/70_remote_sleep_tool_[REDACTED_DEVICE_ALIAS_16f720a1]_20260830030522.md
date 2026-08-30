<!-- SACRED DOCUMENT — DO NOT MODIFY except for checkmarks ([ ] → [x]) and review findings. -->
<!-- You MUST NEVER alter, revert, or delete files outside the scope of this plan. -->
<!-- Plans in docs/plans/ are PERMANENT artifacts. There are ZERO exceptions. -->

# Plan 70 — Remote sleep tool and [REDACTED_DEVICE_ALIAS] end-to-end acceptance

Add a zero-argument `android_admin_sleep_device` tool to the existing ARCP MCP server. The operation puts Android to
sleep through the optional Shizuku administration boundary, then remains usable with the existing trusted remote
unlock flow. Deploy and accept the change on [REDACTED_DEVICE_ALIAS] only. [REDACTED_DEVICE_ALIAS] is explicitly outside this rollout.

## Fixed architecture and security decisions

- The existing `/mcp` server, Cloudflare tunnel and `127.0.0.1:8080` binding remain unchanged.
- The implementation belongs to the fork-owned `:shizuku-admin` extension and its single MCP registration seam. No
  upstream UI class, transport or server is modified.
- The backend executes only the fixed argument vector `input keyevent KEYCODE_SLEEP`. The MCP caller supplies no
  command, key code, duration or other input. No generic shell tool is introduced.
- The tool is available to the administrator bearer and to the exact OAuth client locally authorized for remote
  unlock. Other OAuth clients are denied before the backend is invoked.
- Sleeping does not read, transmit or consume the PIN and does not consume an unlock attempt. The existing unlock
  cooldown and failure policy remains authoritative for the later unlock call.
- Every call uses existing tool logging and permission controls. Shizuku unavailable/denied/command failures map to
  stable MCP errors without command output or credentials.
- Owner signing, install-with-data-preservation, explicit [REDACTED_DEVICE_ALIAS] identity checks and qualified build manifests remain
  mandatory. A signature mismatch is a hard stop.
- Wireless/remote debugging may be enabled only for the controlled deployment window. It MUST be disabled before the
  E2E sleep/unlock test; known ADB ports must be closed.
- No token, PIN, password, keystore or `.env.secrets` content may enter Git, command output, test fixtures or build
  manifests.

## Scope

Allowed implementation paths:

- `shizuku-admin/src/main/**` and corresponding `shizuku-admin/src/test/**`;
- `app/src/main/kotlin/com/danielealbano/androidremotecontrolmcp/mcp/shizuku/**` and corresponding unit tests;
- the existing MCP registration contract tests;
- `README.md` and `myconf/[REDACTED_DEVICE_ALIAS]/**` documentation/configuration artifacts;
- this plan file.

Out of scope: [REDACTED_DEVICE_ALIAS] installation or configuration, Cloudflare/DNS/tunnel mutation, OAuth protocol changes, a generic
shell/input tool, remote Shizuku bootstrap, PIN changes, data reset, app uninstall and upstream source-class edits.

## User Story 1 — Narrow sleep capability

- [ ] Add `sleepDevice()` to the application-owned `PrivilegedAdminBackend` boundary.
- [ ] Implement it as fixed `input keyevent KEYCODE_SLEEP` with bounded output and timeout.
- [ ] Reject unready Shizuku, permission denial, truncation and non-zero exit through the stable exception taxonomy.
- [ ] Add backend tests proving the exact command/argument vector and rejection paths.

## User Story 2 — MCP exposure and authorization

- [ ] Register zero-argument `admin_sleep_device` through `registerShizukuAdminTools`.
- [ ] Authorize the administrator bearer and only the exact locally authorized OAuth client used by remote unlock.
- [ ] Add handler tests for bearer success, exact OAuth success, wrong OAuth denial and backend failure mapping.
- [ ] Update the closed production tool-surface test and prove no shell/settings/clear primitive appears.
- [ ] Preserve per-tool `disabledTools` behavior and existing audit logging.

## User Story 3 — Build and [REDACTED_DEVICE_ALIAS] deployment

- [ ] Run formatting, static analysis, module/unit tests, merged-manifest validation and the qualified owner-signed
  `gmsRelease` build with bounded Gradle workers.
- [ ] Confirm the artifact package, version, signer and qualified deployment manifest.
- [ ] Enable Wireless debugging only after the build is qualified and the user completes Android's manual gate.
- [ ] Verify explicit [REDACTED_DEVICE_ALIAS] identity and deploy with `adb install -r`, preserving application data.
- [ ] Restore/restart the saved [REDACTED_DEVICE_ALIAS] configuration and verify the Cloudflare endpoint.
- [ ] Disable Wireless and USB debugging before E2E; externally verify that known ADB ports are closed.

## User Story 4 — ChatGPT/CDP E2E and regression

- [ ] Through the already authenticated browser on CDP `127.0.0.1:9222`, refresh the [REDACTED_DEVICE_ALIAS] ChatGPT connector so the
  scanned schema contains `android_admin_sleep_device` and the pre-existing admin tools.
- [ ] In a ChatGPT conversation invoke the sleep tool and verify that [REDACTED_DEVICE_ALIAS] becomes non-interactive/locked.
- [ ] Invoke `android_admin_unlock_device` through the same exact OAuth client and verify `status=unlocked` plus the
  expected foreground state after wake.
- [ ] Repeat one complete sleep/unlock cycle to cover trusted-mode reuse and spacing rules.
- [ ] Run bearer regressions for `tools/list`, ordinary Accessibility, Shizuku top-window and protected uninstall
  rejection; confirm the public endpoint still rejects unauthenticated requests.
- [ ] Confirm no crash, ANR, tunnel loss or Shizuku loss during the acceptance window.

## User Story 5 — Documentation and delivery

- [ ] Update the root and [REDACTED_DEVICE_ALIAS] documentation, recorded tool count/version and deployment acceptance evidence.
- [ ] Audit tracked paths and the pending diff for secrets; confirm `.env.secrets` stays ignored with mode `0600`.
- [ ] Commit the plan separately, commit implementation/tests, then commit live acceptance documentation.
- [ ] Push only after all automated and [REDACTED_DEVICE_ALIAS] E2E gates pass; confirm local `main` equals `origin/main`.

## Acceptance criteria

The work is complete only when [REDACTED_DEVICE_ALIAS], with remote debugging disabled, can be put to sleep and then unlocked through the
refreshed ChatGPT connector; a second trusted-mode cycle passes; ordinary MCP and existing privileged tools regress
cleanly; no secret is tracked; and all commits are present on `origin/main`. Any manual Android or ChatGPT gate is
reported explicitly and does not authorize bypassing device or account security.
