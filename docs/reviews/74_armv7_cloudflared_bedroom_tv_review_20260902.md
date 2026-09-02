# Independent review of Plan 74

Scope: `docs/plans/74_armv7_cloudflared_bedroom_tv_20260902.md`, current native build/release validators, CI caches,
ARCP channel topology and the live read-only Bedroom TV baseline. The plan and implementation were not modified.

## Decision

**Approve with changes.** The ARMv7 approach is technically viable, but the first-install path, cache invalidation and
asymmetric payload contract must be made explicit before implementation or release.

## Evidence

- Bedroom TV currently reports Google/[REDACTED_OWNER_VALUE]/`kirkwood`, API 34, `zygote32`, and only
  `armeabi-v7a,armeabi`; ARCP is absent.
- An isolated probe with Go 1.26.7, NDK 27.2, `CGO_ENABLED=1 GOOS=android GOARCH=arm GOARM=7` and
  `armv7a-linux-androideabi21-clang` produced an ELF32 ARM EABI5 PIE using `/system/bin/linker`, 16 KiB-aligned LOAD
  segments, and successfully ran `cloudflared --version` on the TV. This validates the proposed tuple, but not yet
  Package Manager extraction or execution as the application UID.
- `useLegacyPackaging=true` and `AndroidCloudflareBinaryResolver` already support extraction from
  `nativeLibraryDir`; no runtime change is justified before the installed-APK proof.

## Blocking findings

### B1 — Existing cache keys will restore the old two-ABI cloudflared payload

The cloudflared cache key hashes the submodule sources but not the Makefile, ABI matrix, Go version or NDK version.
Adding an ARMv7 path while retaining the key can hit an immutable old cache, skip `make compile-cloudflared`, and omit
the new binary. Update all cache paths **and bump the key contract**, preferably hashing the Makefile/native contract
plus pinned Go and NDK versions. Add a test for a cache hit missing ARMv7 and fail/rebuild rather than trusting
`cache-hit=true`. This applies to both CI jobs and the legacy `edge-release.yml`/`release.yml` workflows while they
remain runnable.

### B2 — The asymmetric payload matrix needs one semantic source of truth

The required payload is currently hard-coded independently in `sync-build-deploy.sh`,
`sign-arcp-channel-release.sh`, `arcp-release-artifact.sh`, channel tests and historical upstream-mirror signing tests.
Changing only `config/arcp-channel-features.json` changes a digest but its verifier does not semantically validate APK
payloads.

Define one trusted matrix and make every pre-sign, post-sign, publish/download and local-build validator consume or
assert it:

- required cloudflared: `arm64-v8a`, `armeabi-v7a`, `x86_64`;
- required ngrok: `arm64-v8a`, `x86_64`;
- forbidden unsupported tunnel entry: `armeabi-v7a/libngrok_java.so`.

Tests must cover every required missing entry, intentional ARMv7-ngrok absence, and unexpected tunnel ABI entries.
Update the still-runnable upstream mirror validators/tests and `myconf/README.md`, not only the ARCP publisher.

### B3 — The released-artifact deploy command cannot perform this first installation

`scripts/arcp-release-artifact.sh deploy` currently accepts only `--device [REDACTED_DEVICE_ALIAS]` and assumes the package is already
installed with a readable version code and APK to back up. Plan 74 would otherwise require bypassing the established
release trust path.

Add a narrowly scoped `bedroom-tv` deployment identity and an explicit first-install branch that:

- proves manufacturer/model/device/API/ABI and that the package was absent immediately before install;
- accepts only the freshly verified GMS asset and owner signer from the immutable release;
- uses `adb install` without uninstall/data clearing and records the transition from absent to the exact package,
  signer and ledger code;
- never silently falls back to the only attached ADB device;
- uninstalls on rollback only when the recorded pre-state was absent and this exact task installed the package.

### B4 — Successful E2E currently has no defined secure final state

The plan says to remove the temporary bearer but does not explicitly stop the quick tunnel/server or explain how the
credential is removed from app storage. Discarding the client copy while leaving a public quick tunnel running would
leave an unmanaged service; setting an empty token while running merely creates a fail-closed but stale service.

After E2E, stop ARCP and cloudflared, disable tunnel/autostart, clear or replace the temporary bearer through a
documented first-install-safe mechanism, and verify no cloudflared PID, quick-tunnel endpoint, ADB forward or MCP
listener remains. Leave only the released package installed. Do not disable the pre-existing TV ADB setting without
separate authorization, but disconnect the host session when finished.

## Important findings

### H1 — Pin the full native toolchain and strengthen ELF qualification

Do not rely on "latest installed NDK" from Makefile autodetection. Pin Go 1.26.7 and NDK 27.2.12479018 in local and CI
contracts. Besides `file`, verify ELF class/machine/type, `/system/bin/linker`, EABI, non-W+X LOAD segments, 16 KiB
alignment and expected dynamic dependencies. Then verify the installed `nativeLibraryDir/libcloudflared.so` is ELF32,
executable by the app UID and is the process actually launched by ARCP.

### H2 — Branch promotion wording is ambiguous for divergent histories

`release/stable` is not an ancestor of `release/edge`; the literal same commit cannot be applied to both without
bringing the edge baseline into stable. Land the canonical change on `main`, advance `release/edge` through the
reviewed main lineage, and backport the minimal Makefile/contract change to `release/stable` with `cherry-pick -x` and
recorded patch identity. Do not copy main-only workflow/documentation commits unnecessarily into stable. Both refs
must pass channel/feature tests and be pushed before the edge ledger allocation; the new code must be greater than
`21000001`. Publish only the immutable edge identity as planned.

### H3 — Release provenance must bind the new native contract, not merely its presence

Record the pinned cloudflared submodule SHA, toolchain/NDK identity and semantic payload-contract version/digest in
pre-sign and final manifests. GMS and FOSS must contain identical tunnel matrices and ledger metadata. The protected
signer must independently inspect the unsigned and signed APKs; no release should rely solely on a feature-ledger hash
produced by the integration worktree.

### H4 — First-install permissions and quick-tunnel test boundaries need explicit checks

Launch the installed app once and handle only normal visible Google TV permission prompts needed for the foreground
service; do not grant Accessibility, Restricted Settings or privileged administration automatically. Use a random
mode-0600 temporary bearer without shell tracing/logging and no Cloudflare token. Test public health, unauthenticated
401, authenticated initialize/tools/list, a non-destructive tool, and one deliberate cloudflared restart/recovery.
Capture diagnostics with token/URL redaction and never persist a ChatGPT/Codex connector or named hostname.

### H5 — Rollback wording conflates first-install rollback with downgrade

For this device there is no previous ARCP APK, so the safe rollback is stopping services and uninstalling only the
newly installed, recorded package. A previous immutable release normally has a lower ledger code and cannot satisfy a
"greater/equal" normal update rule; any future downgrade needs a separately verified known-good artifact and an
explicit `adb install -r -d` policy. GitHub releases and ledger entries remain immutable in either case.

## Required plan amendments

1. Version/bump the cloudflared cache contract and cover stale cache hits.
2. Centralize and test the asymmetric payload matrix across every maintained validator/workflow.
3. Add a verified Bedroom TV first-install path instead of bypassing `arcp-release-artifact.sh`.
4. Pin Go/NDK and expand ELF plus installed-app-UID execution checks.
5. Specify edge advance versus stable `cherry-pick -x`, feature/provenance updates and ledger ordering.
6. End E2E with the quick tunnel, server and temporary credential removed, while retaining only the APK.
7. Separate first-install uninstall rollback from future signed downgrade handling.

With these corrections, the planned contract-first implementation, immutable edge release and downloaded-APK E2E
form a coherent and appropriately narrow rollout.
