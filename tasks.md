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

- [ ] File(s) exist in remote but not local.
    - [ ] File(s) are copied to local.
- [ ] File(s) exist in local but not remote.
    - [ ] File(s) are copied to remote.
- [ ] File(s) are updated in remote.
    - [ ] File(s) in local are updated to match remote.
- [ ] File(s) are updated in local.
    - [ ] File(s) in remote are updated to match local.
- [ ] File(s) are deleted in remote.
    - [ ] File(s) deleted in remote are deleted in local.
- [ ] File(s) are deleted in local.
    - [ ] File(s) deleted in local are deleted in remote.
- [ ] File(s) are moved in remote.
    - [ ] File(s) are moved in local.
- [ ] File(s) are moved in local.
    - [ ] File(s) are moved in remote.

---

## Part 2 — Startup Sync (Reconciling Offline Changes)

These scenarios test syncing changes that happened while `rsync-live-mirror` was NOT running, once it is started.

### 2a. Simple one-sided changes

- [ ] File(s) are created in remote (while tool was offline).
    - [ ] File(s) are created in local.
- [ ] File(s) are created in local (while tool was offline).
    - [ ] File(s) are created in remote.
- [ ] File(s) are updated in remote (while tool was offline).
    - [ ] File(s) are updated in local.
- [ ] File(s) are updated in local (while tool was offline).
    - [ ] File(s) are updated in remote.
- [ ] File(s) are deleted in remote (while tool was offline).
    - [ ] File(s) that were deleted in remote are deleted in local.
- [ ] File(s) are deleted in local (while tool was offline).
    - [ ] File(s) that were deleted in local are deleted in remote.

### 2b. Same-path conflicts (content vs. content)

- [ ] File(s) (NOT folders) are created independently in both local and remote at the same path, and their content differs (a true conflict).
    - [ ] The conflicting local file(s) are moved to `local/.sync/conflicts/<timestamp>/`, and the remote version is copied to local.
- [ ] Folder(s) are created independently in both local and remote at the same path, but the files inside don't collide (no true conflict — just different new files in each).
    - [ ] The folder's contents are merged so local and remote end up with the same combined set of files.
- [ ] File(s) are updated independently in both local and remote, and the resulting content differs (a true conflict).
    - [ ] The conflicting local file(s) are moved to `local/.sync/conflicts/<timestamp>/`, and the remote version is copied to local.

### 2c. Delete vs. edit conflicts

- [ ] File(s) are deleted in local, but modified in remote.
    - [ ] The remote (modified) file(s) are copied to local — the edit wins over the delete.
- [ ] File(s) are modified in local, but deleted in remote.
    - [ ] The local (modified) file(s) are moved to `local/.sync/conflicts/<timestamp>/`.

### 2d. Folder deletion vs. new files inside it

- [ ] File(s) are created inside a folder in local, but that same folder is deleted in remote.
    - [ ] The file(s) that used to be in that folder in remote are deleted, but the folder itself is kept, and the new local file(s) are copied to remote.
- [ ] File(s) are created inside a folder in remote, but that same folder is deleted in local.
    - [ ] The file(s) that used to be in that folder in local are deleted, but the folder itself is kept, and the new remote file(s) are copied to local.

### 2e. Move vs. delete conflicts

- [ ] File(s) are moved in remote, but deleted (at their original path) in local.
    - [ ] File(s) are copied to local at their new (moved) path.
- [ ] File(s) are moved in local, but deleted (at their original path) in remote.
    - [ ] File(s) in local are moved to `local/.sync/conflicts/<timestamp>/`.

### 2f. Move vs. new files inside a moved folder

- [ ] A folder is moved in local, and new file(s) are added to that same folder (at its original path) in remote.
    - [ ] The folder is moved in remote to match local, and the new remote file(s) are added to local (inside the moved folder).
- [ ] A folder is moved in remote, and new file(s) are added to that same folder (at its original path) in local.
    - [ ] The folder is moved in local to match remote, and the new local file(s) are added to remote (inside the moved folder).

### 2g. Move vs. edit conflicts

- [ ] File(s) are moved in local, and their content is changed in remote (at the original path).
    - [ ] File(s) are moved to match local's new path, and their content is updated to match remote's change.
- [ ] File(s) are moved in remote, and their content is changed in local (at the original path).
    - [ ] File(s) are moved to match remote's new path, and their content is updated to match local's change.

### 2h. Move vs. move conflicts

- [ ] File(s) are moved in both remote and local, but to *different* destination paths.
    - [ ] File(s) in local are moved to `local/.sync/conflicts/<timestamp>/`, and the remote version (at its new path) is copied to local.
- [ ] File(s) are moved in both remote and local to the *same* destination path, and the content is identical.
    - [ ] `.sync/remote-snapshot` is updated to reflect the new path. No file content is transferred (nothing needs to change).
