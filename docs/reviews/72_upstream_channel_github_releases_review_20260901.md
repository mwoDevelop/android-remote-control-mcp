# Independent review of Plan 72

Scope: `docs/plans/72_upstream_channel_github_releases_20260901150851.md` before implementation.

## Verdict

The stable/edge split and the separation between an untrusted upstream build and trusted signing are sound, but the
first draft was not implementable safely without the corrections below.

## Blocking findings accepted into the plan

1. The current channel builder can qualify Debug APKs only. An unsigned Release APK fails `apk_metadata()` because
   that function requires a signing certificate. The implementation needs a distinct unsigned metadata and
   pre-sign-manifest path.
2. The current test command always consumes `NGROK_AUTHTOKEN`. Supplying an owner or device token to code checked out
   from upstream would break the secret boundary. Upstream mirror builds must run a documented secretless profile
   which excludes only the live ngrok integration class while retaining compilation and all other tests.
3. Two separate variant builds can resolve a moving `edge` tag to different commits. Both public build invocations
   must still use `--latest-stable` or `--latest-edge`, plus an `--expected-source-sha` guard after the first
   resolution and another freshness check immediately before publication.
4. The build job must have read-only permissions, no environment secrets and no persisted checkout credentials. The
   signing/publishing job alone may receive write permission and a protected environment.
5. The signing job must treat the APK and pre-sign manifest as untrusted input. It must run only trusted fork-owned
   tooling, never Gradle/Make or an executable from the build artifact, and independently derive package, version,
   payload, signer count and certificate data from the final APK.
6. Cancellation cannot guarantee that a cleanup step runs. The achievable contract is `umask 077`, a unique
   `$RUNNER_TEMP` directory, best-effort `always()` cleanup and destruction of the ephemeral hosted runner.
7. GitHub cannot atomically replace several release assets. Rolling edge publication therefore needs a backup and
   best-effort rollback with an explicit incomplete-state failure, not a claim that the old release is always
   untouched.

## Important corrections accepted into the plan

- Idempotence is keyed by `source_sha` only after the existing manifest and complete remote asset set verify. The same
  SHA with different or missing assets is a hard error, not an automatic repair.
- Manifests use portable asset names and a versioned schema, and record separate hashes for raw unsigned, zipaligned
  and signed APKs.
- Mirror tags point to a documented trusted fork commit; the actual upstream source is bound by the signed provenance
  manifest. Stable tags never move.
- Verification requires exactly one signer and the configured owner certificate. Passwords are supplied to
  `apksigner` through mode-0600 files, never command-line values.
- Every third-party Action in the security-sensitive workflow is pinned to a full commit, Gradle Wrapper validation is
  included, and artifact uploads use explicit files, short retention and `if-no-files-found: error`.
- The installed app currently checks the official upstream repository's `/releases/latest`, not this fork. Marking
  mirrors as pre-releases remains defense in depth, while the regression test must assert the real updater endpoint.
- Notes must warn that a mirror APK uses the fork owner's signer and the same package ID: a manual install can replace
  a fork build and remove administrator/Shizuku/recovery features, and may not be signature-compatible with official
  upstream binaries.

## Non-blocking scenarios added to tests

- build environment contains no ngrok or publishing secret and checkout does not persist credentials;
- arbitrary branch/develop inputs and an unexpected source SHA are rejected;
- extra assets, a tag without a release, a release without a manifest, and a same-SHA damaged asset set fail closed;
- stable and edge dry runs create no remote mutation; stable is immutable and edge is idempotent for a fully verified
  existing source SHA.

No files were modified by the reviewer. This document records the review and the changes accepted by the implementer.
