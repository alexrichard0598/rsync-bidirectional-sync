# Complex Tests

## Context

These are scenarios **not** covered by `tasks.md`. They were found by reasoning through edge cases in bidirectional sync behavior, not by reading the codebase.

Unlike `tasks.md`, the "expected result" for each item here is a **proposed** behavior, not a confirmed spec — these haven't been designed or agreed on yet. Before writing a test for any item below:

1. Confirm the expected behavior with the project owner (some of these may not even be in scope).
2. Move the confirmed item into `tasks.md` in the correct section, using the same checkbox format.
3. Only then write the test.

Same rules as `tasks.md` apply once promoted: test in `remote`/`local` folders, cover single file / multiple files / folder where relevant, only modify files in `tests/`, don't try to make tests pass — just make them correctly express the scenario.

---

## Rename edge cases

- [ ] A file is renamed by case only (e.g. `Foo.txt` → `foo.txt`), relevant when one side is on a case-insensitive filesystem and the other isn't.
    - [ ] *Proposed:* treated as a real rename, not a no-op.
- [ ] Chained or circular renames happen in the same sync cycle (e.g. A→B and B→C, or A→B and B→A as a swap).
    - [ ] *Proposed:* all renames resolve correctly without one clobbering another or losing a file.
- [ ] A folder is moved on one side, while the entire folder is deleted on the other side.
    - [ ] *Proposed:* needs a decision — this is distinct from the existing "file moved vs. deleted" case, since deleting a folder implicitly deletes its (now-moved) contents too.

## Symlinks

- [ ] A symlink is created on one side.
    - [ ] *Proposed:* symlink is recreated on the other side.
- [ ] A symlink's target is changed on one side.
    - [ ] *Proposed:* target update is synced.
- [ ] A symlink is deleted on one side.
    - [ ] *Proposed:* follows the same delete rules as a regular file.
- [ ] A symlink points outside the sync root.
    - [ ] *Proposed:* needs a decision — likely should not be followed/synced, for safety.

## Metadata-only changes

- [ ] A file's permissions, ownership, or timestamps change, but its content does not.
    - [ ] *Proposed:* needs a decision — is this ignored, or treated as a change requiring sync?

## Empty content

- [ ] An empty file (0 bytes) is created on one side.
    - [ ] *Proposed:* synced the same as any other new file.
- [ ] An empty folder (no files inside it) is created on one side.
    - [ ] *Proposed:* folder is created on the other side.
- [ ] An empty folder is deleted on one side.
    - [ ] *Proposed:* folder is deleted on the other side.

## Unusual filenames

- [ ] Filenames containing spaces, unicode characters, a leading dash, or trailing whitespace.
    - [ ] *Proposed:* synced correctly, with no shell-quoting or argument-parsing errors.

## Rapid or overlapping changes

- [ ] A file is deleted, then a new file is created at the same path, before the next sync cycle runs.
    - [ ] *Proposed:* needs a decision — treated as "no net change" vs. "delete followed by create."
- [ ] A large backlog of changes accumulates across several missed sync cycles while the tool is offline.
    - [ ] *Proposed:* all changes are reconciled correctly in one pass, same as a single cycle's worth.

## Failure handling

- [ ] The sync process is killed or interrupted partway through a sync cycle.
    - [ ] *Proposed:* on the next run, state is left consistent — no partial/corrupted snapshot.
- [ ] A copy fails partway through a batch (e.g. disk full, permission denied) on one side.
    - [ ] *Proposed:* the failure is surfaced/logged, and it doesn't silently block or corrupt unrelated files in the same batch.

## Nested conflicts

- [ ] A folder is being merged non-conflictingly (per the existing folder-merge case), but one specific file inside that folder does conflict.
    - [ ] *Proposed:* the folder merge still succeeds, but the one conflicting file is handled per the normal file-conflict rule (moved to `local/.sync/conflicts/<timestamp>/`).

## Tool metadata collisions

- [ ] A user's real file or folder is legitimately named `.sync`, colliding with the path the tool uses for its own metadata.
    - [ ] *Proposed:* needs a decision — likely requires a guard/warning rather than silent data loss.
