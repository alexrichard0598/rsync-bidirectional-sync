# Issues

Derived from analysis of `rsync-bidirectional-sync-issue-to-checks.md` (13 candidate issues reviewed against source code and tests).

Only genuinely actionable gaps are listed below. Issues that were already handled by the implementation or represent by-design trade-offs are omitted.

---

## 1. Edit-vs-delete conflicts not archived to `.sync/conflicts/`

**Severity:** Medium

When a file is deleted locally but edited remotely on the same cycle, the journal-driven deletion step destroys the remote edit. The destroyed file is moved to the **remote trash** (if `TRASH_ENABLED=true`, the default), but NOT to `.sync/conflicts/` on the local side.

The reverse is also true: a remotely-deleted / locally-edited file is deleted locally, with the local edit going to local trash only.

**Current state:** `TRASH_ENABLED` defaults to `"true"`, so both sides are recoverable. The gap is that the trash path is silent and undocumented as a recovery mechanism for this scenario, and no test exercises the edit-vs-delete pattern.

**Suggested action:** Add a documentation note about trash as the recovery path for edit-vs-delete conflicts. Consider adding a test for the pattern.

---

## 4. Renames / directory moves fan out into delete+create pairs

**Severity:** Medium

`inotifywait` reports `MOVED_FROM` + `MOVED_TO`. The watcher journals `MOVED_FROM` as a deletion and `MOVED_TO` as a creation. A directory rename produces one journal entry per contained file.

This can:
- Trip `MAX_DELETE` and abort the cycle for large directory moves
- Force full re-transfer of large moved files instead of cheap server-side renames

**Current state:** No rename detection or rsync `--remove-source-files` trickery is attempted.

**Suggested action:** Consider a heuristic to detect rename pairs (same inode, same size, adjacent `MOVED_FROM`/`MOVED_TO` entries) and skip the deletion for the source path. Alternatively, document the limitation and recommend adjusting `MAX_DELETE` for workloads with frequent renames.

---

## 5. Stale EXCLUDES silently freeze files

**Severity:** Low

If `EXCLUDES` is edited to include a path whose files are already synced, those files stop being touched by subsequent cycles — forever — with no warning. The `--filter="protect"` rule prevents deletion, and `--filter="exclude"` prevents transfer, so excluded-but-existing files silently diverge from their remote copies.

**Current state:** No detection or warning on config load.

**Suggested action:** Emit a one-time warning at config load when an EXCLUDES pattern matches already-synced files.

---

## 6. No distributed locking across multiple peers

**Severity:** Low (out of scope)

`flock` on `sync.lock` only serializes cycles on a single machine. A second machine pointed at the same `REMOTE_DIR` races on the remote sentinel/snapshot files with no coordination mechanism.

**Current state:** Tool is explicitly designed as a two-peer sync.

**Suggested action:** Document this limitation. Adding N-peer locking (e.g., SSH-remote flock) is a feature request, not a bug fix.

---

## 9. Safety gates + `Restart=on-failure` restart loop

**Severity:** Medium

`MAX_CHANGES_PER_CYCLE` and `MAX_DELETE` exit with code 3 (`EX_SAFETY`). The sample systemd unit uses `Restart=on-failure`, which treats any non-zero exit as a failure. A legitimate bulk operation that trips a safety gate will cause a restart loop until `StartLimitBurst` kills the unit.

**Current state:** No distinction between safety refusals and actual errors in the systemd example.

**Suggested action:** Update the systemd example to use `RestartPreventExitStatus=3` so safety-gate exits don't trigger restarts. Alternatively, document that `Restart=on-success` is preferred for the periodic timer when safety gates are expected to trip.

---

## 10. Hardlink groups crossing an exclude boundary (niche)

**Severity:** Low

When `PRESERVE_HARDLINKS="true"`, all members of a hardlink group are expected to be synced together. If one member matches an `EXCLUDES` pattern and a sibling does not, the receiver materializes the included members as independent copies — quietly doubling storage for that group.

**Current state:** No detection. Other sub-claims from the original issue (sparse files, xattrs/ACLs) are not issues — sparse files are handled via `--sparse` in `build_common_opts`; xattrs/ACLs are a conscious omission.

**Suggested action:** Add a brief note in the documentation warning about this edge case.

---

## Summary

| # | Issue | Severity | Action |
|---|-------|----------|--------|
| 4 | Renames fan out | Medium | Detect rename pairs or document limitation |
| 9 | Safety gates + systemd restart loop | Medium | Fix systemd example with `RestartPreventExitStatus=3` |
| 1 | Edit-vs-delete → trash only | Medium | Document trash as recovery path; add test |
| 5 | Stale EXCLUDES freeze files | Low | Warn on config load |
| 10 | Hardlink crossing exclude | Low | Document edge case |
| 6 | No multi-peer locking | Low | Document limitation |
