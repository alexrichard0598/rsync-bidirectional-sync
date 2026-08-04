# Tasks

## Context

- `rsync-live-mirror` syncs files between two directories: `local` and `remote`.
- Tests live in `tests/`. Only modify files in `tests/` — do not modify anything outside that directory.
- Every scenario below must be tested against three cases unless a task says otherwise:
  1. a single file
  2. multiple files
  3. a folder
- Every test uses two local test directories named `remote` and `local`.
- **Do not try to make the tests pass.** Write tests that correctly express the scenario and its expected result. Whether the current code passes them is a separate concern.
- When a task's test has been written and manually verified to correctly describe the scenario, check it off.

## Format

Each task is a pair of checkboxes:

```
- [ ] <Scenario>: the state or action being tested.
    - [ ] <Expected result>: what the tool must do in response.
```

Example:

- [x] This is an example task, it has been completed because the success requirement has been met.
    - [x] The example task exists. The success requirement is listed indented like this.

---

## Part 1 — Watch Mode

These scenarios test syncing while `rsync-live-mirror` is actively running and watching for changes.

- [x] File(s) exist in remote but not local.
    - [x] File(s) are copied to local.
- [x] File(s) exist in local but not remote.
    - [x] File(s) are copied to remote.
- [x] File(s) are updated in remote.
    - [x] File(s) in local are updated to match remote.
- [x] File(s) are updated in local.
    - [x] File(s) in remote are updated to match local.
- [x] File(s) are deleted in remote.
    - [x] File(s) deleted in remote are deleted in local.
- [x] File(s) are deleted in local.
    - [x] File(s) deleted in local are deleted in remote.
- [x] File(s) are moved in remote.
    - [x] File(s) are moved in local.
- [x] File(s) are moved in local.
    - [x] File(s) are moved in remote.

---

## Part 2 — Startup Sync (Reconciling Offline Changes)

These scenarios test syncing changes that happened while `rsync-live-mirror` was NOT running, once it is started.

### 2a. Simple one-sided changes

- [x] File(s) are created in remote (while tool was offline).
    - [x] File(s) are created in local.
- [x] File(s) are created in local (while tool was offline).
    - [x] File(s) are created in remote.
- [x] File(s) are updated in remote (while tool was offline).
    - [x] File(s) are updated in local.
- [x] File(s) are updated in local (while tool was offline).
    - [x] File(s) are updated in remote.
- [x] File(s) are deleted in remote (while tool was offline).
    - [x] File(s) that were deleted in remote are deleted in local.
- [x] File(s) are deleted in local (while tool was offline).
    - [x] File(s) that were deleted in local are deleted in remote.

### 2b. Same-path conflicts (content vs. content)

- [x] File(s) (NOT folders) are created independently in both local and remote at the same path, and their content differs (a true conflict).
    - [x] The conflicting local file(s) are moved to `local/.sync/conflicts/<timestamp>/`, and the remote version is copied to local.
- [x] Folder(s) are created independently in both local and remote at the same path, but the files inside don't collide (no true conflict — just different new files in each).
    - [x] The folder's contents are merged so local and remote end up with the same combined set of files.
- [x] File(s) are updated independently in both local and remote, and the resulting content differs (a true conflict).
    - [x] The conflicting local file(s) are moved to `local/.sync/conflicts/<timestamp>/`, and the remote version is copied to local.

### 2c. Delete vs. edit conflicts

- [x] File(s) are deleted in local, but modified in remote.
    - [x] The remote (modified) file(s) are copied to local — the edit wins over the delete.
- [x] File(s) are modified in local, but deleted in remote.
    - [x] The local (modified) file(s) are moved to `local/.sync/conflicts/<timestamp>/`.

### 2d. Folder deletion vs. new files inside it

- [x] File(s) are created inside a folder in local, but that same folder is deleted in remote.
    - [x] The file(s) that used to be in that folder in remote are deleted, but the folder itself is kept, and the new local file(s) are copied to remote.
- [x] File(s) are created inside a folder in remote, but that same folder is deleted in local.
    - [x] The file(s) that used to be in that folder in local are deleted, but the folder itself is kept, and the new remote file(s) are copied to local.

### 2e. Move vs. delete conflicts

- [x] File(s) are moved in remote, but deleted (at their original path) in local.
    - [x] File(s) are copied to local at their new (moved) path.
- [x] File(s) are moved in local, but deleted (at their original path) in remote.
    - [x] File(s) in local are moved to `local/.sync/conflicts/<timestamp>/`.

### 2f. Move vs. new files inside a moved folder

- [x] A folder is moved in local, and new file(s) are added to that same folder (at its original path) in remote.
    - [x] The folder is moved in remote to match local, and the new remote file(s) are added to local (inside the moved folder).
- [x] A folder is moved in remote, and new file(s) are added to that same folder (at its original path) in local.
    - [x] The folder is moved in local to match remote, and the new local file(s) are added to remote (inside the moved folder).

### 2g. Move vs. edit conflicts

- [x] File(s) are moved in local, and their content is changed in remote (at the original path).
    - [x] File(s) are moved to match local's new path, and their content is updated to match remote's change.
- [x] File(s) are moved in remote, and their content is changed in local (at the original path).
    - [x] File(s) are moved to match remote's new path, and their content is updated to match local's change.

### 2h. Move vs. move conflicts

- [x] File(s) are moved in both remote and local, but to *different* destination paths.
    - [x] File(s) in local are moved to `local/.sync/conflicts/<timestamp>/`, and the remote version (at its new path) is copied to local.
- [x] File(s) are moved in both remote and local to the *same* destination path, and the content is identical.
    - [x] `.sync/remote-snapshot` is updated to reflect the new path. No file content is transferred (nothing needs to change).