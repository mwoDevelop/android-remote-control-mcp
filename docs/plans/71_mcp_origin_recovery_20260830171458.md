<!-- REVIEW APPLIED — implementation baseline; amend only with a new dated review note. -->
<!-- Preserve unrelated worktree changes and never record credentials, tokens, PINs or raw OAuth client IDs. -->

# Plan 71 — Recover a dead MCP origin behind a healthy Cloudflare tunnel

Eliminate the availability gap observed on [REDACTED_DEVICE_ALIAS] on 30 August 2026: Cloudflare kept three healthy tunnel connections,
but `http://localhost:8080` temporarily stopped serving, so the public `/health`, OAuth metadata and `/mcp` all returned
Cloudflare `502`. The Android service recovered several minutes later, but the interrupted Codex task failed. Deliver the
fix in two stages: [REDACTED_DEVICE_ALIAS] first, then the identical qualified build on [REDACTED_DEVICE_ALIAS] only after [REDACTED_DEVICE_ALIAS] passes the stability gates.

## Verified incident facts

- At 16:57 CEST [REDACTED_DEVICE_ALIAS] still accepted MCP calls; the screen was successfully woken and Accessibility could read the lock
  screen.
- At 16:58 CEST a direct authenticated request received Cloudflare `502`; independent probes confirmed `502` for
  `/health`, OAuth discovery and `/mcp`.
- Cloudflare reported tunnel `Xiaomi11T` as `healthy`, with three established connectors and no pending reconnect. DNS
  was correct. Therefore the failed component was the local MCP origin, not Cloudflare edge or tunnel connectivity.
- At approximately 17:03 CEST the same endpoint recovered without a tunnel reconfiguration: `/health=200`, OAuth
  discovery `=200`, unauthenticated `/mcp=401`.
- Existing recovery watches the `cloudflared` process and tunnel state, but it does not independently verify that the
  local Ktor origin still answers while the tunnel remains connected.
- The exact reason for the origin loss (uncaught crash, Android/OEM process kill, or listener failure inside a live
  process) was not observable because ADB/logcat was intentionally disabled. The implementation must improve both
  recovery and durable post-mortem evidence without pretending that this cause is already known.

## Fixed architecture and OCP decisions

- New recovery policy, probe, diagnostics and orchestration live in the fork-owned app package
  `com.mwodevelop.androidremotecontrolmcp.recovery`. The generic origin watchdog does not belong to `:shizuku-admin`.
  It depends on narrow callbacks and does not import or modify upstream UI, MCP transport, OAuth or Cloudflare
  implementations.
- The extension is installed as a private, non-exported process initializer in the fork manifest. It observes the public
  `McpServerService.serverStatus`, singleton `TunnelManager.tunnelStatus` and persisted `server_running` intent through a
  narrow Hilt entry point. No upstream service, restart-helper, transport or application class is modified.
- `McpServer`, the MCP SDK server, OAuth routes, tool registry and tunnel providers remain unchanged. No inheritance
  from upstream concrete classes and no copied upstream implementation is allowed.
- The health source is the real loopback HTTP `GET /health`, not `McpServer.isRunning()` and not tunnel status alone.
  `isRunning()` is only an intent flag and cannot prove that Netty is listening.
- Probe only after the server reports `Running`, only for HTTP tunnel mode, and only while `TunnelStatus.Connected`.
  Tunnel-disconnected errors remain owned by the existing tunnel recovery path.
- A short startup grace period and consecutive-failure threshold prevent restart loops during startup, transient GC,
  device sleep transitions and tunnel handoff. A healthy result resets the failure count.
- Origin failures use one recovery coordinator and one persistent circuit breaker. Allow at most two automatic recovery restarts in a
  rolling ten-minute window; reset the budget only after five continuous healthy minutes or an explicit local
  `ACTION_START`, never on an automatic generation start.
- Explicit user stop must never be resurrected. It first invalidates the coordinator generation and cancels any delayed
  callback, then persists `server_running=false`. Every delayed callback rechecks its generation token and the persisted
  intent immediately before starting the service. A stale callback is a no-op.
- Do not add a generic remote restart/kill/debug MCP tool. Deterministic failure injection is test-only or ADB-only and
  must not remain in the production MCP surface.
- Do not add a permanent partial wake lock in the first implementation. First verify the existing battery exemption and
  collect `ApplicationExitInfo`/lifecycle evidence. Add a wake lock only through a separately reviewed plan if evidence
  shows CPU suspension rather than a dead listener/process.
- The in-process watchdog repairs a live process with a dead/unresponsive listener. It cannot run after Android kills
  the process; `START_STICKY`, boot/package restart behavior and OEM power settings remain the process-death controls.
  `ApplicationExitInfo` is diagnostic only and must not be presented as a recovery mechanism.
- No public hostname, DNS, tunnel token, OAuth registration, ChatGPT connector or tool schema changes are required.

## Recovery contract

1. Start the grace timer only after both the origin reports `Running` and the tunnel reports `Connected`; wait 20
   seconds before the first probe. A later disconnect cancels the timer and resets the consecutive-failure series.
2. While Cloudflare is connected, probe `http://127.0.0.1:<configured-port>/health` every 10 seconds with 2-second
   connect/read bounds.
3. Treat only HTTP `200` as healthy. Timeouts, connection refusal, malformed transport and non-200 responses are
   failures; log only the bounded failure category, never URLs with credentials or response bodies.
4. After three consecutive failures, submit `ORIGIN` to the recovery coordinator. If the circuit
   breaker permits it, persist one bounded server-log entry, stop the current service generation and schedule restart
   after the existing bounded delay. On exhaustion, expose a final error and do not loop.
5. On the next start, report the most recent Android `ApplicationExitInfo` reason and whether the previous service
   generation ended cleanly. This evidence must distinguish a controlled recovery from an unclean process exit where
   possible.
6. If the public tunnel is disconnected, the origin watchdog does nothing. Exhausted-tunnel recovery remains in the
   unmodified upstream service; combining both paths would require changing that upstream class and is deliberately not
   done under the user's stricter OCP/no-upstream-class-modification constraint.
7. Probe scheduling is best-effort while the foreground-service process is scheduled. Doze does not guarantee a probe
   every ten seconds; screen-off and forced-idle validation are recorded separately.

## Scope

Allowed implementation paths:

- `app/src/main/**/com/mwodevelop/androidremotecontrolmcp/recovery/**` and matching tests;
- the fork manifest declaration, private initializer/controller and focused recovery helpers/tests;
- manifest permission only if required by the final reviewed design;
- `scripts/tests/**` or existing deployment verification scripts for deterministic, secret-free gates;
- this plan, root documentation and `myconf/[REDACTED_DEVICE_ALIAS]/**`, `myconf/[REDACTED_DEVICE_ALIAS]/**` acceptance records.

Out of scope: changing MCP authentication, broadening trusted OAuth clients, changing the unlock policy, adding an MCP
restart primitive, changing Cloudflare/Regery/ngrok, resetting application data, uninstalling the production app,
changing PINs, enabling permanent remote debugging, or rewriting upstream service/transport classes.

## User Story 1 — OCP recovery extension

- [x] Add a small `OriginHealthProbe` boundary and loopback HTTP implementation with bounded timeouts and no response
  body logging.
- [x] Add a pure `OriginRecoveryPolicy` state machine covering startup grace, connected/disconnected gating,
  consecutive failures and healthy/disconnected reset.
- [x] Add `OriginRecoverySupervisor` that owns the coroutine/timing mechanics and exposes only start/stop plus a
  recovery callback.
- [x] Add a `RecoveryCoordinator` with persistent rolling-window circuit breaker, injected clock, cancellable scheduler
  and generation token. It never revives an explicit stop.
- [x] Add a lifecycle/exit diagnostic adapter that reports a bounded Android exit-reason category and an unclean prior
  generation marker without storing process arguments, URLs, tokens or client IDs.
- [x] Keep all policy logic and Android adapters in new fork-owned files; the upstream service integration must remain
  declarative and small.

## User Story 2 — OCP process integration

- [x] Install one non-exported fork-owned initializer through the manifest; do not edit upstream-owned classes.
- [x] Start supervision only when the public server status is `Running` and tunnel status is `Connected`; derive the
  configured port from the running status.
- [x] On `RecoveryRequired`, submit the reason to the coordinator, stop the service without changing persisted intent,
  and wait for public `Stopped` before scheduling a restart.
- [x] The delayed callback must verify its generation and the bounded read of persisted `server_running`; an
  unreadable/timed-out intent fails closed.
- [x] Stop/cancel the supervisor on disconnect/stop, and mark a clean service generation only after Running→Stopped.
- [ ] Prove normal start, explicit stop, upstream tunnel recovery and package-update recovery remain unchanged.

## User Story 3 — Automated verification

- [x] Unit-test policy transitions: grace, first/second/third failure, healthy reset, disconnected tunnel and duplicate
  callbacks.
- [x] Unit-test HTTP probe classification with a local test server plus refused connection, timeout and non-200 cases.
- [x] Unit-test lifecycle diagnostics and redaction; raw exception text/response body must not enter durable logs.
- [x] Inject monotonic clock, delay/scheduler, dispatcher and transport probe so unit tests use virtual time rather than
  sleeping.
- [x] Test third-failure versus explicit-stop races, stale callbacks from an old generation, a new explicit start during
  teardown, persisted-intent timeout and a late probe after cancellation.
- [x] Test that the process integration starts/stops the extension and schedules exactly one restart without reviving
  an explicit stop.
- [ ] Run formatting, detekt, unit tests for `:shizuku-admin` and `:app`, relevant integration tests, merged-manifest
  checks and the repository deployment-script test suite.
- [ ] Build one qualified owner-signed `gmsRelease` artifact; verify package ID, version, certificate digest, APK digest
  and qualified build manifest. The exact same APK must be promoted from [REDACTED_DEVICE_ALIAS] to [REDACTED_DEVICE_ALIAS].

## User Story 4 — [REDACTED_DEVICE_ALIAS] staged deployment and stabilization

- [x] Before enabling ADB, confirm public baseline: `/health=200`, OAuth discovery `=200`, unauthenticated `/mcp=401`,
  Cloudflare tunnel connected, no Wi-Fi listener on port 8080.
- [x] Use a short, explicitly bounded ADB deployment window; verify the device identity and production signer before
  `adb install -r`. Preserve application data and stop on any signer/identity mismatch.
- [x] Verify Android battery-optimization exemption and Samsung background policy. Record the state; do not silently
  change unrelated power or administrator settings.
- [x] Install the reviewed owner-signed release, restore/restart only the saved ARCP service configuration if required, and verify
  ordinary MCP, OAuth, bearer admin, Shizuku and protected-package denial regressions.
- [ ] Run controlled listener-recovery acceptance with a local-only, fixed ADB test hook when available; otherwise use
  an equivalent non-production failure harness. A release build must expose no parameterized or remote failure tool.
  Observe `200/401 -> temporary failure -> 200/401` without data loss or manual ARCP restart.
- [ ] Separately induce a non-destructive process death and record `START_STICKY`/OEM recovery plus bounded
  `ApplicationExitInfo`; do not count it as proof of the in-process watchdog.
- [x] Run at least a 15-minute screen-off soak plus a separate forced-idle check with repeated external `/health`
  probes, then one sleep/unlock cycle
  and a normal read-only MCP call. Any unexplained `502` or manual restart fails the [REDACTED_DEVICE_ALIAS] gate.
- [ ] Disable Wireless/USB debugging and verify known ADB ports are closed before declaring [REDACTED_DEVICE_ALIAS] stable.

## User Story 5 — [REDACTED_DEVICE_ALIAS] promotion after [REDACTED_DEVICE_ALIAS]

- [x] Treat [REDACTED_DEVICE_ALIAS] as the regression/stabilization stage. Begin [REDACTED_DEVICE_ALIAS] only after every applicable [REDACTED_DEVICE_ALIAS] item passes and the
  artifact digest is frozen; [REDACTED_DEVICE_ALIAS] remains the actual incident acceptance gate.
- [x] Reconfirm [REDACTED_DEVICE_ALIAS] baseline, identity, signer, battery exemption and MIUI background/autostart policy.
- [x] Deploy the exact [REDACTED_DEVICE_ALIAS]-reviewed APK using `adb install -r`, preserving data and the existing ChatGPT trusted
  OAuth binding.
- [ ] Repeat controlled recovery with logcat/exit evidence, public endpoint monitoring and no manual server restart.
- [x] Run at least a 15-minute locked-screen soak, then verify wake, locally authorized sleep/unlock, ordinary
  MCP and bearer-only privileged regressions.
- [ ] Disable Wireless/USB debugging and externally verify ADB ports are closed. Public `/mcp` must still reject an
  unauthenticated request with `401`.

## User Story 6 — Documentation and delivery

- [x] Before either install, record current APK digest, signer digest and a known-good rollback APK. If a gate fails,
  reinstall the matching signed rollback with `adb install -r` and preserve data; never uninstall/reset as rollback.
- [x] Record the recovered incident, thresholds, lifecycle evidence, [REDACTED_DEVICE_ALIAS]-first promotion results and residual Android
  scheduling limits in root and per-device documentation.
- [x] Preserve all pre-existing dirty worktree changes; stage only reviewed Plan 71 paths and explicitly reconciled
  acceptance-document overlaps.
- [x] Audit Git-tracked files, staged diff, logs and generated reports for secrets. `.env.secrets`, PINs, bearer/tunnel
  tokens, signing material and raw OAuth client IDs must remain untracked and absent from output artifacts.
- [x] Commit plan/review, implementation/tests and live acceptance evidence separately. Push only after [REDACTED_DEVICE_ALIAS] passes and
  confirm local `main` equals `origin/main`.

## Live rollout record — 30 August 2026

The owner-signed `gmsRelease` artifact `1.12.0-dev.82+f7ff992` (`versionCode 20010151`) had APK SHA-256
`[REDACTED_RESOURCE_ID]` and signer SHA-256
`[REDACTED_RESOURCE_ID]`. The installed predecessor was pulled from
each device before `adb install -r`; both predecessors had APK SHA-256
`[REDACTED_RESOURCE_ID]` and the same signer.

[REDACTED_DEVICE_ALIAS] passed identity/signer preflight, ordinary/OAuth/bearer/Shizuku/protected-package regressions and 30 consecutive
screen-off/deep-Doze samples over 15 minutes with `/health=200`, OIDC `=200`, and unauthenticated `/mcp=401`. [REDACTED_DEVICE_ALIAS]
then received the exact same APK and passed the same 30-sample soak. An authenticated MCP call also succeeded during
[REDACTED_DEVICE_ALIAS] deep Doze. The first post-Doze unlock met a cold Shizuku binder timeout; the bounded retry succeeded and the
local `trusted` state remained active.

MIUI did not resume the MCP foreground service after package replacement, so one local `Start` action was required;
the saved configuration and OAuth binding were retained. No DNS, tunnel, tool schema, Codex server definition or
ChatGPT plugin mutation was required. On both phones, disabling both ADB modes terminated the non-root Shizuku server.
The final least-privilege state therefore keeps locally required USB debugging enabled, disables Wireless debugging,
closes the observed wireless ADB ports, and leaves LAN port `8080` closed. Shizuku admin calls passed after this
cleanup.

The release intentionally contains no failure-injection hook. Deterministic dead-listener recovery is covered by the
focused supervisor/integration tests, but a live in-process listener failure and a separate safe process-death test
remain unchecked above. The build is owner-signed and reviewed, but not labeled `qualified=true`, because the global
detekt task still reports 149 pre-existing findings outside the fork-owned recovery paths. These boundaries must not
be rewritten as completed live evidence.

## Acceptance criteria

The change is complete only when the independent review has been applied; automated gates pass; one owner-signed APK
recovers automatically from a controlled live-process listener failure on [REDACTED_DEVICE_ALIAS] and then [REDACTED_DEVICE_ALIAS]; process-death behavior is
separately evidenced; both devices survive the
locked-screen soak without unexplained `502`; existing OAuth/bearer/Shizuku/unlock security behavior is unchanged;
debug access is closed; no secret is tracked; and the final commits are present on `origin/main`.

If [REDACTED_DEVICE_ALIAS] cannot meet the gate, [REDACTED_DEVICE_ALIAS] deployment is forbidden. If the live evidence shows the process is killed before an
in-process supervisor can act, classify that as a distinct process-survival failure and amend this plan with a
separately reviewed process-survival mechanism instead of claiming the loopback watchdog solved it.

## Independent review applied

The independent review returned **REVISE**. This revision applies all material findings: it separates listener failure
from process death; replaces the per-generation allowance with a persistent rolling circuit breaker; closes the
explicit-stop/stale-callback race with generation tokens and a persisted-intent recheck; documents Doze as best-effort;
makes [REDACTED_DEVICE_ALIAS] the regression stage and [REDACTED_DEVICE_ALIAS] the incident gate; moves generic recovery out of `:shizuku-admin`; requires
injected time/probe dependencies and race tests; forbids a release failure-injection primitive; and adds
signer/digest-based rollback. The recommendation to unify origin/tunnel arbitration was superseded by the user's stricter
OCP requirement: the existing upstream tunnel path stays untouched and the new extension owns only origin recovery. Recovery constants remain local to the fork extension, loopback
ports are validated, redirects/proxies are disabled, response bodies are always closed, and durable logs contain only
bounded categories/timestamps/importance.
