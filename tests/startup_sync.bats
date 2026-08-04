#!/usr/bin/env bats
# Startup Sync integration tests (Part 2a — simple one-sided offline changes).
#
# These scenarios test syncing changes that happened while rsync-live-mirror
# was NOT running, once it is started. Each scenario covers:
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
# Part 2a — Simple one-sided changes (offline changes, single direction)
# ===========================================================================
# These simulate the tool being offline while changes happen on one side,
# then the tool starts and reconciles the differences.
# ===========================================================================

# ---------------------------------------------------------------------------
# 2a.1 File(s) created in remote (while tool was offline) → created in local
# ---------------------------------------------------------------------------

@test "startup: single file created in remote offline is created in local" {
  write_conf
  # Simulate: remote had a file all along, tool just didn't know about it
  echo "remote only" > "$REMOTE_DIR/remote_new.txt"
  run_sync --once --force-first-run
  [ "$status" -eq 0 ]
  [ -f "$LOCAL_DIR/remote_new.txt" ]
  assert_file_content "$LOCAL_DIR/remote_new.txt" "remote only"
}

@test "startup: multiple files created in remote offline are created in local" {
  write_conf
  echo "r1" > "$REMOTE_DIR/offline1.txt"
  echo "r2" > "$REMOTE_DIR/offline2.txt"
  echo "r3" > "$REMOTE_DIR/offline3.txt"
  run_sync --once --force-first-run
  [ "$status" -eq 0 ]

  [ -f "$LOCAL_DIR/offline1.txt" ]
  [ -f "$LOCAL_DIR/offline2.txt" ]
  [ -f "$LOCAL_DIR/offline3.txt" ]
  assert_file_content "$LOCAL_DIR/offline1.txt" "r1"
  assert_file_content "$LOCAL_DIR/offline2.txt" "r2"
  assert_file_content "$LOCAL_DIR/offline3.txt" "r3"
}

@test "startup: folder created in remote offline is created in local" {
  write_conf
  mkdir -p "$REMOTE_DIR/offline_dir/sub"
  echo "in remote folder" > "$REMOTE_DIR/offline_dir/here.txt"
  echo "deeper" > "$REMOTE_DIR/offline_dir/sub/deep.txt"
  run_sync --once --force-first-run
  [ "$status" -eq 0 ]

  [ -d "$LOCAL_DIR/offline_dir" ]
  [ -f "$LOCAL_DIR/offline_dir/here.txt" ]
  [ -f "$LOCAL_DIR/offline_dir/sub/deep.txt" ]
}

# ---------------------------------------------------------------------------
# 2a.2 File(s) created in local (while tool was offline) → created in remote
# ---------------------------------------------------------------------------

@test "startup: single file created in local offline is created in remote" {
  write_conf
  echo "local only" > "$LOCAL_DIR/local_new.txt"
  run_sync --once --force-first-run
  [ "$status" -eq 0 ]
  [ -f "$REMOTE_DIR/local_new.txt" ]
  assert_file_content "$REMOTE_DIR/local_new.txt" "local only"
}

@test "startup: multiple files created in local offline are created in remote" {
  write_conf
  echo "l1" > "$LOCAL_DIR/local1.txt"
  echo "l2" > "$LOCAL_DIR/local2.txt"
  echo "l3" > "$LOCAL_DIR/local3.txt"
  run_sync --once --force-first-run
  [ "$status" -eq 0 ]

  [ -f "$REMOTE_DIR/local1.txt" ]
  [ -f "$REMOTE_DIR/local2.txt" ]
  [ -f "$REMOTE_DIR/local3.txt" ]
  assert_file_content "$REMOTE_DIR/local1.txt" "l1"
  assert_file_content "$REMOTE_DIR/local2.txt" "l2"
  assert_file_content "$REMOTE_DIR/local3.txt" "l3"
}

@test "startup: folder created in local offline is created in remote" {
  write_conf
  mkdir -p "$LOCAL_DIR/local_dir/offline_sub"
  echo "local nested" > "$LOCAL_DIR/local_dir/nested.txt"
  echo "very deep" > "$LOCAL_DIR/local_dir/offline_sub/deep.txt"
  run_sync --once --force-first-run
  [ "$status" -eq 0 ]

  [ -d "$REMOTE_DIR/local_dir" ]
  [ -f "$REMOTE_DIR/local_dir/nested.txt" ]
  [ -f "$REMOTE_DIR/local_dir/offline_sub/deep.txt" ]
}

# ---------------------------------------------------------------------------
# 2a.3 File(s) updated in remote (while tool was offline) → updated in local
# ---------------------------------------------------------------------------

@test "startup: single file updated in remote offline is updated in local" {
  write_conf
  echo "version1" > "$REMOTE_DIR/base.txt"
  run_sync --once --force-first-run
  # Baseline established; now remote updates the file while "offline"
  echo "version2" > "$REMOTE_DIR/base.txt"
  run_sync --once
  [ "$status" -eq 0 ]
  assert_file_content "$LOCAL_DIR/base.txt" "version2"
}

@test "startup: multiple files updated in remote offline are updated in local" {
  write_conf
  echo "old_a" > "$REMOTE_DIR/ma.txt"
  echo "old_b" > "$REMOTE_DIR/mb.txt"
  echo "old_c" > "$REMOTE_DIR/mc.txt"
  run_sync --once --force-first-run

  # Offline updates on remote
  echo "new_a" > "$REMOTE_DIR/ma.txt"
  echo "new_b" > "$REMOTE_DIR/mb.txt"
  echo "new_c" > "$REMOTE_DIR/mc.txt"
  run_sync --once
  [ "$status" -eq 0 ]

  assert_file_content "$LOCAL_DIR/ma.txt" "new_a"
  assert_file_content "$LOCAL_DIR/mb.txt" "new_b"
  assert_file_content "$LOCAL_DIR/mc.txt" "new_c"
}

@test "startup: folder contents updated in remote offline are updated in local" {
  write_conf
  mkdir -p "$REMOTE_DIR/folder_update"
  echo "old content" > "$REMOTE_DIR/folder_update/file.txt"
  run_sync --once --force-first-run

  # Offline update
  echo "new content from remote" > "$REMOTE_DIR/folder_update/file.txt"
  echo "sibling update" > "$REMOTE_DIR/folder_update/sibling.txt"
  run_sync --once
  [ "$status" -eq 0 ]

  assert_file_content "$LOCAL_DIR/folder_update/file.txt" "new content from remote"
  assert_file_content "$LOCAL_DIR/folder_update/sibling.txt" "sibling update"
}

# ---------------------------------------------------------------------------
# 2a.4 File(s) updated in local (while tool was offline) → updated in remote
# ---------------------------------------------------------------------------

@test "startup: single file updated in local offline is updated in remote" {
  write_conf
  echo "base" > "$LOCAL_DIR/local_base.txt"
  run_sync --once --force-first-run

  # Offline update on local
  echo "local changed this" > "$LOCAL_DIR/local_base.txt"
  run_sync --once
  [ "$status" -eq 0 ]
  assert_file_content "$REMOTE_DIR/local_base.txt" "local changed this"
}

@test "startup: multiple files updated in local offline are updated in remote" {
  write_conf
  echo "x" > "$LOCAL_DIR/lx.txt"
  echo "y" > "$LOCAL_DIR/ly.txt"
  echo "z" > "$LOCAL_DIR/lz.txt"
  run_sync --once --force-first-run

  # Offline updates
  echo "lx_new" > "$LOCAL_DIR/lx.txt"
  echo "ly_new" > "$LOCAL_DIR/ly.txt"
  echo "lz_new" > "$LOCAL_DIR/lz.txt"
  run_sync --once
  [ "$status" -eq 0 ]

  assert_file_content "$REMOTE_DIR/lx.txt" "lx_new"
  assert_file_content "$REMOTE_DIR/ly.txt" "ly_new"
  assert_file_content "$REMOTE_DIR/lz.txt" "lz_new"
}

@test "startup: folder contents updated in local offline are updated in remote" {
  write_conf
  mkdir -p "$LOCAL_DIR/local_fold"
  echo "old local" > "$LOCAL_DIR/local_fold/inner.txt"
  run_sync --once --force-first-run

  # Offline update
  echo "updated by local" > "$LOCAL_DIR/local_fold/inner.txt"
  echo "brand new sibling" > "$LOCAL_DIR/local_fold/brother.txt"
  run_sync --once
  [ "$status" -eq 0 ]

  assert_file_content "$REMOTE_DIR/local_fold/inner.txt" "updated by local"
  assert_file_content "$REMOTE_DIR/local_fold/brother.txt" "brand new sibling"
}

# ---------------------------------------------------------------------------
# 2a.5 File(s) deleted in remote (while tool was offline) → deleted in local
# ---------------------------------------------------------------------------

@test "startup: single file deleted in remote offline is deleted in local" {
  write_conf
  echo "will vanish" > "$REMOTE_DIR/will_vanish.txt"
  run_sync --once --force-first-run
  # Establish snapshot
  run_sync --once
  [ -f "$LOCAL_DIR/will_vanish.txt" ]

  # Delete on remote (simulating offline deletion)
  rm "$REMOTE_DIR/will_vanish.txt"
  run_sync --once
  [ "$status" -eq 0 ]
  [ ! -f "$LOCAL_DIR/will_vanish.txt" ]
}

@test "startup: multiple files deleted in remote offline are deleted in local" {
  write_conf
  echo "d1" > "$REMOTE_DIR/del1.txt"
  echo "d2" > "$REMOTE_DIR/del2.txt"
  echo "d3" > "$REMOTE_DIR/del3.txt"
  run_sync --once --force-first-run
  run_sync --once  # snapshot baseline

  rm "$REMOTE_DIR/del1.txt" "$REMOTE_DIR/del2.txt" "$REMOTE_DIR/del3.txt"
  run_sync --once
  [ "$status" -eq 0 ]
  [ ! -f "$LOCAL_DIR/del1.txt" ]
  [ ! -f "$LOCAL_DIR/del2.txt" ]
  [ ! -f "$LOCAL_DIR/del3.txt" ]
}

@test "startup: folder deleted in remote offline is deleted in local" {
  write_conf
  mkdir -p "$REMOTE_DIR/remote_folder/doom"
  echo "root" > "$REMOTE_DIR/remote_folder/root.txt"
  echo "sub" > "$REMOTE_DIR/remote_folder/doom/sub.txt"
  run_sync --once --force-first-run
  run_sync --once  # snapshot baseline
  [ -d "$LOCAL_DIR/remote_folder" ]

  rm -rf "$REMOTE_DIR/remote_folder"
  run_sync --once
  [ "$status" -eq 0 ]
  [ ! -d "$LOCAL_DIR/remote_folder" ]
}

# ---------------------------------------------------------------------------
# 2a.6 File(s) deleted in local (while tool was offline) → deleted in remote
# ---------------------------------------------------------------------------

@test "startup: single file deleted in local offline is deleted in remote" {
  write_conf
  echo "local doomed" > "$LOCAL_DIR/local_doomed.txt"
  run_sync --once --force-first-run
  [ -f "$REMOTE_DIR/local_doomed.txt" ]

  # Delete locally and journal the deletion
  rm "$LOCAL_DIR/local_doomed.txt"
  echo "local_doomed.txt" > "$LOCAL_DIR/.sync/pending-deletes"
  run_sync --once
  [ "$status" -eq 0 ]
  [ ! -f "$REMOTE_DIR/local_doomed.txt" ]
}

@test "startup: multiple files deleted in local offline are deleted in remote" {
  write_conf
  echo "la" > "$LOCAL_DIR/ml1.txt"
  echo "lb" > "$LOCAL_DIR/ml2.txt"
  echo "lc" > "$LOCAL_DIR/ml3.txt"
  run_sync --once --force-first-run

  rm "$LOCAL_DIR/ml1.txt" "$LOCAL_DIR/ml2.txt" "$LOCAL_DIR/ml3.txt"
  printf 'ml1.txt\nml2.txt\nml3.txt\n' > "$LOCAL_DIR/.sync/pending-deletes"
  run_sync --once
  [ "$status" -eq 0 ]
  [ ! -f "$REMOTE_DIR/ml1.txt" ]
  [ ! -f "$REMOTE_DIR/ml2.txt" ]
  [ ! -f "$REMOTE_DIR/ml3.txt" ]
}

@test "startup: folder deleted in local offline is deleted in remote" {
  write_conf
  mkdir -p "$LOCAL_DIR/local_del_tree/deep"
  echo "top" > "$LOCAL_DIR/local_del_tree/top.txt"
  echo "bot" > "$LOCAL_DIR/local_del_tree/deep/bot.txt"
  run_sync --once --force-first-run
  [ -d "$REMOTE_DIR/local_del_tree" ]

  rm -rf "$LOCAL_DIR/local_del_tree"
  printf 'local_del_tree/top.txt\nlocal_del_tree/deep/bot.txt\n' > "$LOCAL_DIR/.sync/pending-deletes"
  run_sync --once
  [ "$status" -eq 0 ]
  [ ! -d "$REMOTE_DIR/local_del_tree" ]
}
