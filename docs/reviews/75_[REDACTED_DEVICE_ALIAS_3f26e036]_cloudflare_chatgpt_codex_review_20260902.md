# Independent review of Plan 75

Scope: `docs/plans/75_[REDACTED_DEVICE_ALIAS]_cloudflare_chatgpt_codex_20260902.md`, existing [REDACTED_DEVICE_ALIAS]/[REDACTED_DEVICE_ALIAS] owner profiles, the verified
Bedroom TV baseline, Cloudflare state and the current ChatGPT/Codex integration model. The reviewer did not edit any
file or external resource.

## Decision

**Approve with changes.** Do not mutate persistent external resources before incorporating the blocking findings.

## Blocking findings

1. **Minimize secrets.** `GOOGLE_USER/GOOGLE_PASS` are not ARCP/Cloudflare device configuration and must not be
   duplicated into `myconf/[REDACTED_DEVICE_ALIAS]`. Use the existing CDP session and stop for manual owner login/MFA/CAPTCHA. Read the
   shared Cloudflare API token without `source`, `eval`, tracing, argv, Terraform output or logs; local state must be
   ignored and mode `0600`.
2. **Prove Cloudflare ownership and idempotency.** Snapshot active/deleted tunnels and every DNS collision before
   mutation. Partial/ambiguous state must stop. Use one mutation path, record each resource as `created` or `adopted`,
   apply tunnel → ingress → DNS → token → Android, bound health polling, and prove a rerun is a no-op without token
   rotation. Rollback deletes only resources created by this rollout, in reverse order; never delete adopted state.
3. **Use a clean-room TV script.** Do not copy phone behavior that grants Accessibility/runtime permissions or changes
   secure settings. Add a contract test excluding `settings put secure enabled_accessibility_services`, notification
   listener grants, `pm grant`, PIN, Shizuku and ngrok. Verify serial/model/package/version/signer/ABI before changing
   configuration and pass secrets over stdin. Boot autostart needs a reboot test or an explicit pending result; also
   test stop/start, idle/screen-off behavior, loopback socket and an independent LAN probe. ADB TCP 5555 remains a
   documented residual risk.
4. **Treat OAuth approvals as mandatory manual gates.** ChatGPT and Codex register different DCR clients and require
   separate visible approvals on the TV. Never automate the TV approval or Accessibility. Identify ChatGPT apps by URL
   and connector ID, not name alone, and compare tool count/prefix/identity after scanning.
5. **Harden Codex configuration.** Preserve other global tables through CLI or an atomic backed-up change; use
   `enabled=true`, `required=false`, a bounded timeout and explicit DCR/scopes when supported by the installed client.
   Rollback logs out before removing the entry. A fresh process must call a harmless tool and prove the TV identity.
   Isolate that test from unrelated existing MCP startup failures. `approve` is the broadest approval mode and should
   not be enabled without explicit acceptance; begin with `prompt`.

## Important findings

- Capture sanitized pre/post evidence: Cloudflare IDs/config hash, Android signer/version/ABI/binding/process, separate
  OAuth client IDs, ChatGPT connector/release/tool count, Codex version and fresh-process test result.
- Make [REDACTED_DEVICE_ALIAS]/[REDACTED_DEVICE_ALIAS] regression live: DNS, endpoint health/auth boundary and a harmless authenticated call where available.
- Audit tracked, staged and untracked paths, Terraform state, plans, browser exports/screenshots, curl headers, APKs,
  logs and signing material before commit.
- Separate a diagnostic pause (retain exact state) from rollback. A full rollback reverses only new ChatGPT/Codex,
  Android named-tunnel settings, DNS/config/tunnel resources, then restores the captured fail-closed Android state.
- Keep Plan 74 closure evidence logically separate from Plan 75 owner configuration.

With these changes, the direct owner rollout is coherent, reversible and appropriately isolated from phone profiles.
