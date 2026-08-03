#!/usr/bin/env bats
# CLI parsing and config-validation tests. These invoke rsync-live-mirror.sh as a real
# subprocess (not sourced) since they exercise argument parsing, exit codes,
# and validate_config()'s interaction with a real sync.conf on disk.

load 'test_helper.bash'

setup() {
  setup_sync_dirs
}

# --- basic CLI ------------------------------------------------------------

@test "--help exits 0 and prints usage" {
  run "$SYNC_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"USAGE"* ]]
  [[ "$output" == *"--dry-run"* ]]
}

@test "--version prints the script name and version" {
  run "$SYNC_SH" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"rsync-live-mirror.sh"* ]]
}

@test "an unknown option is rejected with the config exit code" {
  run "$SYNC_SH" --this-flag-does-not-exist
  [ "$status" -eq 1 ]
}

@test "--dir without a path argument is rejected" {
  run "$SYNC_SH" --dir
  [ "$status" -eq 1 ]
}

@test "no sync.conf anywhere up the tree is a config error" {
  # An empty dir with no sync.conf and no parent config.
  run "$SYNC_SH" --dir "$LOCAL_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no sync.conf"* ]]
}

@test "--dir pointing at a non-directory is rejected" {
  run "$SYNC_SH" --dir "$LOCAL_DIR/not-a-real-dir"
  [ "$status" -eq 1 ]
}

# --- validate_config: required keys and enums ------------------------------

@test "missing REMOTE_DIR is a config error" {
  echo 'REMOTE=""' > "$LOCAL_DIR/sync.conf"
  run_sync --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"REMOTE_DIR"* ]]
}

@test "an invalid DELETE_MODE is rejected" {
  write_conf DELETE_MODE="sideways"
  run_sync --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DELETE_MODE"* ]]
}

@test "an invalid PULL_COMPARE is rejected" {
  write_conf PULL_COMPARE="vibes"
  run_sync --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"PULL_COMPARE"* ]]
}

@test "an invalid REMOTE_WATCH is rejected" {
  write_conf REMOTE_WATCH="telepathy"
  run_sync --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"REMOTE_WATCH"* ]]
}

@test "a non-boolean value for a boolean key is rejected" {
  write_conf TRASH_ENABLED="yes-please"
  run_sync --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"TRASH_ENABLED"* ]]
}

@test "a non-numeric value for a numeric key is rejected" {
  write_conf REMOTE_POLL_INTERVAL="soon"
  run_sync --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"REMOTE_POLL_INTERVAL"* ]]
}

@test "MAX_DELETE accepts -1 as 'unlimited'" {
  write_conf MAX_DELETE="-1"
  run_sync --check
  [ "$status" -eq 0 ]
}

@test "DEBOUNCE_SECONDS below 1 is silently clamped, not rejected" {
  write_conf DEBOUNCE_SECONDS="0"
  run_sync --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEBOUNCE_SECONDS raised to 1"* ]]
}

# --- validate_config: path safety ------------------------------------------

@test "REMOTE_DIR pointing at a forbidden system directory is refused" {
  write_conf REMOTE_DIR="/etc"
  run_sync --check
  [ "$status" -eq 3 ]
  [[ "$output" == *"system directory"* ]]
}

@test "a local sync root that does not exist is a config error" {
  local nonexistent="${BATS_TEST_TMPDIR}/does/not/exist"
  echo 'REMOTE=""' > /dev/null # placeholder, conf written manually below
  mkdir -p "$(dirname "$nonexistent")"
  LOCAL_DIR="$nonexistent"
  run "$SYNC_SH" --dir "$LOCAL_DIR" --check
  [ "$status" -eq 1 ]
}

@test "overlapping local-to-local roots are refused" {
  # REMOTE_DIR nested inside LOCAL_DIR: rsync would recurse into its own
  # destination.
  local nested="$LOCAL_DIR/nested-remote"
  mkdir -p "$nested"
  write_conf REMOTE_DIR="$nested"
  run_sync --check
  [ "$status" -eq 3 ]
  [[ "$output" == *"overlap"* ]]
}

@test "local-to-local mode requires REMOTE_DIR to already exist" {
  write_conf REMOTE_DIR="${BATS_TEST_TMPDIR}/never-created"
  run_sync --check
  [ "$status" -eq 1 ]
}

# --- config file permissions -----------------------------------------------

@test "a world-writable sync.conf is refused, since it is sourced as code" {
  write_conf
  chmod 666 "$LOCAL_DIR/sync.conf"
  run_sync --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"world-writable"* ]]
}

@test "a syntactically broken sync.conf fails cleanly instead of crashing" {
  echo 'REMOTE_DIR="/unterminated' > "$LOCAL_DIR/sync.conf"
  run_sync --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"syntax error"* ]]
}

# --- --check on an otherwise-valid config ----------------------------------

@test "--check on a valid local-to-local config succeeds and is read-only" {
  write_conf
  run_sync --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"configuration looks good"* ]]
  # --check must not create the sentinel or any state.
  [ ! -f "$LOCAL_DIR/.sync/.sync-root" ]
}

@test "--check reports asymmetric sentinels as a safety problem" {
  write_conf
  mkdir -p "$LOCAL_DIR/.sync"
  touch "$LOCAL_DIR/.sync/.sync-root"
  run_sync --check
  [ "$status" -eq 3 ]
  [[ "$output" == *"ASYMMETRIC"* ]]
}
