<!-- IMPLEMENTED — independently reviewed; one owner-approved reboot/autostart check remains explicitly pending. -->
<!-- Never commit bearer/OAuth/tunnel/API tokens, Google credentials, browser cookies, Terraform state or generated APKs. -->

# Plan 75 — persistent `[REDACTED_DEVICE_ALIAS]` Cloudflare, ChatGPT and Codex integration

Create a persistent owner configuration for the [REDACTED_OWNER_VALUE] under `myconf/[REDACTED_DEVICE_ALIAS]`, expose its loopback-only
ARCP origin as `https://[REDACTED_PRIVATE_HOST]` through a dedicated named Cloudflare Tunnel, then connect and test
that endpoint from ChatGPT and the local Codex client. This is a direct rollout to one small owner environment; there
is no canary tier.

## Verified baseline and boundaries

- Bedroom TV is `[REDACTED_OWNER_VALUE]` / `kirkwood`, Android API 34, 32-bit userspace
  `armeabi-v7a,armeabi`, currently reachable as `[REDACTED_PRIVATE_ENDPOINT]`.
- The owner-signed edge release
  `arcp-edge-16f39717ce09-dda2c531f58d-vc21000002` is installed with `versionCode=21000002`, the owner certificate,
  and Android-selected `primaryCpuAbi=armeabi-v7a`.
- The installed release passed local and Cloudflare Quick Tunnel checks: `/health=200`, unauthenticated `/mcp=401`,
  authenticated `initialize`, `tools/list`, and 49 discovered tools with the `android_[REDACTED_DEVICE_ALIAS]_` prefix. The
  accessibility-dependent screen-state call returned a controlled permission error; no Restricted Settings or
  Accessibility permission was bypassed.
- The temporary Quick Tunnel, bearer and origin were stopped/cleared after qualification. Only the installed APK is
  retained before this plan begins.
- Persistent target: tunnel name `[REDACTED_DEVICE_ALIAS]`, hostname `[REDACTED_PRIVATE_HOST]`, origin
  `http://localhost:8080`, MCP URL `[REDACTED_OWNER_VALUE]`.
- Do not add ngrok for this ARMv7 device. No Regery mutation is needed because `[REDACTED_PRIVATE_HOST]` is already
  delegated to Cloudflare; only a Cloudflare DNS record is added.
- Keep ARCP bound to `127.0.0.1`. Do not expose port 8080 to the LAN, weaken authentication, grant Android privileged
  permissions, or change the TV's pre-existing debugging setting without separate authorization.

## Secrets and identity contract

1. Add an ignored, mode-`0600` `myconf/[REDACTED_DEVICE_ALIAS]/.env.secrets` and a tracked placeholder-only `.env.example`.
2. Copy only the shared `CLOUDFLARE_API_TOKEN` from the existing ignored profiles without printing it. Require equality
   in both source profiles and verify its live account/zone permissions before selecting it. Do not copy Google,
   Qustodio or PIN credentials: the existing CDP session is the only browser identity source, and reauthentication,
   MFA or CAPTCHA is a mandatory manual owner gate.
3. Generate a unique random `ANDROID_MCP_BEARER_TOKEN` for `[REDACTED_DEVICE_ALIAS]`. Create a dedicated Cloudflare Tunnel and store
   only its newly retrieved `CLOUDFLARE_TUNNEL_TOKEN`. Never reuse the bearer or tunnel token of [REDACTED_DEVICE_ALIAS]/[REDACTED_DEVICE_ALIAS].
4. Keep ChatGPT session cookies and OAuth access/refresh tokens browser-managed and non-exportable. Keep Codex OAuth
   credentials in Codex's credential store, not in the repository or `config.toml`. Never place a secret in argv,
   Terraform output/state committed to Git, browser exports/screenshots or logs; any local Terraform state is ignored
   and mode `0600`.

## Configuration design

### Owner configuration and verification

- Add `myconf/[REDACTED_DEVICE_ALIAS]/{README.md,.env.example,snapshot.json}` plus:
  - `android/config.json` and `android/apply-config.sh`;
  - `cloudflare/{versions.tf,variables.tf,main.tf,outputs.tf,imports.tf,.terraform.lock.hcl,live-snapshot.json}`;
  - `chatgpt/connectors.json`;
  - `scripts/verify.sh`.
- Preserve the formats used by `myconf/[REDACTED_DEVICE_ALIAS]` and `myconf/[REDACTED_DEVICE_ALIAS]`, but omit phone-only PIN/Shizuku/Qustodio/ngrok
  material. Extend the shared device-config validator and root `myconf/README.md` for `[REDACTED_DEVICE_ALIAS]`.
- Make a clean-room TV apply script fail closed on missing/duplicate secrets, wrong device identity, non-`0600`
  permissions, or an
  unverified ADB serial. Configure `device_slug=[REDACTED_DEVICE_ALIAS]`, bearer and OAuth enabled, public URL override, loopback origin,
  500 MB file limit, dedicated token-mode Cloudflare, and boot autostart. Add a contract test proving it contains no
  `pm grant`, Accessibility/secure-settings write, notification-listener grant, PIN, Shizuku or ngrok behavior. Pass
  secrets through stdin and do not silently grant runtime or restricted Android permissions.

### Cloudflare

- Snapshot active and deleted tunnel names plus every DNS record colliding with the exact hostname. A partial or
  ambiguous state stops the rollout. Adopt an exact existing `[REDACTED_DEVICE_ALIAS]` tunnel/hostname only after explicit review proves
  its account, zone, tunnel type, ingress and ownership; otherwise create new state.
- Otherwise create one remotely managed tunnel, configure ingress for `[REDACTED_PRIVATE_HOST]` to
  `http://localhost:8080` plus a terminal `http_status:404`, create one proxied CNAME to its
  `<tunnel-id>.cfargotunnel.com`, and retrieve its dedicated run token.
- Use exactly one mutating path in the order tunnel → ingress → DNS → token retrieval → Android. Capture non-secret IDs,
  `created|adopted` ownership and a configuration hash in Terraform/import/snapshot files. Never commit Terraform
  state. Validate HCL formatting, use bounded DNS/TLS/health polling and an API read-back comparison, then prove a
  second run is a no-op and does not rotate the token.

### ChatGPT

- Through the already authorized Chrome CDP endpoint `127.0.0.1:9222`, first verify the active account is
  `[REDACTED_EMAIL]`; do not enter stored credentials unless the existing Google session explicitly requires it.
- Create a private developer MCP app named `[REDACTED_DEVICE_ALIAS]` at the persistent MCP URL, select OAuth/DCR, scan tools, and
  connect it. Complete only normal visible OAuth approval; if the TV presents an authorization code/approval screen,
  pause for the owner rather than bypassing it. ChatGPT and Codex create different DCR clients and each requires a
  separate visible owner approval on the TV; these are mandatory manual gates.
- Enable the discovered actions consistently with the existing owner connectors and record only non-secret plugin,
  connector, release/version, link and OAuth-client identifiers. Official OpenAI guidance requires an explicit tool
  refresh when the server's action snapshot changes.

### Codex

- Add the global Streamable HTTP server `[mcp_servers.android_[REDACTED_DEVICE_ALIAS]]` with
  `url = "[REDACTED_OWNER_VALUE]"`, `enabled=true`, `required=false`, a bounded tool timeout and
  `default_tools_approval_mode = "prompt"`. The existing phone entries use the broader `approve`, but that automatic
  mode is not assumed for a new shared-TV endpoint. Do not add a static header or literal bearer to `config.toml`.
- Run explicit DCR login with scopes `mcp,offline_access` when supported by the installed Codex client and retain
  credentials in Codex's own store. Verify the stored
  entry with `codex mcp get/list`. A currently running IDE session cannot acquire the new tool inventory, so perform
  functional validation in a fresh Codex process/session and document that the IDE must later be reloaded.

## Execution and acceptance

### Phase 1 — Plan and independent review

- [x] Record the live APK/ABI/Quick-Tunnel baseline and persistent target.
- [x] Independently review idempotency, secret isolation, Cloudflare rollback, Android final state, OAuth/DCR manual
  gates, browser-account validation, Codex reload behavior and evidence sufficiency.
- [x] Incorporate sensible findings before creating persistent external resources or files beyond this plan. Review
  decision: `approve-with-changes`; accepted changes cover minimal secrets, resource ownership/idempotency, a clean-room
  Android script, separate mandatory DCR approvals, safer Codex defaults, expanded evidence and rollback semantics.

### Phase 2 — Local configuration and Cloudflare

- [x] Create and structurally validate `myconf/[REDACTED_DEVICE_ALIAS]`; copy only approved shared secret values, generate a new bearer,
  and prove `.env.secrets` is ignored, `0600`, and untracked.
- [x] Read/adopt-or-create the exact Cloudflare tunnel, configuration and DNS record; retrieve the dedicated tunnel
  token into the ignored profile and record non-secret IDs in IaC/live snapshot files.
- [x] Apply the `[REDACTED_DEVICE_ALIAS]` ARCP configuration to the verified TV and start the service. Confirm app/cloudflared processes,
  tunnel health, autostart configuration, loopback binding, public `/health=200`, unauthenticated `/mcp=401`, OAuth
  discovery/DCR metadata, authenticated bearer `initialize/tools/list`, and LAN port 8080 closed.
- [x] Exercise one controlled ARCP stop/start recovery and re-run endpoint checks. Keep the named tunnel running after
  success; disconnect host ADB without changing the TV's existing debugging setting.
- [x] Verify screen-off/idle behavior and record reboot autostart as pending. The screen-off check passed for 20 seconds;
  an owner-approved reboot was not performed, so autostart remains explicitly pending rather than inferred. The
  independent LAN port 8080 probe is closed. ADB TCP 5555 remains a residual risk even after disconnecting this host.

### Phase 3 — ChatGPT and Codex

- [x] Verify the browser account, create/connect the private `[REDACTED_DEVICE_ALIAS]` ChatGPT app through CDP, scan/enable actions, and
  record only exportable non-secret metadata.
- [x] In a new ChatGPT chat, explicitly select/mention `[REDACTED_DEVICE_ALIAS]`, invoke one read-only tool, and verify its result came
  from the [REDACTED_OWNER_VALUE]. Do not invoke destructive or accessibility-dependent actions for acceptance.
- [x] Add and OAuth-authenticate `android_[REDACTED_DEVICE_ALIAS]` in Codex without disturbing other tables. Verify config parsing, OAuth
  metadata and a fresh-process read-only MCP call that returns the Google TV identity and `android_[REDACTED_DEVICE_ALIAS]_` prefix.
  Isolate the run from unrelated MCP failures; do not claim the already-running IDE has reloaded it.

### Phase 4 — Regression, evidence and delivery

- [x] Local shared/device validators, `[REDACTED_DEVICE_ALIAS]` bearer smoke, focused release tests and [REDACTED_DEVICE_ALIAS]/[REDACTED_DEVICE_ALIAS] public regressions
  passed. Main CI run `33652741703` passed all five jobs for implementation commit `c7a20c3`.
- [x] Audit tracked/staged files for `.env.secrets`, tokens, passwords, cookies, state, APKs and signing material.
- [x] Update Plan 74 with its final released-APK evidence and this plan with Cloudflare/ChatGPT/Codex IDs and E2E
  results, without secrets.
- [x] Commit narrow logical changes, push `main`, wait for CI, and leave the worktree clean. Do not create another APK
  release because this phase changes owner configuration only, not the already released application binary.

## Rollback

- Before application of the named tunnel, preserve the stopped/fail-closed ARCP state. If Cloudflare provisioning is
  incomplete, keep the tunnel disabled on the TV and do not create ChatGPT/Codex integrations.
- A diagnostic pause retains exact state and IDs without further mutation. A full rollback disables/deletes only a
  ChatGPT app created by this plan, logs out then removes only `android_[REDACTED_DEVICE_ALIAS]`, restores the captured fail-closed ARCP
  settings, and removes DNS → tunnel config → tunnel in reverse order only where the ownership ledger says `created`.
  Never delete adopted state or touch [REDACTED_DEVICE_ALIAS]/[REDACTED_DEVICE_ALIAS] resources.
- Do not uninstall ARCP or clear its data: the owner-signed APK and first-install record remain valid independently of
  connectivity.

## Implementation evidence

- Cloudflare tunnel `[REDACTED_RESOURCE_ID]` and proxied DNS record
  `[REDACTED_RESOURCE_ID]` were created by this plan. The tunnel read-back is healthy, its ingress and
  configuration digest match the tracked snapshot, and a second Terraform plan reports no changes.
- ARCP is bound to loopback on port 8080. The LAN probe is closed; public health, unauthenticated `401`, OAuth/OIDC
  discovery, bearer initialization and all-prefix tool discovery passed. The named tunnel survived the screen-off
  smoke and recovered after one controlled service restart. Reboot autostart is the sole pending device check.
- Codex CLI `0.152.1` registered the independent DCR client documented in `android/config.json`. `mcp get/list` report
  OAuth, and an isolated fresh process invoked `android_[REDACTED_DEVICE_ALIAS]_list_apps` and returned `[REDACTED_DEVICE_ALIAS]_CODEX_E2E_OK` after
  finding `com.google.android.apps.tv.launcherx`.
- ChatGPT account `[REDACTED_EMAIL]` created and connected the private application recorded in
  `chatgpt/connectors.json`. A forced action refresh discovered 62 `android_[REDACTED_DEVICE_ALIAS]_` actions. New chat
  `[REDACTED_RESOURCE_ID]` selected `[REDACTED_DEVICE_ALIAS]`, invoked the read-only `list_apps` action and returned
  `[REDACTED_DEVICE_ALIAS]_CHATGPT_E2E_OK` for the Google TV launcher package.
