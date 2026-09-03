<!-- AUTHORIZED AND INDEPENDENTLY REVIEWED — B1-B7 incorporated; exact pre-mutation inventory and verified encrypted backup are mandatory. -->
<!-- This document intentionally contains no real account, endpoint, device, topology or credential value. -->

# Plan 79 — rewrite public Git history and retire historical metadata artifacts

## Goal

Remove the owner-specific infrastructure and device metadata identified after Plan 78 from every Git object still
reachable through the public repository's branches and tags. Remove the previously published Releases, workflow runs,
artifacts and caches that preserve or point at the old history, while preserving the official upstream ancestry needed
for future updates and retaining the current sanitized application trees.

This is a destructive, explicitly authorized operation. It does not rotate credentials or external resources. It also
cannot alter third-party clones, downloads or caches outside the repository owner's control.

## Verified pre-rewrite scope

The read-only inventory immediately preceding authorization found:

- four remote branches, including the isolated version-ledger branch;
- twenty-one tags, four of them annotated;
- five GitHub Releases;
- fifty-six workflow runs;
- one hundred fifty-one Actions artifacts;
- seventy-three Actions caches;
- no open pull requests, branch protections or repository rulesets;
- two public source-history lines that formerly contained owner configuration, while all current application branch
  tips already pass the public metadata policy.

Counts are a baseline, not selectors. Before mutation, capture the exact ref names/object IDs and exact API object IDs;
only that captured set may be rewritten or deleted. Any unexpected new protected ref or open pull request is a stop
condition requiring a fresh impact check. The authorization for this plan explicitly includes non-recoverable deletion
of the frozen Actions artifacts and caches without copying their approximately fifteen gigabytes of derived content.

## Rewrite strategy

1. Preserve upstream compatibility. Use `git-filter-repo` in an isolated mirror rather than replacing the whole
   project with an unrelated orphan root.
2. Remove the former owner-configuration directory from every reachable commit.
3. Build a temporary private replacement set from the protected configuration repository and the removed historical
   trees. Redact exact owner emails, domains, network endpoints, provider/resource identifiers, device aliases and
   equivalent strings from other historical blobs, commit messages, tag messages and filenames. Never print matched
   values. The rewrite bundle must contain a distinct, reviewable rule or callback for every metadata class.
4. Rewrite author/committer/tagger identity only when both the original object ID and exact old identity occur on a
   frozen owner-only allowlist. Preserve every unrelated upstream contributor field byte-for-byte.
5. Classify official upstream tags by matching both tag-object ID and peeled target against the frozen upstream
   manifest, never by name alone. Every unaffected upstream tag must keep its exact object ID. For an affected
   annotated tag, freeze the intended new target, sanitized message and tagger before execution; a rewritten signed
   tag cannot retain its original cryptographic signature and any unexpected signature is a stop condition.
6. Rebuild `release/version-ledger` as one clean root snapshot. Translate source commit identities through the
   generated commit map, preserve monotonic version allocations, and remove the old ledger ancestry so it cannot keep
   obsolete source IDs reachable.
7. Preserve the exact current sanitized file trees of `main`, `release/edge` and `release/stable`, except for this plan,
   its independent review and explicitly reviewed closeout documentation added on `main`.

The replacement set, identity/object allowlists, callbacks, commit map, API inventories and original mirror are
temporary protected material. They must live in a mode-0700 workspace outside the public checkout, be included in an
encrypted recovery archive, and be removed in plaintext after verification.

## Stop gates and execution sequence

### Gate 1 — freeze and backup

1. Confirm a clean public worktree and record local/remote refs without fetching untrusted pull-request refs.
2. Capture the exact branches, tags, Releases, runs, artifacts and caches selected by the authorized inventory.
3. Create a bare mirror that includes the reviewed local plan/review commit as well as every current remote ref.
4. Download Release metadata and assets into the protected workspace and hash each metadata/asset file. Actions
   artifacts are deliberately not copied:
   they are derived, potentially metadata-bearing outputs selected for deletion; the encrypted Git mirror and release
   bundle are the recovery boundary.
5. Archive the workspace with `age` to the existing offline recipient, set mode 0600, and copy the encrypted archive
   to a second mounted filesystem. Verify both ciphertext hashes. Restore one copy into a second mode-0700 directory,
   run `git fsck --full`, compare every ref/object with the frozen manifest and recheck all Release metadata/asset
   hashes. Delete both restored and original plaintext backup copies only after this full restore proof.

Do not rewrite or delete anything remotely unless the encrypted archive and exact inventories verify.

### Gate 2 — isolated rewrite and exhaustive validation

1. Install or invoke a pinned `git-filter-repo` version whose package hash is frozen in the private execution bundle.
   Use `--force` only in disposable mirrors and record the version/hash in the private closeout report.
2. Rewrite two independent disposable copies of the same original mirror with the frozen path, filename, blob,
   message, tag and identity callbacks. Require their complete branch/tag ref manifests to be identical.
3. Rebuild the version ledger as one clean root. Preserve each upstream SHA, translate every owner/local SHA exactly
   through the commit map, recompute each identity, and fail on a missing, removed or ambiguous mapping. Every retained
   historical release tag must keep its name and target only the mapped form of its original target. Verify schema,
   unique identity/tag/version code, `next_version_code` above the maximum, lookup of an existing identity and a
   non-mutating preview of the next allocation.
4. For every rewritten branch and tag, prove that the object exists and that no unexpected ref was added or lost.
5. Scan every blob reachable from the rewritten refs with both:
   - the public path/category metadata policy; and
   - the private exact-value denylist, extended from the original historical configuration without logging matches.
6. Separately scan commit, tag and path metadata. Fail on the former owner email, device aliases, non-example domains,
   exact private endpoints and captured provider/resource identifiers.
7. Compare the three current application branch trees with their pre-rewrite snapshots. Any difference outside the
   reviewed documentation delta stops the operation.
8. Run shell syntax, metadata-policy tests, release-ledger tests, unified CLI tests and the normal local verification
   suite from the rewritten `main` snapshot.

### Gate 3 — atomic remote ref replacement

1. Freeze workflow enabled states, wait for every in-flight run to finish, and temporarily disable tag-triggered
   publishers while leaving ordinary CI available. Restore each workflow to its exact original state after the push.
2. Prove remote atomic-push capability with a no-change dry-run. Immediately re-read the complete remote heads/tags
   set and compare it with the frozen manifest; any changed, added or removed ref stops the operation.
3. Force-update the four branch refs and twenty-one tag refs in one explicit atomic push from the validated mirror,
   with a separate `--force-with-lease=<ref>:<frozen-object>` for every ref. Do not use `git push --mirror`, wildcard
   refspecs or unconditional `--force`, because helper/backup refs must never be published and every race must fail.
   Do not rely on tag push events: GitHub does not create them when one push updates more than three tags.
4. Fetch the remote refs into a fresh bare remote-verification mirror and prove they exactly equal the intended
   rewritten ref manifest.
5. Repeat the reachable-blob and metadata scans against that bare remote-verification mirror.

### Gate 4 — establish replacement provenance

1. Require public CI at the exact rewritten `main` SHA to complete successfully and record its new run ID outside the
   frozen deletion set.
2. Explicitly dispatch stable and edge release dry-runs, correlate both results to the rewritten branch/source SHAs,
   and require success. Do not depend on tag-triggered events and do not publish a Release during this repair.
3. A failure here is repaired forward on the rewritten refs and retested; old publication records remain intact until
   all three clean validations succeed.

### Gate 5 — remove old GitHub publication records

1. Delete the five pre-rewrite Releases by their frozen numeric IDs. Keep their rewritten tag refs unless validation
   shows that a tag cannot be represented truthfully; such a mismatch is a stop condition, not permission to retarget
   it arbitrarily.
2. Delete the fifty-six pre-rewrite workflow runs by their frozen IDs. This removes their logs and run-owned artifacts.
3. Delete every still-existing artifact from the frozen one-hundred-fifty-one-ID set, then verify none remains.
4. Delete every cache from the frozen seventy-three-ID set, then verify none remains.
5. For every deletion, keep a private result journal keyed by frozen numeric ID and re-read that exact ID. A `404` is
   accepted only after the list endpoint also proves absence. Use paginated list checks; never delete by count,
   workflow name, age or a freshly enumerated broad selector.
6. Verify that every retained Release tag still points to the approved rewritten target. Do not delete new clean
   post-rewrite validation runs or artifacts merely because their IDs were not part of the frozen exposure set; they
   are the replacement provenance evidence.

### Gate 6 — update dependent locks and close out

1. Update the private repository's schema/source lock to the rewritten public SHA, rerun private validation and push
   its closeout report without copying any sensitive identifier into the public repository.
2. Create a separate working-tree fresh clone from the public remote in an empty directory without alternates, fetch
   all heads/tags, compare the exact ref
   manifest and run `git fsck --full`, both complete-history scans, all three tree comparisons and the focused
   ledger/build/release tests. Only then clean local reflogs, helper refs and plaintext rewrite workspaces.
3. Repoint the working checkout to rewritten refs, remove obsolete local reflogs/helper refs and run repository garbage
   collection after the independent fresh-clone proof passes.
4. Record old-to-new ref mapping only inside the encrypted/private recovery material. Public closeout documentation
   records counts and test outcomes, never old object IDs or owner infrastructure values.

## Validation and acceptance criteria

- all four expected remote branches and all twenty-one expected tag names exist at the authorized rewritten objects;
- no former owner configuration path is present in any reachable commit;
- no protected owner identifier is present in reachable blobs, paths, commit messages, tag messages or identity fields;
- current `main`, stable and edge application trees are unchanged apart from reviewed documentation;
- the clean-root version ledger remains valid, monotonic and consistent with retained release tags;
- the five frozen Releases, fifty-six runs, one hundred fifty-one artifacts and seventy-three caches no longer exist;
- a fresh clone passes the public and private metadata policies plus the focused build/release tests;
- public CI and both explicitly dispatched release-channel dry-runs succeed at rewritten refs before old publication
  records are deleted;
- the private lock points to the rewritten public SHA and private CI is green;
- no plaintext backup, replacement file, mail map or original mirror remains after the encrypted archive is verified.

## Rollback boundary

Before the force-update, rollback is simply to discard the disposable rewrite. After the force-update, rollback means
restoring the exact twice-verified encrypted mirror and ref manifest with another explicitly controlled force-update;
deleted Releases, runs, artifacts and caches are not assumed recoverable. For that reason, publication-record deletion occurs
only after the remote rewritten refs pass a fresh-clone scan.

Every existing collaborator clone must be replaced with a fresh clone or deliberately reset to the rewritten refs;
merging old branches back is forbidden because it would republish the removed objects.

## Explicitly out of scope

- credential, token, PIN, signing-key, endpoint, tunnel, DNS, OAuth or registrar rotation;
- changes to deployed Android applications, devices, connectors or infrastructure;
- deletion of third-party clones, downloads, mirrors, search indexes or caches outside repository APIs;
- arbitrary retargeting of historical release tags to current code;
- changes to upstream application classes or the OCP-oriented private-configuration boundary.
