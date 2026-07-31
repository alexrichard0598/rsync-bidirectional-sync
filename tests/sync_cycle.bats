#!/usr/bin/env bats
# Integration tests that run real sync cycles in local-to-local mode
# (REMOTE=""). This exercises the full rsync pipeline -- pull, push,
# conflict resolution, both deletion mechanisms, and symlink handling --
# without needing sshd or network access.

load 'test_helper.bash'

setup() {
  setup_sync_dirs
}

# --- first-run safety gate --------------------------------------------------

@test "first run is refused without --force-first-run or --dry-run" {
  write_conf
  run_sync --once
  [ "$status" -eq 3 ]
  [[ "$output" == *"First run refused"* ]]
}

@test "first run --dry-run previews without creating sentinels or files" {
  write_conf
  echo hello > "$LOCAL_DIR/only-local.txt"
  run_sync --once --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$LOCAL_DIR/.sync/.sync-root" ]
  [ ! -f "$REMOTE_DIR/only-local.txt" ]
}

@test "--force-first-run performs the sync and registers both sentinels" {
  write_conf
  echo hello > "$LOCAL_DIR/only-local.txt"
  run_sync --once --force-first-run
  [ "$status" -eq 0 ]
  [ -f "$LOCAL_DIR/.sync/.sync-root" ]
  [ -f "$REMOTE_DIR/.sync/.sync-root" ]
  assert_file_content "$REMOTE_DIR/only-local.txt" "hello"
}

@test "once both sentinels exist, a plain --once no longer needs --force-first-run" {
  write_conf
  establish_baseline
  echo again > "$LOCAL_DIR/second.txt"
  run_sync --once
  [ "$status" -eq 0 ]
  assert_file_content "$REMOTE_DIR/second.txt" "again"
}

@test "an asymmetric sentinel (one side wiped) is refused, not silently mirrored" {
  write_conf
  establish_baseline
  rm -rf "$REMOTE_DIR/.sync"
  run_sync --once
  [ "$status" -eq 3 ]
  [[ "$output" == *"sentinel MISSING"* ]]
}

# --- basic push / pull ------------------------------------------------------

@test "a new local file is pushed to the remote" {
  write_conf
  establish_baseline
  echo "local content" > "$LOCAL_DIR/pushed.txt"
  run_sync --once
  [ "$status" -eq 0 ]
  assert_file_content "$REMOTE_DIR/pushed.txt" "local content"
}

@test "a new remote file is pulled to local" {
  write_conf
  establish_baseline
  echo "remote content" > "$REMOTE_DIR/pulled.txt"
  run_sync --once
  [ "$status" -eq 0 ]
  assert_file_content "$LOCAL_DIR/pulled.txt" "remote content"
}

@test "--pull-only never pushes a new local file" {
  write_conf
  establish_baseline
  echo "should stay local" > "$LOCAL_DIR/local-only.txt"
  run_sync --once --pull-only
  [ "$status" -eq 0 ]
  [ ! -f "$REMOTE_DIR/local-only.txt" ]
}

@test "--push-only never pulls a new remote file" {
  write_conf
  establish_baseline
  echo "should stay remote" > "$REMOTE_DIR/remote-only.txt"
  run_sync --once --push-only
  [ "$status" -eq 0 ]
  [ ! -f "$LOCAL_DIR/remote-only.txt" ]
}

@test "an unchanged tree produces a no-op cycle" {
  write_conf
  establish_baseline
  echo same > "$LOCAL_DIR/steady.txt"
  run_sync --once
  [ "$status" -eq 0 ]
  run_sync --once --verbose
  [ "$status" -eq 0 ]
  [[ "$output" == *"already in sync"* ]]
}

# --- conflict resolution: remote wins ---------------------------------------

@test "a file changed on both sides: remote content wins locally" {
  write_conf
  echo original > "$LOCAL_DIR/shared.txt"
  run_sync --once --force-first-run
  [ "$status" -eq 0 ]

  echo "local edit"  > "$LOCAL_DIR/shared.txt"
  echo "remote edit" > "$REMOTE_DIR/shared.txt"
  run_sync --once
  [ "$status" -eq 0 ]

  assert_file_content "$LOCAL_DIR/shared.txt" "remote edit"
  assert_file_content "$REMOTE_DIR/shared.txt" "remote edit"
}

@test "the losing local edit is archived under .sync/conflicts/, not lost" {
  write_conf
  echo original > "$LOCAL_DIR/shared.txt"
  run_sync --once --force-first-run

  echo "local edit"  > "$LOCAL_DIR/shared.txt"
  echo "remote edit" > "$REMOTE_DIR/shared.txt"
  run_sync --once
  [ "$status" -eq 0 ]

  local backup
  backup="$(find "$LOCAL_DIR/.sync/conflicts" -name shared.txt -print -quit)"
  [ -n "$backup" ]
  assert_file_content "$backup" "local edit"
}

@test "push never clobbers a remote file that changed more recently" {
  # --update on the push means an mtime-newer remote file survives even if
  # the pull step somehow missed it in this cycle.
  write_conf
  echo original > "$LOCAL_DIR/race.txt"
  run_sync --once --force-first-run

  echo "remote newer" > "$REMOTE_DIR/race.txt"
  sleep 1
  echo "local older content, touched after" > "$LOCAL_DIR/race.txt"
  touch -d "1 hour ago" "$LOCAL_DIR/race.txt"

  run_sync --once
  [ "$status" -eq 0 ]
  assert_file_content "$REMOTE_DIR/race.txt" "remote newer"
}

# --- deletions: push side (journal-driven) ----------------------------------

@test "a local deletion journaled by the watcher removes the remote file" {
  write_conf
  echo bye > "$LOCAL_DIR/doomed.txt"
  run_sync --once --force-first-run
  [ -f "$REMOTE_DIR/doomed.txt" ]

  rm "$LOCAL_DIR/doomed.txt"
  # Simulate what the inotify watcher would have journaled.
  echo "doomed.txt" > "$LOCAL_DIR/.sync/pending-deletes"

  run_sync --once
  [ "$status" -eq 0 ]
  [ ! -f "$REMOTE_DIR/doomed.txt" ]
}

@test "a journaled deletion is skipped if the file was recreated (atomic save)" {
  write_conf
  echo v1 > "$LOCAL_DIR/edited.txt"
  run_sync --once --force-first-run

  # An editor's atomic save: unlink then recreate. The recreated file existing
  # again locally must stop the queued delete from reaching the remote --
  # regardless of what conflict resolution later does with its content.
  rm "$LOCAL_DIR/edited.txt"
  echo v2 > "$LOCAL_DIR/edited.txt"
  echo "edited.txt" > "$LOCAL_DIR/.sync/pending-deletes"

  run_sync --once
  [ "$status" -eq 0 ]
  [ -f "$REMOTE_DIR/edited.txt" ]
  [[ "$output" == *"exists again locally"* ]]
}

@test "with TRASH_ENABLED, a journaled remote deletion lands in remote trash" {
  write_conf TRASH_ENABLED=true
  echo bye > "$LOCAL_DIR/doomed.txt"
  run_sync --once --force-first-run

  rm "$LOCAL_DIR/doomed.txt"
  echo "doomed.txt" > "$LOCAL_DIR/.sync/pending-deletes"
  run_sync --once
  [ "$status" -eq 0 ]

  local trashed
  trashed="$(find "$REMOTE_DIR/.sync/trash" -name doomed.txt -print -quit)"
  [ -n "$trashed" ]
}

@test "DELETE_MODE=none ignores the journal entirely" {
  write_conf DELETE_MODE="none"
  echo bye > "$LOCAL_DIR/keepme.txt"
  run_sync --once --force-first-run

  rm "$LOCAL_DIR/keepme.txt"
  echo "keepme.txt" > "$LOCAL_DIR/.sync/pending-deletes"
  run_sync --once
  [ "$status" -eq 0 ]
  [ -f "$REMOTE_DIR/keepme.txt" ]
}

@test "journaled deletions over MAX_DELETE are refused, not partially applied" {
  write_conf MAX_DELETE=1
  echo a > "$LOCAL_DIR/a.txt"
  echo b > "$LOCAL_DIR/b.txt"
  run_sync --once --force-first-run

  rm "$LOCAL_DIR/a.txt" "$LOCAL_DIR/b.txt"
  printf 'a.txt\nb.txt\n' > "$LOCAL_DIR/.sync/pending-deletes"

  run_sync --once
  # Refused deletions re-queue and are reported, but the run itself doesn't
  # crash; both files must still exist remotely.
  [ -f "$REMOTE_DIR/a.txt" ]
  [ -f "$REMOTE_DIR/b.txt" ]
  [[ "$output" == *"MAX_DELETE"* ]]
}

# --- deletions: pull side (snapshot-diff-driven) ----------------------------

@test "a remote deletion is detected via snapshot diff and removed locally" {
  write_conf
  echo bye > "$LOCAL_DIR/remote-doomed.txt"
  run_sync --once --force-first-run
  # First cycle after baseline establishes the remote snapshot.
  run_sync --once
  [ -f "$LOCAL_DIR/remote-doomed.txt" ]

  rm "$REMOTE_DIR/remote-doomed.txt"
  run_sync --once
  [ "$status" -eq 0 ]
  [ ! -f "$LOCAL_DIR/remote-doomed.txt" ]
}

@test "a file created locally is never mistaken for a remote deletion" {
  # The whole reason pull avoids a blanket --delete: a brand new local file
  # must survive even though it "only exists on one side", same shape as a
  # genuine remote deletion.
  write_conf
  establish_baseline
  run_sync --once   # records the (empty-ish) remote snapshot baseline

  echo "brand new" > "$LOCAL_DIR/new-local-file.txt"
  run_sync --once
  [ "$status" -eq 0 ]
  [ -f "$LOCAL_DIR/new-local-file.txt" ]
  assert_file_content "$REMOTE_DIR/new-local-file.txt" "brand new"
}

# --- symlinks ---------------------------------------------------------------

@test "a symlink is pushed as a symlink, not dereferenced content" {
  write_conf
  echo "target contents" > "$LOCAL_DIR/target.txt"
  ln -s target.txt "$LOCAL_DIR/link.txt"
  run_sync --once --force-first-run
  [ "$status" -eq 0 ]
  [ -L "$REMOTE_DIR/link.txt" ]
  [ "$(readlink "$REMOTE_DIR/link.txt")" == "target.txt" ]
}

@test "a symlink pointing outside the tree is copied as an inert link" {
  write_conf
  ln -s /etc/hostname "$LOCAL_DIR/outside-link"
  run_sync --once --force-first-run
  [ "$status" -eq 0 ]
  [ -L "$REMOTE_DIR/outside-link" ]
  [ "$(readlink "$REMOTE_DIR/outside-link")" == "/etc/hostname" ]
  # Confined, not followed: no /etc/hostname content leaked into the tree.
  [ ! -e "$REMOTE_DIR/hostname" ]
}
