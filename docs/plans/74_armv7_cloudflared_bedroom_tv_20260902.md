<!-- COMPLETE — independently reviewed, released and qualified on Bedroom TV. -->
<!-- Never commit tunnel tokens, bearer credentials, signing material, device identifiers beyond documented model/IP, or generated APKs. -->

# Plan 74 — ARMv7 cloudflared and Bedroom TV edge rollout

Add `armeabi-v7a` support for the embedded Cloudflare connector so the existing ARCP application can run its tunnel
directly on the 32-bit Android userspace of Bedroom TV. Keep ngrok explicitly limited to its existing 64-bit ABIs,
publish a new immutable owner edge release, install the freshly downloaded release on Bedroom TV, and qualify both
the local MCP origin and the Cloudflare tunnel.

## Verified baseline and scope

- Bedroom TV is `[REDACTED_OWNER_VALUE]` (`kirkwood`, MediaTek `mt8696`) at `[REDACTED_PRIVATE_ENDPOINT]`, Android 14/API 34.
  Its Android userspace exposes only `armeabi-v7a,armeabi`, despite 64-bit-capable hardware.
- The current immutable edge release is
  `arcp-edge-16f39717ce09-07e5946270d8-vc21000001`. It has `minSdk=33`, includes general JNI payloads for
  `armeabi-v7a`, but embeds `libcloudflared.so` only for `arm64-v8a` and `x86_64`.
- The application is not installed on Bedroom TV. The device has Google Play Services and sufficient free storage.
- Official upstream edge remains `16f39717ce0969aa81a4ec132ba1cad861ba46cc`; current owner edge integration is
  `[REDACTED_RESOURCE_ID]`. No upstream application/runtime class needs modification.
- Scope is Cloudflare only. Do not add unsupported ARMv7 ngrok JNI, do not reuse another device's named tunnel token,
  do not alter [REDACTED_DEVICE_ALIAS]/[REDACTED_DEVICE_ALIAS] configuration, and do not weaken release signing or provenance checks.

## Design and compatibility contract

1. Extend the existing native build target with one Android/ARMv7 cross-compile, pinned to Go `1.26.7` and Android
   NDK `27.2.12479018`:
   `CGO_ENABLED=1 GOOS=android GOARCH=arm GOARM=7` using NDK
   `armv7a-linux-androideabi21-clang`. Package the executable as
   `app/src/main/jniLibs/armeabi-v7a/libcloudflared.so`, retaining legacy JNI extraction and execute permissions.
2. Keep one APK per GMS/FOSS release variant. ARMv7 is another payload in the universal APK, not another application
   flavor, package ID, release channel, or side-by-side installation.
3. Make one versioned, machine-readable native payload contract the semantic source of truth for every validator:
   - Cloudflare: `arm64-v8a`, `armeabi-v7a`, `x86_64`;
   - ngrok: `arm64-v8a`, `x86_64` only.
   Update local build, pre-sign, post-sign, download and feature-ledger verification so a missing ARMv7 cloudflared
   fails closed, while no validator incorrectly requires ARMv7 ngrok. Treat
   `armeabi-v7a/libngrok_java.so` as unsupported and forbidden.
4. Extend CI caches and every maintained build workflow that invokes `compile-cloudflared`. Cache keys continue to be
   content-addressed by the pinned cloudflared submodule, but also bind the versioned ABI contract, Makefile, pinned Go
   and NDK identities. Cached paths must include the ARMv7 binary, and a cache hit missing any required payload must
   rebuild or fail rather than being trusted.
5. Do not change `AndroidCloudflareBinaryResolver`: it already resolves the ABI-specific native library selected by
   Android. Treat a runtime resolver/process failure as a release blocker and add code only if device evidence proves
   the existing resolver is insufficient.
6. Record ARMv7 cloudflared in `config/arcp-channel-features.json`. The feature-contract digest must consequently
   change and be recorded in release provenance. Apply the common build/verification change to both reviewed channel
   branches, but publish only a new edge release in this rollout.
7. Extend the trusted artifact deployment helper with an explicit `bedroom-tv` identity and first-install mode. It
   must bind the exact device identity and absent pre-state, accept only the freshly verified GMS asset and owner
   signer, never choose an implicit sole ADB target, and record package/signer/version after installation.

## Test and release strategy

### Phase 1 — Plan and independent review

- [x] Record the verified device, source, ABI and release baselines in this plan.
- [x] Obtain an independent review focused on Android ARMv7 executable compatibility, asymmetric payload validation,
  cache poisoning/staleness, immutable release provenance, secrets and safe first installation.
- [x] Apply all sensible findings to this plan before production edits. Review decision: `approve-with-changes`; the
  accepted changes are centralized payload semantics, cache-contract invalidation, pinned toolchains, stronger ELF
  and installed-UID checks, explicit first-install deployment/rollback, branch-specific promotion and secure cleanup.

### Phase 2 — Contract-first implementation

- [x] Add failing shell contract tests that require every matrix entry, reject missing required cloudflared/ngrok
  payloads, accept the intentional absence of ARMv7 ngrok, and reject the unsupported ARMv7 ngrok payload.
- [x] Add a Makefile/build-contract test for the exact ARMv7 Go/NDK tuple and output path.
- [x] Implement the ARMv7 compilation target, the shared versioned payload-contract reader, workflow cache paths/keys,
  all still-runnable payload validators and the channel feature ledger without changing application runtime classes.
- [x] Run shell syntax checks, actionlint, focused release/build contract suites and feature-ledger validation.

### Phase 3 — Native and APK qualification

- [x] Build the pinned ARMv7 cloudflared locally. Verify ELF class/machine/type, EABI, Android linker, dynamic
  dependencies, non-W+X LOAD segments and 16 KiB alignment; execute `cloudflared --version` on Bedroom TV from a
  temporary shell-owned path.
- [x] Build and qualify GMS/FOSS edge artifacts through the existing secretless channel path. Confirm the APK contains
  exactly the required asymmetric tunnel payload and remains owner-signable.
- [x] Run the normal static, unit/integration and E2E-compile gates; any deterministic failure receives a focused
  regression test before retry.

Local evidence: the Go 1.26.7/NDK 27.2.12479018 build produced an ELF32 ARM EABI5 PIE using
`/system/bin/linker`, 16 KiB LOAD alignment, no W+X LOAD segment and only Android `liblog`, `libdl`, `libc`
dependencies. It executed `cloudflared --version` on the verified Bedroom TV. The full local GMS debug qualification,
including lint, unit/integration tests, E2E compilation and the exact five-entry tunnel matrix, passed.

### Phase 4 — Git channel promotion and immutable release

- [x] Audit tracked files and staged diff for secrets and generated native/APK/signing artifacts.
- [x] Commit the reviewed implementation on `main`, push it, and wait for required CI.
- [x] Advance `release/edge` through the reviewed `main` lineage. Backport only the common Makefile/contract change to
  divergent `release/stable` with `cherry-pick -x` and record patch identity; push only after channel tests and ancestry
  checks pass. Do not publish stable in this rollout.
- [x] Run the protected ARCP edge release workflow. Allocate a strictly greater ledger version code and create a new
  immutable `arcp-edge-*` identity; never modify or replace the previous release.
- [x] Download the published GMS APK into a fresh directory and independently verify assets, hashes, signer, package,
  version, source/submodule SHAs, pinned Go/NDK identities, payload-contract version/digest, feature-contract digest
  and all required native payloads. GMS and FOSS must have identical tunnel matrices and ledger metadata.

### Phase 5 — Bedroom TV deployment and E2E

- [x] Reconfirm `Bedroom TV`, IP/ADB identity, API and 32-bit ABI immediately before installation. Refuse a different
  target, signer mismatch, downgrade, incomplete release or skipped mandatory gate.
- [x] Deploy with the explicit `bedroom-tv` first-install path, without uninstall/data clearing. Confirm the previously
  absent package now has the exact release code and owner signer, Android selected `armeabi-v7a`, and the installed
  `nativeLibraryDir/libcloudflared.so` is ELF32 and is the binary actually executed by the ARCP application UID.
- [x] Start ARCP and use a tokenless Cloudflare quick tunnel for this qualification; do not copy [REDACTED_DEVICE_ALIAS]/[REDACTED_DEVICE_ALIAS] credentials.
  Keep the origin loopback-only. Use a temporary random bearer without printing or committing it.
- [x] Verify local health, public tunnel health, unauthenticated MCP rejection, authenticated initialize/tools/list,
  and representative non-destructive tools. Accessibility-dependent tests require normal on-device user approval;
  do not bypass Restricted Settings.
- [x] Exercise one cloudflared restart/recovery smoke, then confirm the tunnel and origin remain healthy. Finish by
  stopping ARCP/cloudflared, disabling temporary tunnel/autostart, removing or replacing the temporary bearer through
  a documented first-install-safe path, and verifying that no cloudflared PID, quick-tunnel endpoint, ADB forward or
  MCP listener remains. Disconnect the host ADB session but do not change the TV's pre-existing debugging setting.
  Leave only the released APK installed; do not create a persistent ChatGPT/Codex connector or named hostname.

### Phase 6 — Closure

- [x] Record the final commit, channel refs, workflow run, release tag/version/digests and device test result here,
  without credentials.
- [x] Mark the plan complete only when the downloaded release—not a local APK—passes Bedroom TV E2E.
- [x] Commit and push final evidence. If manual Accessibility approval is unavailable, report core/tunnel E2E as
  complete and accessibility E2E as explicitly pending rather than weakening device security.

Final evidence (2026-09-02): implementation commit `[REDACTED_RESOURCE_ID]`; first-install
automation fix `5f2c97aae11da77b4fd3958020c26666949b565d`; stable backports `[REDACTED_RESOURCE_ID]`
and `[REDACTED_RESOURCE_ID]`. Main CI run `33634772450` passed all jobs. Protected release run
`33636125498` published immutable tag `arcp-edge-16f39717ce09-dda2c531f58d-vc21000002` with ledger
`versionCode=21000002`; freshly downloaded GMS/FOSS artifacts passed signer, provenance, contract and exact
five-entry native-payload verification.

The verified first install recorded the absent pre-state, owner certificate and `primaryCpuAbi=armeabi-v7a`. The
application-owned ELF32 cloudflared process connected successfully. Local and public `/health` returned 200,
unauthenticated `/mcp` returned 401, authenticated `initialize` and `tools/list` passed with 49
`android_[REDACTED_DEVICE_ALIAS]_` tools, and controlled stop/start produced a new healthy tunnel. The temporary Quick Tunnel,
temporary bearer, server, cloudflared process, ADB forward and host ADB session were removed/stopped. Accessibility
was not granted; its representative tool returned the expected controlled permission error. The released APK remains
installed. Persistent connectivity is intentionally a separate reviewed rollout in Plan 75.

## Rollback

- Before first installation there is no ARCP package/data to preserve. If this task fails, stop its services and
  uninstall only when the deployment record proves the package was absent beforehand and this task installed the exact
  package. Do not change device firmware.
- A future signed downgrade is a separate, explicit procedure using a separately verified known-good artifact and an
  intentional `adb install -r -d` policy; it is not this first-install rollback. Never overwrite an immutable GitHub
  release or reuse a ledger code.
