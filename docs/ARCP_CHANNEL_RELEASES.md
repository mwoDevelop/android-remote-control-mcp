# ARCP stable and edge releases

`--latest-stable` and `--latest-edge` select an official upstream baseline, but build reviewed local integrations.
They no longer produce pure-upstream mirrors.

| Channel | Official baseline | Local source | GitHub release |
|---|---|---|---|
| stable | newest strict official `vMAJOR.MINOR.PATCH` | `origin/release/stable` | immutable normal release |
| edge | official moving `edge` tag | `origin/release/edge` | immutable pre-release |

Both branches retain the same application ID and owner certificate, so these are alternative updates of one app, not
side-by-side installations. Stable has a Ktor 3.4/MCP SDK 0.8 adapter; edge has the Ktor 3.5/MCP SDK 0.15 adapter.
Common privileged implementations remain in owner packages and the `shizuku-admin` module.

Historical `upstream-v*` and `upstream-edge` releases are retained only as audit evidence. They omit local features
and must not be installed on [REDACTED_DEVICE_ALIAS] or [REDACTED_DEVICE_ALIAS].

## Source, version and release contract

The resolver records the official label/SHA, local ref/SHA, exact `vendor/cloudflared` and `vendor/ngrok-java` SHAs,
feature-contract digest, package metadata and qualification state. `release/stable` must contain its stable baseline
and must not contain the official edge commit. `release/edge` must contain the current official edge commit.

Android version codes are allocated globally in the append-only `release/version-ledger` branch. Retrying an exact
source identity reuses its code; a repair revision receives a greater code. New immutable tags use:

- `arcp-stable-<upstream-label>-<local-short-sha>-vc<code>`;
- `arcp-edge-<upstream-short-sha>-<local-short-sha>-vc<code>`.

No asset or tag is overwritten. An existing exact release is a verified no-op; any differing provenance is fatal.

## GitHub environments

`.github/workflows/arcp-channel-release.yml` is manual and has one non-cancelling global publication lock. It has
three trust boundaries:

1. A secretless build checks both source refs, feature parity, native payload, lint, tests and E2E compilation and
   produces unsigned GMS/FOSS APKs.
2. `arcp-live-tests` receives only `NGROK_AUTHTOKEN` and runs the real ngrok integration test at the exact local SHA.
3. `upstream-releases` receives signing secrets and publication access only after the first two jobs pass.

The signing environment contains, by name, `RELEASE_KEYSTORE_BASE64`, `RELEASE_KEYSTORE_PASSWORD`,
`RELEASE_KEY_ALIAS`, `RELEASE_KEY_PASSWORD`, `RELEASE_CERTIFICATE_SHA256` and
`ENABLE_ARCP_RELEASE_PUBLISHING=true`. Never store their values in Git.

Start a dry run or publication with GitHub CLI:

```bash
gh workflow run arcp-channel-release.yml -f channel=edge -f revision=1 -f publish=false
gh workflow run arcp-channel-release.yml -f channel=edge -f revision=1 -f publish=true
```

## Released APK verification and [REDACTED_DEVICE_ALIAS] promotion

Deployment uses a freshly downloaded immutable release, never the local build output:

```bash
release_dir="$(mktemp -d /tmp/arcp-release.XXXXXX)"
scripts/arcp-release-artifact.sh download --tag <immutable-tag> --dir "$release_dir"
scripts/arcp-release-artifact.sh deploy --tag <immutable-tag> --dir "$release_dir" --device [REDACTED_DEVICE_ALIAS]
scripts/arcp-release-artifact.sh deploy --tag <immutable-tag> --dir "$release_dir" --device [REDACTED_DEVICE_ALIAS] --apply
```

The verifier enforces the exact regular-file allowlist, remote tag target/classification, release ledger binding,
dual source and submodule SHAs, feature contract, hashes, one owner signer, package/version metadata and both native
tunnel payloads. Deployment additionally refuses a versionCode downgrade, retains application data, and stores the
previous installed base APK under ignored `build/device-backups/[REDACTED_DEVICE_ALIAS]/` before update.

The complete reviewed design, accepted independent-review findings and rollout evidence are in
[Plan 73](plans/73_local_fork_stable_edge_releases_20260901.md).
