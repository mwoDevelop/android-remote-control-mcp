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

The mutable legacy `edge` publisher and inherited `v*` draft publisher remain in Git for audit and upstream
mergeability, but both are disabled in the owner repository. New device releases must use the immutable `arcp-*`
workflow and version ledger below. Verify or converge the repository metadata with:

```bash
./scripts/arcp github status
./scripts/arcp github configure             # preview with rollback commands
./scripts/arcp github configure --apply     # enable CI/ARCP and disable both legacy publishers
```

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

Use the single public CLI for routine builds and releases:

```bash
./scripts/arcp build stable
./scripts/arcp build edge --variant fossDebug
./scripts/arcp release edge
./scripts/arcp release stable --publish
```

Channel `build` accepts debug variants only. The `release` command is the sole route to signed stable/edge Release
artifacts: it authoritatively fetches `main`, requires a clean pushed checkout, resolves and pins both full channel
SHAs, dispatches with an allowlisted request ID, discovers the exact run, and waits by default. A queued run fails
closed if either source ref moves. `--no-wait` still waits for Actions registration and prints exact `request_id`,
`run_id`, and `url`; resume it with:

```bash
./scripts/arcp release status --request-id <request-id> --watch
```

Revision `1` is the normal identity. Use `--revision 2` or greater only for a deliberate repair of the same source
identity. A dry-run previews rather than reserves the version-ledger entry and has no write-capable job. Publication
requires literal `--publish`, an enabled publication gate, and a write-capable job separated from signing. The CLI
verifies the resulting immutable release identity after success.

For local builds, `scripts/arcp` honors `ANDROID_HOME`/`ANDROID_SDK_ROOT` and otherwise detects the common
`~/android-sdk`, `~/Android/Sdk`, or `~/.local/share/android-sdk` layout. The pinned NDK package declared by the build
must be installed in that SDK.

For CI/recovery troubleshooting only, the underlying interfaces remain
`sync-build-deploy.sh`, `arcp-version-ledger.sh`, `sign-arcp-channel-release.sh`, and
`publish-arcp-channel-release.sh`; routine users should not compose them manually.

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
