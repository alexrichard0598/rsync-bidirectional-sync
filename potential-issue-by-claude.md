# Potential Issues — `rsync-bidirectional-sync`

High-level review based on `README.md`, `class-diagram.md`, `sync.conf.example`, and
`tests/` (bats-core). `mirror-remote-directory.sh` and `lib/*.sh` were deliberately
**not** read for this pass, so several items below are flagged as "verify in code"
rather than confirmed bugs — they're gaps in what the design *documents*, which may
or may not be handled correctly in the implementation.

---

## 1. Edit-vs-delete is a whole conflict class that "remote wins" doesn't cover

The documented policy only resolves **edit-vs-edit** (remote wins, loser archived to
`.sync/conflicts/`). Nothing addresses **edit-vs-delete**:

- **Local delete + remote edit**: cycle order is local-deletes → remote-deletes →
  pull → push. A locally-deleted file is pushed as a deletion in step 1, *before*
  the pull step would notice the remote side changed that same file. If someone
  edited it remotely in the meantime, that edit is destroyed with no conflict
  backup — `.sync/conflicts/` is only populated by the pull-overwrite path, not the
  delete path. The only safety net is `TRASH_ENABLED` on the remote.
- **Remote delete + local edit**: same shape in reverse — a snapshot-diff-detected
  remote deletion is applied locally (step 2) before any comparison against the
  local file's current content. A locally-edited-since-last-sync file is simply
  deleted, with only local `TRASH_ENABLED` as a backstop.

This looks like the single biggest gap: the two failure modes with genuine
data-loss potential (as opposed to "surprising but recoverable" overwrites) aren't
documented, and no test exercises "delete on one side + concurrent edit on the
other."

## 2. Push's clobber-protection depends on mtime, which the README calls unreliable

The conflict-detection rationale explicitly says mtime is *"unreliable across hosts
with skewed clocks or different filesystem timestamp precision"* — hence pull uses
checksum comparison. But push's overwrite-protection is `--update`, pure mtime
comparison:

- Pull's "who's different" decision is skew-proof; push's "can I overwrite"
  decision is not.
- If the remote clock is behind, a local file can look newer than it is, and push
  can clobber a remote edit that pull hasn't caught yet — silently, with no
  conflict record, since `--update` just skips or proceeds, it doesn't flag a
  conflict.

## 3. Watcher pause during a cycle can create a detection blind spot

`Sync` pauses `Watcher` during a cycle. If inotify literally stops listening
(rather than queuing) while paused, a local edit made *while a cycle is running*
generates no event and isn't picked up until something else triggers a cycle —
worst case, not until `PERIODIC_FULL_SYNC` fires. On a large tree or slow link,
cycles can run long enough for this window to matter.

## 4. Renames and directory moves become delete+create, with cascading effects

`inotifywait` watches `move` alongside `create`/`delete`. A `mv` is `MOVED_FROM` +
`MOVED_TO`, most likely journaled as a delete of the old path and a push of the new
one rather than a true rename:

- A directory rename fans out into a delete+create pair *per file inside it*,
  which can trip `MAX_DELETE` or `MAX_CHANGES_PER_CYCLE` and abort an entirely
  ordinary refactor.
- Large files that only moved get fully re-transferred instead of a cheap rename —
  a real cost for anyone with big media/build artifacts in the tree.

## 5. Stale `EXCLUDES` silently freezes files rather than reconciling them

Excluded paths are documented as "protected from deletion." The corollary isn't
stated: if `EXCLUDES` is edited after matching files are already synced, those
files stop being touched by either side — forever — with no warning that they're
now in a frozen, potentially-diverging state.

## 6. No distributed locking across multiple local peers to one remote

`flock` on `sync.lock` only serializes cycles *on one machine*. Nothing stops a
second machine's install of this tool, pointed at the same `REMOTE_DIR`, from
running a cycle concurrently — both writing to the same remote sentinel/snapshot
files under `REMOTE_DIR/.sync/`. The conflict-resolution model assumes exactly one
other party mutating the remote tree; a second synced peer breaks that assumption.

## 7. Type changes at the same path (file↔directory, file↔symlink)

"Remote wins" is well-specified for **content** changes to a regular file. It's
unclear how pull handles a path that changed *kind* on the remote — a file
replaced by a directory or vice versa — since that requires `rm -rf` of a whole
local subtree rather than a single-file backup-and-overwrite. Whether that gets the
same `.sync/conflicts/` treatment or is deleted outright isn't documented or
tested.

## 8. First run is effectively "remote wins" applied to two independently-populated trees

`--force-first-run` is correctly gated against clobbering an empty tree by
accident, but if both sides already contain real, divergent data (merging two
machines never synced before), the first run treats *every* differing path as a
conflict and remote wins across the board — a much bigger blast radius than the
steady-state "one file changed on both sides" case the docs frame conflicts
around.

## 9. Bulk legitimate operations vs. safety gates, under `Restart=on-failure`

`MAX_DELETE`/`MAX_CHANGES_PER_CYCLE` correctly refuse rather than partially apply.
But the sample systemd unit uses `Restart=on-failure` with a 30s backoff. A
legitimate large delete/refactor that trips a gate exits 3 every cycle — depending
on how systemd scores that exit code, either a silent restart loop spamming the
journal, or the unit hits `StartLimitBurst` and stops watching entirely until a
human intervenes. Neither is mentioned as a consequence of the safety gates.

## 10. Metadata not in scope: xattrs/ACLs, sparse files, hardlink groups crossing an exclude boundary

- No mention of `-X`/`-A` (xattrs/ACLs) — anything relying on those (SELinux
  contexts, POSIX ACLs) silently doesn't round-trip.
- `PRESERVE_HARDLINKS="true"` is fine within a fully-synced set, but if one member
  of a hardlink group matches an `EXCLUDES` pattern and its siblings don't, the
  receiver likely materializes the included members as independent copies —
  quietly doubling storage with no warning.
- Sparse files (VM images, DB files) aren't addressed; without `-S` a large sparse
  file can balloon on transfer/storage.

## 11. Snapshot staleness during `--pull-only`/`--push-only` runs

The remote snapshot (used for deletion-diffing) only refreshes at the end of a
full cycle. A long stretch of `--push-only` runs (e.g. a cron job) leaves the
snapshot arbitrarily stale; when a full cycle finally runs again, it can present a
large batch of "remote deletions" at once — correct, but indistinguishable at a
glance from a real mass-deletion event, and may trip `MAX_DELETE` for no reason.

---

## 12. Self-triggering feedback loops (sync causing sync)

This is the sharpest version of #3, and worth calling out on its own: a
bidirectional watcher-driven sync is inherently at risk of **reacting to its own
writes**.

- **Pull → local watcher → new cycle.** Pulling files writes them to the local
  disk, which is exactly the kind of `close_write`/`create` activity the local
  watcher is designed to catch. If the watcher is paused for the *entire* cycle
  (pull + push + snapshot) and inotify drops events that occur while paused
  (rather than queuing them), this is a non-issue. If instead events during the
  pause are queued in the kernel's inotify buffer and delivered on resume, the
  sync's own pulled files would immediately queue up as "changes," debounce, and
  fire a redundant cycle. Worth confirming which behavior the implementation
  relies on.
- **Push → remote watcher → new pull.** Symmetric risk on `REMOTE_WATCH="inotify"`:
  pushing writes files on the remote, which the remote-side `inotifywait` stream
  would see and report back as change events, potentially queuing an immediate
  follow-up cycle. Whether the remote watcher is also suppressed during a push (or
  its events for that specific window are discarded) isn't documented.
- **`.sync/` writes potentially not excluded from the *watch*, only from the
  *transfer*.** The docs are clear that `.sync/` is excluded from rsync transfer
  and protected from deletion. It's less clear whether the **local inotify
  watcher's** exclude regex — built by translating the `EXCLUDES` array — also
  hardcodes `.sync/`, since `.sync/` does not appear in `sync.conf.example`'s
  `EXCLUDES` list (it's user-editable, and the default doesn't include it). Every
  cycle rewrites `.sync/remote-snapshot`, appends to `.sync/sync.log`, and (with
  `TRASH_ENABLED`/`CONFLICT_BACKUP`) writes into `.sync/trash/` and
  `.sync/conflicts/`. If any of those writes are visible to the same watcher that
  triggers a sync, every cycle would immediately re-arm the next one — a tight,
  continuous sync loop even on an otherwise idle tree. This is worth verifying
  directly against `lib/watcher.sh`, since if `.sync/` isn't hardcoded out of the
  watch (independent of user `EXCLUDES`), it's effectively a livelock.
- **REMOTE_CHMOD/REMOTE_CHOWN echo.** Push normalizing remote permissions/ownership
  changes remote file attributes even when content is unchanged. On
  `REMOTE_WATCH="inotify"`, that's an `attrib` event, which would trigger a follow-up
  cycle. Likely self-limiting (the second cycle finds nothing left to chmod, so it
  doesn't repeat indefinitely), but it's still a guaranteed extra no-op cycle after
  every push that touches permissions — worth confirming it terminates after one
  bounce rather than continuing to oscillate.

## 13. Performance considerations

- **Checksum comparison reads full file content, every cycle, on both sides.**
  `PULL_COMPARE="checksum"` (the recommended default) means xxh128 is computed over
  every candidate file's full content on both local and remote for every cycle —
  not just cycles with real changes. Combined with #12's feedback-loop risk, a
  self-triggered no-op cycle still pays this full-content-read cost.
- **Dry-run-then-real-run doubles the tree walk.** `estimate_changes()` runs an
  rsync dry-run first (to gate `MAX_CHANGES_PER_CYCLE`) and then the real transfer
  — effectively two full tree comparisons per direction, per cycle, on top of the
  checksum cost above.
- **Multiple separate rsync/ssh invocations per cycle.** A single cycle can involve
  local-delete push, remote-delete listing, pull, push, and remote-snapshot
  listing — each a distinct `rsync`/`ssh` call. `SSH_MULTIPLEXING` amortizes the
  connection setup, but each invocation still pays process-spawn and rsync's own
  file-list-building overhead separately rather than as one combined operation.
- **Two independent timers can both trigger expensive full comparisons.**
  `REMOTE_POLL_INTERVAL` (when `REMOTE_WATCH="poll"`) and `PERIODIC_FULL_SYNC` are
  separate timers with no apparent coordination; on a short poll interval and a
  short periodic-sync interval, their triggers can overlap or stack, doubling up
  full-tree work rather than one superseding the other.
- **Debounce can be perpetually reset by continuous activity.** `DEBOUNCE_SECONDS`
  waits for quiet before syncing. A workload that never goes quiet for that long
  (a build system, a database, a busy log directory not fully covered by
  `EXCLUDES`) can indefinitely postpone syncing — not a crash, but a livelock on
  responsiveness that's easy to misdiagnose as "the sync isn't working."
- **Large-tree snapshot/journal handling.** `.sync/remote-snapshot` and
  `.sync/pending-deletes` are plain-text listings diffed each cycle; on very large
  trees (hundreds of thousands of files) this is a real memory/CPU cost on top of
  rsync's own file-list building, and scales linearly with tree size on every
  single cycle regardless of how small the actual change was.
- **Trash/conflict retention pruning cost.** If pruning (`TRASH_KEEP_DAYS`) walks
  the full `trash/`/`conflicts/` tree on every cycle rather than on a slower
  schedule, long-lived syncs with heavy churn and a generous retention window pay
  an ever-growing directory-walk cost each cycle.
- **inotify watch limits on large/many-directory trees** (already an acknowledged
  known limitation) — still worth grouping here as a performance/scale concern
  alongside the above, since it's the same underlying "cost grows with tree size"
  theme.
- **lz4 compression on already-compressed content.** For trees with a lot of
  already-compressed binary data (media files, archives), lz4 compression spends
  CPU for negligible size reduction — a minor but real per-transfer cost.

---

*Everything above is a documentation/design-level observation, not a confirmed
implementation bug. #1, #2, and the `.sync/`-watch-exclusion question under #12
seem like the highest-value items to check first against `lib/watcher.sh`,
`lib/sync.sh`, and `lib/snapshot.sh`.*
