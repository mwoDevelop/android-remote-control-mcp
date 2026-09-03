# Official upstream channel releases

The mirror workflow publishes qualified APKs from the official
`danielealbano/android-remote-control-mcp` repository without mixing them with this fork's own release stream.

## Streams and safety boundary

| Stream | Source | Release tag | GitHub classification |
|---|---|---|---|
| fork stable | reviewed fork commit | `v*` | normal release, unchanged |
| fork edge | reviewed fork `main` | `edge` | rolling pre-release, unchanged |
| upstream stable mirror | newest strict official `vMAJOR.MINOR.PATCH` | `upstream-vMAJOR.MINOR.PATCH` | immutable pre-release |
| upstream edge mirror | official moving `edge` tag | `upstream-edge` | rolling pre-release |

Current accepted mirrors (2026-09-01):

- [`upstream-v1.12.0`](https://github.com/mwoDevelop/android-remote-control-mcp/releases/tag/upstream-v1.12.0),
  official source `3777403d148283c5a18a3e8122ff819da4eed808`;
- [`upstream-edge`](https://github.com/mwoDevelop/android-remote-control-mcp/releases/tag/upstream-edge), official source
  `16f39717ce0969aa81a4ec132ba1cad861ba46cc`.

Both were downloaded and independently verified after publication. The stable and edge publication paths also
returned a verified same-source `NO-OP` when reapplied, without replacing their assets. Full run, artifact and digest
evidence is recorded in
[`Plan 72`](plans/72_upstream_channel_github_releases_20260901150851.md).

The mirror build job has read-only repository access, persists no checkout credential and receives no ngrok, signing,
device or publishing secret. It invokes the existing channel selectors:

```bash
scripts/sync-build-deploy.sh build --latest-stable --variant gmsRelease --unsigned-release
scripts/sync-build-deploy.sh build --latest-edge --variant gmsRelease --unsigned-release
```

The first variant establishes the official source SHA. The second variant is bound to it with the guard below; this
does not introduce a free-form source selector:

```bash
scripts/sync-build-deploy.sh build --latest-edge --variant fossRelease --unsigned-release \
  --expected-source-sha SOURCE_SHA_FROM_THE_FIRST_MANIFEST
```

Only the live `NgrokTunnelIntegrationTest` is not applicable to this secretless upstream profile because it requires a
real account token. The class is still compiled. Lint, detekt, all remaining unit/integration/privacy tests, E2E test
compilation, native tunnel payload validation and package/version validation remain active and are recorded in the
pre-sign manifest. A failed secretless Gradle test task is retried exactly once because the official suite contains a
confirmed server-start race; deterministic failures still fail on the second run, and the retry is recorded per asset
in provenance.

The trusted post-build job treats the unsigned APK and its manifest as untrusted input. It does not run Gradle, Make or
any executable from that input. It independently reads APK metadata, checks the native payload, runs `zipalign`, signs
with `apksigner`, requires one owner certificate and verifies the package/version again. The aggregate schema records
separate SHA-256 values for raw unsigned, zipaligned and signed content.

## GitHub configuration

This repository uses the protected GitHub Environment `upstream-releases`, restricted to deployments from `main`.
When recreating the environment, configure these secrets there by name only:

- `RELEASE_KEYSTORE_BASE64`
- `RELEASE_KEYSTORE_PASSWORD`
- `RELEASE_KEY_ALIAS`
- `RELEASE_KEY_PASSWORD`

Configure these repository or environment variables:

- `RELEASE_CERTIFICATE_SHA256` — the expected public SHA-256 certificate digest;
- `ENABLE_UPSTREAM_RELEASE_PUBLISHING` — literal `true` enables remote publication.

The workflow is `.github/workflows/upstream-channel-release.yml`. Manual runs accept only `stable` or `edge` and are a
dry run unless `publish` is selected and the activation variable is `true`. Scheduled runs check both channels twice a
day and publish automatically only while that variable is `true`; otherwise they perform the signing and dry-run path.

All third-party Actions used by this workflow are pinned to exact commits. The unsigned artifact retention is two days
and the signed dry-run evidence retention is three days. Keystores and password files are created under a unique
`$RUNNER_TEMP` directory with mode 0600, removed by traps and an `always()` cleanup step, and never uploaded or cached.
On forced cancellation the final guarantee is destruction of the ephemeral GitHub-hosted runner, because GitHub does
not guarantee that a cleanup step starts after cancellation.

## Local trusted signing and dry run

Build `gmsRelease` and `fossRelease` for one channel, preserving their pre-sign manifests in one input directory. Then
use external mode-0600 credential files:

```bash
scripts/sign-upstream-channel-release.sh \
  --input-dir build/upstream-input-stable \
  --output-dir build/upstream-release-stable \
  --keystore /secure/path/release.jks \
  --store-password-file /secure/path/store-password \
  --key-alias RELEASE_ALIAS \
  --key-password-file /secure/path/key-password \
  --expected-certificate-sha256 EXPECTED_PUBLIC_CERTIFICATE_SHA256

scripts/publish-upstream-channel-release.sh \
  --release-dir build/upstream-release-stable \
  --repo mwoDevelop/android-remote-control-mcp
```

The publisher is non-mutating without `--apply`. It prints source labels, SHAs and asset digests only. A real mutation
requires the explicit flag:

```bash
scripts/publish-upstream-channel-release.sh \
  --release-dir build/upstream-release-stable \
  --repo mwoDevelop/android-remote-control-mcp \
  --apply
```

## Publication behavior

- A stable mirror is immutable. An existing complete release for the same source/digests is a no-op; another source or
  damaged asset set is a hard error.
- Edge is a rolling pre-release. The same fully verified source/digests is a no-op. A new current source backs up the
  existing complete asset set before replacement.
- GitHub cannot atomically replace several assets. If an edge update fails, the script attempts to restore the verified
  backup. A failed update and failed restoration is reported explicitly as `INCOMPLETE RELEASE` for manual repair.
- Freshness is checked again against `--latest-stable` or `--latest-edge` immediately before any remote mutation.
- Mirror tags point to the trusted fork workflow commit. The official source label/SHA is cryptographically bound by
  the aggregate provenance manifest; stable mirror tags are never moved.
- Release notes come from a fixed fork-owned template rather than generated notes between unrelated tag histories.

## Installation warning

Mirror APKs omit fork-only administrator, Shizuku, trusted unlock/sleep and origin-recovery extensions. They keep the
same Android package ID and are signed with the fork owner's key, so a manual install can replace a fork build and
remove those features. They may also be signature-incompatible with APKs signed by the official upstream author.

The app's updater currently reads the official upstream repository's `/releases/latest`, not releases in this fork.
Mirror releases therefore cannot enter that updater stream; marking every mirror as a pre-release is an additional
defense. Publication never installs an APK on a managed device.
