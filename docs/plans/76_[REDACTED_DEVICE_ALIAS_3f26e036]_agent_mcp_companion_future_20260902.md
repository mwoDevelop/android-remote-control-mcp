<!-- DEFERRED DESIGN ONLY — do not implement, deploy, publish or mutate device/cloud/account state from this plan. -->
<!-- Never commit model credentials, bearer/OAuth/tunnel tokens, browser sessions, voice recordings or device-derived private data. -->

# Plan 76 — BedTV Agent: voice companion with broad ARCP MCP access

Design a future, separately released Android TV companion named `BedTV Agent` that gives the Bedroom TV user a
conversational interface to as many of the ARCP tools as the device can actually execute. Preserve the built-in Google
Assistant/Gemini experience for launching the companion and for a small set of immediate Google Home commands, but do
not pretend that the built-in TV assistant can currently load an arbitrary MCP server or dynamically use all ARCP
tools.

This document records the idea and a proposed delivery path only. No implementation, repository creation, account
configuration, Google Home project, Firebase project, release, installation or permission change is authorized yet.

## Why this project exists

The desired experience is broader than a conventional Google Home television integration. The user should eventually
be able to say, for example:

- "open Kodi and find the subtitle settings";
- "read the current screen, select the Polish track and check that it stayed selected";
- "open the application settings and tell me which option is enabled";
- "start movie mode", where the agent performs a reviewed sequence of app, playback and volume operations.

Google Home traits can express fixed commands such as application selection, playback, volume, input, channel, modes,
toggles and scenes. They cannot expose an arbitrary MCP catalog with rich JSON parameters, return a screen tree or
screenshot to the model, or let the model plan a multi-step UI interaction. Encoding every ARCP tool as a fake smart
home toggle would be brittle, unsafe and semantically misleading.

The proposed solution is therefore hybrid:

1. The built-in TV assistant remains the native entry point and may handle a small, explicit set of fast commands.
2. A separate `BedTV Agent` Android TV application becomes the real conversational agent and MCP client.
3. The companion discovers ARCP tools dynamically and performs multi-step tool use under a local policy and approval
   layer.

## Verified baseline on 2026-09-02

Treat every item below as a dated observation that must be rechecked before implementation:

- Bedroom TV is a [REDACTED_OWNER_VALUE] (`kirkwood`) running Android 14 / API 34 with a 32-bit Android userspace exposing
  `armeabi-v7a,armeabi`.
- The configured default voice interaction service is `com.google.android.katniss`, the Google TV
  Assistant/search service.
- The owner ARCP edge build is installed and running. It binds the origin to `127.0.0.1:8080`; LAN port 8080 remains
  closed.
- The persistent endpoint is `[REDACTED_OWNER_VALUE]`. Its health, OAuth metadata, authenticated MCP
  initialization, `tools/list` and a read-only `list_apps` call passed during the latest inspection.
- The live server advertised 62 `android_[REDACTED_DEVICE_ALIAS]_*` tools. Accessibility was enabled in the live Android setting even
  though an older captured configuration snapshot still described it as not granted; live state wins and the snapshot
  must be refreshed separately when operational documentation is next reconciled.
- ARCP OAuth and bearer authentication are enabled. The existing ChatGPT and Codex clients have distinct DCR
  registrations; their credentials must not be reused by the future companion.
- Shizuku/admin support was not configured for BedTV in the recorded profile. Camera, location, storage and other
  runtime capabilities were not fully qualified.
- Google Play reported the official ChatGPT Android application as incompatible with this TV. Sideloading a mobile UI
  is not a foundation for this project.

## External platform boundary

Current Google documentation establishes the following boundary:

- [Gemini for TV](https://support.google.com/googletv/answer/16522213) is a TV-specific product with availability tied
  to device, region, language, age and account; it is not the same surface as the mobile or web Gemini application.
- [Gemini Spark custom MCP apps](https://support.google.com/gemini/answer/17209137) are currently documented for the
  Gemini mobile and web applications, not Gemini for TV.
- [Conversational Actions](https://developers.google.com/assistant/ca-sunset), the former generic Assistant extension
  mechanism, were retired in 2023.
- [App Actions](https://developer.android.com/develop/devices/assistant/overview) are documented for Android phones,
  not as a general custom-action mechanism for Google TV.
- [Google Home TV traits](https://developers.home.google.com/cloud-to-cloud/guides/tv) remain suitable for a bounded
  set of television commands but do not speak MCP.

Consequently, the strict requirement "the built-in Katniss/Gemini for TV process itself must become a full MCP client"
is not implementable through a supported public integration at the time of this plan. The closest supported user
experience is a voice-launched companion, with an optional Google Home bridge for short commands.

## Target user experience

### Fast path — built-in assistant

The user speaks a fixed command to the built-in assistant, for example:

- "open BedTV Agent";
- "open Kodi on Bedroom TV";
- "pause Bedroom TV";
- "mute Bedroom TV";
- "start movie mode".

Application launch should use the native Google TV application launcher. Other fast commands may later use a private
Google Home Cloud-to-cloud test integration and a narrow fulfillment bridge. They are conveniences, not the primary
full-tool interface.

The built-in assistant is not expected to forward the original arbitrary utterance to the companion. The normal flow
may therefore be two-step: launch `BedTV Agent`, then speak the actual request inside it. Any future one-step handoff
must be proven with a documented Google TV API before it is included in scope.

### Full path — BedTV Agent

After launch, the companion presents a TV-friendly, D-pad accessible conversation screen and starts a push-to-talk or
bounded listening session. It can continue as a foreground service when an ARCP action opens another application. The
conversation state must survive the companion UI moving to the background, and spoken/visual confirmations must remain
clear about which device and action are targeted.

The intended execution loop is:

```text
remote microphone or text input
          |
          v
voice/text adapter -> model session -> requested function call
                                         |
                                         v
                              policy and approval engine
                                         |
                                         v
                              MCP client -> ARCP /mcp
                                         |
                                         v
                            normalized result -> model -> TTS/UI
```

## Repository and release decision

Create `BedTV Agent` as a separate project and separate Git repository, not as a Gradle module inside the ARCP fork.
The working name is `[REDACTED_DEVICE_ALIAS]-agent`; the final package ID must be owner-controlled and different from every ARCP package.

Reasons:

- ARCP upstream merges remain isolated from agent UI, model SDK and voice dependencies.
- The companion and ARCP have independent release, signing, rollback and compatibility lifecycles.
- The client depends only on the MCP protocol and can later control other MCP servers.
- A failed companion upgrade cannot replace or corrupt the ARCP server application.
- Model providers and voice implementations can be changed without modifying ARCP.

The current `android-remote-control` repository may later retain only integration-owned material under
`myconf/[REDACTED_DEVICE_ALIAS]/[REDACTED_DEVICE_ALIAS]-agent/`, such as a non-secret deployment manifest, pinned companion release/version/hash, expected
package/certificate identity and smoke-test metadata. It must not vendor the companion source, generated APK or signing
material. Avoid a Git submodule unless a concrete reproducibility need outweighs its operational overhead; a pinned
release manifest is the simpler default.

## Proposed companion architecture

Use interfaces and adapters so each volatile dependency remains replaceable:

1. **Android TV shell** — Compose/TV or Leanback-compatible UI, D-pad focus, large confirmation panels, lifecycle and
   foreground-service ownership.
2. **Voice input adapter** — initially Android speech recognition or another proven TV-compatible recognizer; Gemini
   Live is an optional adapter, not a hard dependency.
3. **Voice output adapter** — Android TTS first; streamed native audio is optional.
4. **Model adapter** — model-agnostic conversation and function-call interface. A Gemini implementation is the first
   candidate, but OpenAI or another provider must not require rewriting the MCP/policy layers.
5. **MCP client** — Streamable HTTP initialization, notification, tool discovery, invocation, timeout, cancellation,
   retry and structured error handling.
6. **Tool schema adapter** — converts supported MCP JSON Schemas to provider function declarations and validates model
   arguments again before MCP invocation.
7. **Capability resolver** — hides or marks unavailable tools based on hardware, Android permissions, Accessibility,
   notification access, SAF storage grants and Shizuku readiness.
8. **Policy engine** — assigns risk, caller, data-flow and confirmation requirements independently of the model.
9. **Approval UI** — local, explicit and non-spoofable confirmations; sensitive actions cannot be approved solely by
   spoken input or model output.
10. **Session/audit store** — bounded metadata about tool name, decision, duration and outcome, never raw secrets,
    passwords, screenshots, file contents, notification bodies or unrestricted prompts by default.
11. **Optional Google Home bridge** — a separately deployable adapter for native assistant fast commands. It maps
    Google Home intents to a strict ARCP allowlist and is not part of the full MCP loop.

No component may import, subclass or copy an ARCP concrete implementation. MCP is the integration boundary.

## Voice and model recommendation

Start with a stable chained path:

```text
speech recognition -> text Gemini request -> function calls -> text answer -> Android TTS
```

[Firebase AI Logic for Android](https://firebase.google.com/docs/ai-logic) currently offers Android SDKs, function
calling, multimodal input, audio capabilities and App Check protection without embedding a raw Gemini API key in the
APK. Confirm its actual ARMv7/runtime compatibility on BedTV before selecting it.

Keep [Gemini Live API](https://firebase.google.com/docs/ai-logic/live-api) behind the voice/model interfaces. It offers
low-latency bidirectional audio and function calling but is currently Preview and has no stability/SLA guarantee. A
Live API incompatibility or service change must fall back to the chained path.

The provider choice is separate from the signed-in Google TV account. API project, billing, quota, data retention and
regional availability must be explicitly accepted before implementation; a Google TV subscription must not be assumed
to include Gemini API use.

## MCP connection and identity

Prefer a dedicated OAuth/DCR identity named conceptually `[REDACTED_DEVICE_ALIAS]-agent`:

- register it independently of ChatGPT and Codex;
- perform the initial authorization with a visible on-device approval;
- store refresh/access credentials in Android Keystore-backed storage;
- never place an access token, refresh token or bearer in Git, logs, crash reports, command arguments or screenshots;
- configure the exact OAuth client identity for privileged tools only after a separate administrator decision.

The public Cloudflare MCP URL is the conservative first integration target because its OAuth metadata and resource
identity are already configured and qualified. A same-device loopback path would remove an unnecessary cloud round trip,
but it must not be assumed that a public-resource OAuth token is valid for `127.0.0.1`. During the feasibility spike,
test discovery, audience/resource validation and token use on loopback without changing ARCP. Select one of these only
after evidence:

1. **Public OAuth path** — companion -> Cloudflare -> ARCP; simplest identity reuse, internet-dependent.
2. **Loopback OAuth path** — only if existing ARCP metadata/token validation supports it securely without upstream
   modifications.
3. **Loopback bearer path** — last resort; the single bearer is broader and must be provisioned through stdin/local UI,
   stored in Keystore and never shared with the model provider.

Do not disable ARCP authentication merely because the listener is loopback-only. Another application on the device may
still attempt to reach it.

## Tool discovery at scale

The companion should make every currently advertised ARCP tool discoverable, but it must not assume that all 62 JSON
schemas fit the selected model's function-count, schema-subset or context limits forever.

Use two-stage selection:

1. Build a local catalog from MCP `tools/list`, including name, description, schema, risk and capability requirements.
2. A deterministic/semantic router selects relevant namespaces for the current request (screen, navigation, node,
   text, apps, files, notifications, camera, location, sharing or admin).
3. Pass only the relevant validated function declarations to the model.
4. If a schema cannot be represented faithfully, fail closed or use a carefully validated generic invocation adapter;
   never silently drop constraints such as enums, required fields, numeric bounds or path restrictions.
5. Re-fetch the catalog on server/version change and invalidate incompatible cached schemas.

This provides access to the entire catalog over a session without requiring every tool to be present in every model
turn. The model must never invent an unadvertised tool name.

## Capability expectations on BedTV

All advertised tools may be registered in the catalog, but "advertised" does not mean "usable". Resolve availability
before model exposure:

- screen, node, touch, gesture, text and navigation tools require the ARCP Accessibility service;
- application listing/open/close can be available without extra hardware;
- notification tools require Notification Listener access;
- file tools depend on app-owned storage and user-granted SAF/MediaStore locations;
- camera tools require an Android-compatible camera, likely an external USB device on this hardware;
- microphone-based video and the companion's voice input require independently granted audio access;
- location may be unavailable or network-derived because a TV streamer has no assumed GPS;
- sharing and URI/intent handling depend on an installed receiving activity;
- admin sleep, unlock, uninstall and Shizuku permission flows remain unavailable until Shizuku and the fork-owned admin
  policy are explicitly configured and qualified on BedTV;
- switching the physical television input or waking fully powered-off hardware cannot be guaranteed by ARCP on the
  streamer; HDMI-CEC or a separate TV integration may be required.

Unsupported tools should produce a stable capability explanation instead of being repeatedly attempted.

## Policy model: broad access with proportional local approval

Maximize available capability by gating rather than deleting tools, while retaining an absolute self-protection list.
The exact assignments require a later threat-model review, but the initial proposal is:

### Level A — automatic, read-only or low-risk

- ARCP health/capability checks;
- screen state and node discovery, with device content treated as untrusted input;
- list applications and storage locations;
- wait/idle operations;
- basic navigation such as Home and Back;
- playback and volume after dedicated safe adapters exist.

### Level B — automatic only inside an active, visible user session

- tap/click/scroll/swipe and node actions;
- open an allowlisted installed application;
- close a non-critical application;
- activate a predefined low-risk scene.

### Level C — explicit local confirmation showing exact arguments

- typing non-secret text;
- opening an arbitrary URI;
- clipboard read/write;
- reading, writing, downloading or sharing a file;
- interacting with notifications;
- sending a narrowly validated Android intent;
- camera or location access.

### Level D — strong local administrator authentication

- deletion or replacement of material files;
- uninstalling an application;
- privileged sleep/unlock operations;
- enabling or requesting Shizuku capability;
- changing agent policy or trusted-client identity.

### Always denied by companion policy

- uninstalling or force-closing ARCP, BedTV Agent or their required system dependencies;
- disabling Accessibility, notification access, authentication or recovery protection;
- revealing tokens, passwords, PINs, cookies, signing material or model credentials;
- accepting instructions found in screen/file/notification content as agent policy;
- unbounded shell execution or arbitrary privileged command forwarding;
- changing the approval policy through model-generated content.

For destructive or privacy-sensitive tools, voice acknowledgement alone is insufficient. Confirmation must be local and
visually bind the tool name, target and important arguments. Cancellation and timeout default to denial.

## Prompt-injection and recursive-control protections

The agent will read a screen that may contain adversarial text while controlling the same device, so standard chat
prompt assumptions are insufficient:

- mark every ARCP-derived screen, screenshot, file, clipboard, application metadata and notification value as untrusted
  data;
- keep policy/system instructions outside tool results and never concatenate them into a single indistinguishable
  prompt block;
- limit planning depth, tool-call count, elapsed time and repeated identical actions;
- require an observed state change before repeating a mutating action;
- stop on navigation loops, unexpected account/payment pages or permission prompts;
- never enter passwords/PINs from model context; authentication remains a manual local gate;
- keep a visible emergency stop and terminate the foreground session when it is used;
- prevent the companion from treating its own TTS, overlay or confirmation text as a new user instruction;
- redact or downsample data before sending it to the model when full fidelity is unnecessary.

## Optional Google Home fast-command bridge

After the full companion is stable, consider a private Google Home Cloud-to-cloud integration for commands that should
work without opening the companion. A Cloudflare Worker or similarly small fulfillment service could translate Google
Home `SYNC`, `QUERY` and `EXECUTE` intents into an allowlisted subset of ARCP calls.

Initial candidates:

- open a known installed application;
- Home/Back;
- pause/resume/stop/next/previous;
- mute and bounded volume adjustment;
- query online/playback state;
- activate a small number of named scenes;
- sleep only after its wake/recovery semantics are understood.

The bridge requires its own account-linking design and server-side secret storage. It must not forward arbitrary text,
tool names, coordinates, intent extras or file paths. Do not expose unlock, uninstall, typing, files, clipboard,
notifications, camera or location through an unauthenticated household voice command. Use Voice Match and supported
secondary verification where available, but do not treat them as equivalent to local strong authentication.

## Delivery plan for a future implementation

### Phase 0 — revalidation and feasibility spikes

1. Re-fetch ARCP upstream and local release/channel state without changing either repository.
2. Re-verify BedTV model/API/ABI, free storage, installed ARCP certificate/version, loopback listener, tunnel and all
   live special permissions.
3. Record the current 62-tool catalog, schemas and tool-level permission results without destructive calls.
4. Test whether the Bluetooth/voice remote microphone is available to an ordinary foreground Android TV application.
5. Build the smallest ARMv7 Android TV APK using the candidate Firebase/Gemini SDK and prove install, launch, network,
   function call and D-pad operation.
6. Measure the model's current tool-count/schema limits and identify incompatible JSON Schema constructs.
7. Test public OAuth/DCR and, separately, whether the resulting resource token can securely call loopback.
8. Recheck current Google TV, Gemini, Firebase AI Logic, Live API and Google Home terms, regions, pricing and
   availability. Any result may invalidate a dated assumption in this plan.
9. Stop and present feasibility evidence before creating production cloud resources or changing device permissions.

### Phase 1 — independent `[REDACTED_DEVICE_ALIAS]-agent` foundation

1. Create the separate repository with an owner-controlled namespace, license decision, Android TV launcher, minimum
   supported API/ABI contract and reproducible Gradle wrapper.
2. Add CI for unit tests, lint, secret scanning, release certificate verification and ARMv7 artifact inspection.
3. Define narrow interfaces for voice, model, MCP transport, policy, approvals, capability probing and audit events.
4. Add a TV-native text-only shell before adding microphone or model access.
5. Establish independent semantic versioning, owner signing and immutable GitHub Releases.

### Phase 2 — MCP client and catalog

1. Implement Streamable HTTP MCP initialization, tool listing, calls, cancellation and bounded retry.
2. Add OAuth/DCR onboarding with manual on-device approval and Keystore-backed credential storage.
3. Implement catalog refresh, namespace routing and schema conversion with fail-closed validation.
4. Add capability probes for every permission/hardware-dependent category.
5. Prove read-only calls against BedTV, then reversible navigation/app calls.

### Phase 3 — text agent and safety layer

1. Integrate a text model adapter using function calling.
2. Enforce policy before every tool call; model output can request but never authorize an operation.
3. Implement visible confirmations, strong administrator gates, timeout/cancel and emergency stop.
4. Add prompt-injection separation, response-size limits and image/file disclosure controls.
5. Add session budgets for steps, time, repeated actions and model/tool failures.
6. Test multi-step interaction while the companion moves to the background.

### Phase 4 — voice interaction

1. Add push-to-talk using the proven TV microphone path.
2. Add transcription preview/correction before high-impact actions.
3. Add Android TTS with interruption, cancellation and loopback/echo protection.
4. Optionally add Gemini Live behind the same interfaces and retain the stable fallback.
5. Verify foreground-service behavior with screen on/off, app switching, Doze and network interruption.

### Phase 5 — built-in assistant entry and fast commands

1. Ensure the built-in assistant can reliably launch `BedTV Agent` by application name.
2. Decide whether the value of one-step commands justifies a Google Home Cloud-to-cloud project.
3. If approved, implement only the narrow TV-trait bridge, account linking and state reporting.
4. Test commands from BedTV itself and from another authorized Home surface.
5. Keep bridge and companion policies consistent, with the bridge always the narrower caller.

### Phase 6 — release, deployment and operations

1. Publish a signed immutable pre-release with provenance and hashes.
2. Extend the existing owner deployment tooling to accept a pinned companion release and expected signing certificate,
   without coupling its build to ARCP.
3. Install only on BedTV first; do not deploy to [REDACTED_DEVICE_ALIAS]/[REDACTED_DEVICE_ALIAS] without a separate decision.
4. Run the complete E2E and security suite with remote debugging disabled for final runtime checks.
5. Record only non-secret version, hash, certificate, OAuth client identifier and qualification status under
   `myconf/[REDACTED_DEVICE_ALIAS]/[REDACTED_DEVICE_ALIAS]-agent/`.
6. Define independent rollback: downgrade/remove the companion without changing ARCP configuration or its connectors.

## Test strategy

### Unit and contract tests

- MCP initialize/list/call, empty responses, HTTP errors, OAuth expiry and cancellation;
- conversion of every captured ARCP schema and rejection of unsupported/relaxed schemas;
- catalog routing makes all advertised tools reachable across namespaces;
- capability resolver hides unavailable camera/location/storage/Shizuku actions;
- every tool maps to exactly one policy class and unknown tools fail closed;
- confirmations bind exact arguments and cannot be replayed after timeout or reboot;
- sensitive values never enter logs, analytics or crash reports;
- critical package/self-protection deny rules cannot be overridden by remote configuration.

### BedTV E2E examples

1. Read screen -> locate a harmless node -> ask for confirmation if required -> click -> verify state change.
2. Open Kodi/YouTube -> navigate -> pause/resume -> return Home.
3. Enter clearly non-secret test text and verify exact content; confirm that password fields are refused.
4. Read and write a disposable app-owned test file; deny paths outside the granted location.
5. Exercise notification access only with a synthetic notification and remove it afterward.
6. Attempt camera/location/admin calls when unsupported and verify stable capability errors rather than loops.
7. Feed prompt-injection text through a test screen/file and verify that it is reported as data, not followed.
8. Try to close/uninstall ARCP and the companion and verify unconditional denial.
9. Background the companion by opening another app and complete the tool/result/TTS loop.
10. Interrupt network, ARCP origin and OAuth separately; verify bounded recovery and no duplicate actions.
11. Turn the screen off/on and reboot; verify explicit autostart/session policy without bypassing manual security gates.
12. Disable wireless/remote debugging and repeat representative read, navigation and voice cases.

### Regression boundaries

- Existing ChatGPT and Codex `[REDACTED_DEVICE_ALIAS]` connectors retain their independent OAuth clients and 62-tool discovery.
- ARCP remains bound to loopback and its Cloudflare endpoint remains authenticated.
- Installing/removing the companion does not change ARCP DataStore, Accessibility, tunnel, recovery or signing state.
- No new permission is granted silently and no Android restricted setting is bypassed.
- No secret or generated APK becomes tracked in either repository.

## Acceptance criteria

The future project is complete only when:

- the independently signed companion launches on the 32-bit BedTV build and is usable entirely with the TV remote;
- the companion dynamically discovers the live ARCP catalog and can route to every compatible tool namespace;
- unavailable hardware/permission tools are accurately reported and never retried blindly;
- representative multi-step UI, app, text, file and notification workflows pass with the expected approval levels;
- high-risk/admin calls require local approval and the self-protection deny list is proven;
- voice input/output remains usable after ARCP opens another application;
- the built-in assistant reliably opens the companion;
- any Google Home bridge exposes only its reviewed fast-command subset;
- final screen-off, reboot, network-loss and remote-debugging-off tests pass;
- rollback removes the companion without affecting ARCP, Cloudflare, ChatGPT or Codex;
- documentation records current limitations, costs, account dependencies and recovery steps without secrets.

## Important unresolved decisions

Resolve these only when the project is resumed:

1. Does the BedTV remote microphone work for a third-party foreground/foreground-service application?
2. Is Firebase AI Logic/Gemini the selected provider, or should a provider-neutral backend host the model session?
3. Is stable chained audio sufficient, or is the Preview Live API worth the operational risk?
4. Can secure OAuth calls use loopback, or should the companion intentionally use the existing Cloudflare route?
5. Which data classes may be sent to the model: screenshots, notification text, file bodies, clipboard and location?
6. Which tools need ordinary confirmation versus strong administrator authentication?
7. Should Shizuku ever be configured on BedTV, given reboot persistence and attack-surface costs?
8. Is the optional Google Home bridge useful enough to justify its cloud project, account linking, maintenance and
   potential certification constraints?
9. Should conversation history be ephemeral, local-encrypted or server-retained, and for how long?
10. Is an on-screen overlay needed while controlling other apps, and can it be implemented without broad overlay
    permissions or interference with Accessibility?
11. What model quota, billing cap, privacy policy and household/child access policy are acceptable?
12. Should the companion remain BedTV-specific or become a generic multi-device ARCP client after the first release?

## Explicit non-goals for the deferred project

- Modifying the built-in `com.google.android.katniss` package or pretending to replace Google Assistant.
- Patching upstream ARCP concrete classes to embed a model SDK or voice UI.
- Installing an unsupported ChatGPT/Gemini mobile APK as the production solution.
- Disabling MCP authentication, exposing port 8080 to the LAN or embedding credentials in the APK.
- Mapping arbitrary model output directly to Android shell/Shizuku commands.
- Publishing a public Google Home integration before the private owner use case is stable and policy-reviewed.
- Deploying to [REDACTED_DEVICE_ALIAS]/[REDACTED_DEVICE_ALIAS] as part of the BedTV-first project.

## Resume checklist

When work on this project is explicitly authorized later:

1. Read this plan and the then-current BedTV/ARCP runbooks.
2. Fetch upstreams and compare current stable/edge/local integration branches before choosing a baseline.
3. Re-run Phase 0 in full; do not trust the dated platform or device observations above.
4. Perform an independent architecture/security review and apply sensible findings to this plan before coding.
5. Obtain explicit approval for any Firebase/Google Cloud project, billing, Google Home account linking, new repository,
   device permission, Shizuku, installation, release or external-state mutation.
6. Implement incrementally with commits, secret scans, signed releases, BedTV-only deployment and E2E evidence.
