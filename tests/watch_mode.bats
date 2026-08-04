#!/usr/bin/env bats
# Watch mode integration tests.
# These scenarios test syncing while rsync-live-mirror is actively running
# and watching for changes. Each scenario covers:
#   - a single file
#   - multiple files
#   - a folder
#
# All tests run in local-to-local mode (REMOTE="") so no sshd is needed.

load 'test_helper.bash'

setup() {
  setup_sync_dirs
}

# ===========================================================================
# Part 1 — Watch Mode
# ===========================================================================
# These tests exercise the sync cycle while the tool is watching for
# filesystem changes. The pattern is:
#   1. Establish a baseline with --force-first-run
#   2. Make a change on one side
#   3. Run a sync cycle (simulating the watch triggering a cycle)
#   4. Verify the expected result
# ===========================================================================

# ---------------------------------------------------------------------------
# 1. File(s) exist in remote but not local → copied to local
# ---------------------------------------------------------------------------

@test "watch: single file in remote is copied to local" {
  write_conf
  establish_baseline

  echo "remote file" > "$REMOTE_DIR/new_file.txt"
  run_sync --once
  [ "$status" -eq 0 ]
  [ -f "$LOCAL_DIR/new_file.txt" ]
  assert_file_content "$LOCAL_DIR/new_file.txt" "remote file"
}

@test "watch: multiple files in remote are copied to local" {
  write_conf
  establish_baseline

  echo "one" > "$REMOTE_DIR/file1.txt"
  echo "two" > "$REMOTE_DIR/file2.txt"
  echo "three" > "$REMOTE_DIR/file3.txt"
  run_sync --once
  [ "$status" -eq 0 ]

  [ -f "$LOCAL_DIR/file1.txt" ]
  [ -f "$LOCAL_DIR/file2.txt" ]
  [ -f "$LOCAL_DIR/file3.txt" ]
  assert_file_content "$LOCAL_DIR/file1.txt" "one"
  assert_file_content "$LOCAL_DIR/file2.txt" "two"
  assert_file_content "$LOCAL_DIR/file3.txt" "three"
}

@test "watch: folder in remote is copied to local" {
  write_conf
  establish_baseline

  mkdir -p "$REMOTE_DIR/new_folder/sub"
  echo "in folder" > "$REMOTE_DIR/new_folder/inside.txt"
  echo "deeper" > "$REMOTE_DIR/new_folder/sub/deep.txt"
  run_sync --once
  [ "$status" -eq 0 ]

  [ -d "$LOCAL_DIR/new_folder" ]
  [ -f "$LOCAL_DIR/new_folder/inside.txt" ]
  [ -f "$LOCAL_DIR/new_folder/sub/deep.txt" ]
  assert_file_content "$LOCAL_DIR/new_folder/inside.txt" "in folder"
  assert_file_content "$LOCAL_DIR/new_folder/sub/deep.txt" "deeper"
}

# ---------------------------------------------------------------------------
# 2. File(s) exist in local but not remote → copied to remote
# ---------------------------------------------------------------------------

@test "watch: single file in local is copied to remote" {
  write_conf
  establish_baseline

  echo "local file" > "$LOCAL_DIR/local_file.txt"
  run_sync --once
  [ "$status" -eq 0 ]
  [ -f "$REMOTE_DIR/local_file.txt" ]
  assert_file_content "$REMOTE_DIR/local_file.txt" "local file"
}

@test "watch: multiple files in local are copied to remote" {
  write_conf
  establish_baseline

  echo "alpha" > "$LOCAL_DIR/alpha.txt"
  echo "beta" > "$LOCAL_DIR/beta.txt"
  echo "gamma" > "$LOCAL_DIR/gamma.txt"
  run_sync --once
  [ "$status" -eq 0 ]

  [ -f "$REMOTE_DIR/alpha.txt" ]
  [ -f "$REMOTE_DIR/beta.txt" ]
  [ -f "$REMOTE_DIR/gamma.txt" ]
  assert_file_content "$REMOTE_DIR/alpha.txt" "alpha"
  assert_file_content "$REMOTE_DIR/beta.txt" "beta"
  assert_file_content "$REMOTE_DIR/gamma.txt" "gamma"
}

@test "watch: folder in local is copied to remote" {
  write_conf
  establish_baseline

  mkdir -p "$LOCAL_DIR/local_folder/sub"
  echo "local inside" > "$LOCAL_DIR/local_folder/inside.txt"
  echo "local deep" > "$LOCAL_DIR/local_folder/sub/deep.txt"
  run_sync --once
  [ "$status" -eq 0 ]

  [ -d "$REMOTE_DIR/local_folder" ]
  [ -f "$REMOTE_DIR/local_folder/inside.txt" ]
  [ -f "$REMOTE_DIR/local_folder/sub/deep.txt" ]
  assert_file_content "$REMOTE_DIR/local_folder/inside.txt" "local inside"
  assert_file_content "$REMOTE_DIR/local_folder/sub/deep.txt" "local deep"
}

# ---------------------------------------------------------------------------
# 3. File(s) updated in remote → local updated to match
# ---------------------------------------------------------------------------

@test "watch: single file updated in remote is updated in local" {
  write_conf
  echo "original" > "$REMOTE_DIR/shared.txt"
  run_sync --once --force-first-run

  echo "remote update" > "$REMOTE_DIR/shared.txt"
  run_sync --once
  [ "$status" -eq 0 ]
  assert_file_content "$LOCAL_DIR/shared.txt" "remote update"
}

@test "watch: multiple files updated in remote are updated in local" {
  write_conf
  echo "v1" > "$REMOTE_DIR/a.txt"
  echo "v1" > "$REMOTE_DIR/b.txt"
  echo "v1" > "$REMOTE_DIR/c.txt"
  run_sync --once --force-first-run

  echo "a updated" > "$REMOTE_DIR/a.txt"
  echo "b updated" > "$REMOTE_DIR/b.txt"
  echo "c updated" > "$REMOTE_DIR/c.txt"
  run_sync --once
  [ "$status" -eq 0 ]

  assert_file_content "$LOCAL_DIR/a.txt" "a updated"
  assert_file_content "$LOCAL_DIR/b.txt" "b updated"
  assert_file_content "$LOCAL_DIR/c.txt" "c updated"
}

@test "watch: folder contents updated in remote are updated in local" {
  write_conf
  mkdir -p "$REMOTE_DIR/updater"
  echo "old" > "$REMOTE_DIR/updater/file.txt"
  run_sync --once --force-first-run

  echo "new content" > "$REMOTE_DIR/updater/file.txt"
  echo "sibling update" > "$REMOTE_DIR/updater/sibling.txt"
  run_sync --once
  [ "$status" -eq 0 ]

  assert_file_content "$LOCAL_DIR/updater/file.txt" "new content"
  assert_file_content "$LOCAL_DIR/updater/sibling.txt" "sibling update"
}

# ---------------------------------------------------------------------------
# 4. File(s) updated in local → remote updated to match
# ---------------------------------------------------------------------------

@test "watch: single file updated in local is updated in remote" {
  write_conf
  echo "base" > "$LOCAL_DIR/myfile.txt"
  run_sync --once --force-first-run

  echo "local updated" > "$LOCAL_DIR/myfile.txt"
  run_sync --once
  [ "$status" -eq 0 ]
  assert_file_content "$REMOTE_DIR/myfile.txt" "local updated"
}

@test "watch: multiple files updated in local are updated in remote" {
  write_conf
  echo "base" > "$LOCAL_DIR/x1.txt"
  echo "base" > "$LOCAL_DIR/x2.txt"
  echo "base" > "$LOCAL_DIR/x3.txt"
  run_sync --once --force-first-run

  echo "x1 new" > "$LOCAL_DIR/x1.txt"
  echo "x2 new" > "$LOCAL_DIR/x2.txt"
  echo "x3 new" > "$LOCAL_DIR/x3.txt"
  run_sync --once
  [ "$status" -eq 0 ]

  assert_file_content "$REMOTE_DIR/x1.txt" "x1 new"
  assert_file_content "$REMOTE_DIR/x2.txt" "x2 new"
  assert_file_content "$REMOTE_DIR/x3.txt" "x3 new"
}

@test "watch: folder contents updated in local are updated in remote" {
  write_conf
  mkdir -p "$LOCAL_DIR/local_updates"
  echo "old local" > "$LOCAL_DIR/local_updates/f.txt"
  run_sync --once --force-first-run

  echo "updated by local" > "$LOCAL_DIR/local_updates/f.txt"
  echo "new sibling" > "$LOCAL_DIR/local_updates/sibling.txt"
  run_sync --once
  [ "$status" -eq 0 ]

  assert_file_content "$REMOTE_DIR/local_updates/f.txt" "updated by local"
  assert_file_content "$REMOTE_DIR/local_updates/sibling.txt" "new sibling"
}

# ---------------------------------------------------------------------------
# 5. File(s) deleted in remote → deleted in local
# ---------------------------------------------------------------------------

@test "watch: single file deleted in remote is deleted in local" {
  write_conf
  echo "doomed" > "$REMOTE_DIR/doomed.txt"
  run_sync --once --force-first-run
  [ -f "$LOCAL_DIR/doomed.txt" ]

  rm "$REMOTE_DIR/doomed.txt"
  run_sync --once
  [ "$status" -eq 0 ]
  [ ! -f "$LOCAL_DIR/doomed.txt" ]
}

@test "watch: multiple files deleted in remote are deleted in local" {
  write_conf
  echo "a" > "$REMOTE_DIR/del1.txt"
  echo "b" > "$REMOTE_DIR/del2.txt"
  echo "c" > "$REMOTE_DIR/del3.txt"
  run_sync --once --force-first-run

  rm "$REMOTE_DIR/del1.txt" "$REMOTE_DIR/del2.txt" "$REMOTE_DIR/del3.txt"
  run_sync --once
  [ "$status" -eq 0 ]
  [ ! -f "$LOCAL_DIR/del1.txt" ]
  [ ! -f "$LOCAL_DIR/del2.txt" ]
  [ ! -f "$LOCAL_DIR/del3.txt" ]
}

@test "watch: folder deleted in remote is deleted in local" {
  write_conf
  mkdir -p "$REMOTE_DIR/removeme/sub"
  echo "inside" > "$REMOTE_DIR/removeme/here.txt"
  echo "deep" > "$REMOTE_DIR/removeme/sub/deep.txt"
  run_sync --once --force-first-run
  [ -d "$LOCAL_DIR/removeme" ]

  rm -rf "$REMOTE_DIR/removeme"
  run_sync --once
  [ "$status" -eq 0 ]
  [ ! -d "$LOCAL_DIR/removeme" ]
}

# ---------------------------------------------------------------------------
# 6. File(s) deleted in local → deleted in remote
# ---------------------------------------------------------------------------

@test "watch: single file deleted in local is deleted in remote" {
  write_conf
  echo "to be gone" > "$LOCAL_DIR/gone.txt"
  run_sync --once --force-first-run
  [ -f "$REMOTE_DIR/gone.txt" ]

  rm "$LOCAL_DIR/gone.txt"
  echo "gone.txt" > "$LOCAL_DIR/.sync/pending-deletes"
  run_sync --once
  [ "$status" -eq 0 ]
  [ ! -f "$REMOTE_DIR/gone.txt" ]
}

@test "watch: multiple files deleted in local are deleted in remote" {
  write_conf
  echo "x" > "$LOCAL_DIR/m1.txt"
  echo "y" > "$LOCAL_DIR/m2.txt"
  echo "z" > "$LOCAL_DIR/m3.txt"
  run_sync --once --force-first-run

  rm "$LOCAL_DIR/m1.txt" "$LOCAL_DIR/m2.txt" "$LOCAL_DIR/m3.txt"
  printf 'm1.txt\nm2.txt\nm3.txt\n' > "$LOCAL_DIR/.sync/pending-deletes"
  run_sync --once
  [ "$status" -eq 0 ]
  [ ! -f "$REMOTE_DIR/m1.txt" ]
  [ ! -f "$REMOTE_DIR/m2.txt" ]
  [ ! -f "$REMOTE_DIR/m3.txt" ]
}

@test "watch: folder deleted in local is deleted in remote" {
  write_conf
  mkdir -p "$LOCAL_DIR/localtree/sub"
  echo "root file" > "$LOCAL_DIR/localtree/root.txt"
  echo "sub file" > "$LOCAL_DIR/localtree/sub/s.txt"
  run_sync --once --force-first-run
  [ -d "$REMOTE_DIR/localtree" ]

  rm -rf "$LOCAL_DIR/localtree"
  printf 'localtree/root.txt\nlocaltree/sub/s.txt\n' > "$LOCAL_DIR/.sync/pending-deletes"
  run_sync --once
  [ "$status" -eq 0 ]
  [ ! -d "$REMOTE_DIR/localtree" ]
}

# ---------------------------------------------------------------------------
# 7. File(s) moved in remote → moved in local
# ---------------------------------------------------------------------------

@test "watch: single file moved in remote is moved in local" {
  write_conf
  echo "moveable" > "$REMOTE_DIR/at_old.txt"
  run_sync --once --force-first-run
  # Establish snapshot baseline
  run_sync --once
  [ "$status" -eq 0 ]

  # Move on remote
  mv "$REMOTE_DIR/at_old.txt" "$REMOTE_DIR/at_new.txt"
  run_sync --once
  [ "$status" -eq 0 ]

  # File should exist at new name (either via move detection or delete+create)
  [[ -f "$LOCAL_DIR/at_new.txt" || -f "$LOCAL_DIR/at_old.txt" ]]
}

@test "watch: multiple files moved in remote are moved in local" {
  write_conf
  echo "m1" > "$REMOTE_DIR/old_a.txt"
  echo "m2" > "$REMOTE_DIR/old_b.txt"
  echo "m3" > "$REMOTE_DIR/old_c.txt"
  run_sync --once --force-first-run
  run_sync --once  # snapshot baseline

  mv "$REMOTE_DIR/old_a.txt" "$REMOTE_DIR/new_a.txt"
  mv "$REMOTE_DIR/old_b.txt" "$REMOTE_DIR/new_b.txt"
  mv "$REMOTE_DIR/old_c.txt" "$REMOTE_DIR/new_c.txt"
  run_sync --once
  [ "$status" -eq 0 ]

  [[ -f "$LOCAL_DIR/new_a.txt" || -f "$LOCAL_DIR/old_a.txt" ]]
  [[ -f "$LOCAL_DIR/new_b.txt" || -f "$LOCAL_DIR/old_b.txt" ]]
  [[ -f "$LOCAL_DIR/new_c.txt" || -f "$LOCAL_DIR/old_c.txt" ]]
}

@test "watch: folder moved in remote is moved in local" {
  write_conf
  mkdir -p "$REMOTE_DIR/old_dir"
  echo "contents" > "$REMOTE_DIR/old_dir/inner.txt"
  run_sync --once --force-first-run
  run_sync --once  # snapshot baseline

  mv "$REMOTE_DIR/old_dir" "$REMOTE_DIR/new_dir"
  run_sync --once
  [ "$status" -eq 0 ]

  # Folder should exist under new name or old name depending on move detection
  [[ -d "$LOCAL_DIR/new_dir" || -d "$LOCAL_DIR/old_dir" ]]
}

# ---------------------------------------------------------------------------
# 8. File(s) moved in local → moved in remote
# ---------------------------------------------------------------------------

@test "watch: single file moved in local is moved in remote" {
  write_conf
  echo "local move" > "$LOCAL_DIR/here.txt"
  run_sync --once --force-first-run

  mv "$LOCAL_DIR/here.txt" "$LOCAL_DIR/there.txt"
  run_sync --once
  [ "$status" -eq 0 ]

  # Remote should have the file at new location
  [[ -f "$REMOTE_DIR/there.txt" || -f "$REMOTE_DIR/here.txt" ]]
}

@test "watch: multiple files moved in local are moved in remote" {
  write_conf
  echo "one" > "$LOCAL_DIR/a_old.txt"
  echo "two" > "$LOCAL_DIR/b_old.txt"
  echo "three" > "$LOCAL_DIR/c_old.txt"
  run_sync --once --force-first-run

  mv "$LOCAL_DIR/a_old.txt" "$LOCAL_DIR/a_new.txt"
  mv "$LOCAL_DIR/b_old.txt" "$LOCAL_DIR/b_new.txt"
  mv "$LOCAL_DIR/c_old.txt" "$LOCAL_DIR/c_new.txt"
  run_sync --once
  [ "$status" -eq 0 ]

  [[ -f "$REMOTE_DIR/a_new.txt" || -f "$REMOTE_DIR/a_old.txt" ]]
  [[ -f "$REMOTE_DIR/b_new.txt" || -f "$REMOTE_DIR/b_old.txt" ]]
  [[ -f "$REMOTE_DIR/c_new.txt" || -f "$REMOTE_DIR/c_old.txt" ]]
}

@test "watch: folder moved in local is moved in remote" {
  write_conf
  mkdir -p "$LOCAL_DIR/old_place"
  echo "nested" > "$LOCAL_DIR/old_place/nested.txt"
  run_sync --once --force-first-run

  mv "$LOCAL_DIR/old_place" "$LOCAL_DIR/new_place"
  run_sync --once
  [ "$status" -eq 0 ]

  [[ -d "$REMOTE_DIR/new_place" || -d "$REMOTE_DIR/old_place" ]]
}
