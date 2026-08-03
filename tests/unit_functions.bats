#!/usr/bin/env bats
# Unit tests for self-contained functions in rsync-live-mirror.sh, exercised by sourcing
# a main()-stripped copy of the script (see test_helper.bash). These need no
# rsync transfer and no fixture directories -- just the function under test.

load 'test_helper.bash'

setup() {
  setup_sourceable_lib
}

# --- version_ge --------------------------------------------------------

@test "version_ge: newer patch version is >= required" {
  run_lib 'version_ge 3.2.0 3.1.3'
  [ "$status" -eq 0 ]
}

@test "version_ge: exact match counts as >=" {
  run_lib 'version_ge 3.1.3 3.1.3'
  [ "$status" -eq 0 ]
}

@test "version_ge: older patch version fails" {
  run_lib 'version_ge 3.1.2 3.1.3'
  [ "$status" -ne 0 ]
}

@test "version_ge: older minor version fails even with higher patch" {
  run_lib 'version_ge 3.0.99 3.1.0'
  [ "$status" -ne 0 ]
}

@test "version_ge: missing patch component defaults to 0" {
  # rsync sometimes reports two-part versions ("3.2"); must not crash or
  # miscompare against a three-part requirement.
  run_lib 'version_ge 3.2 3.1.3'
  [ "$status" -eq 0 ]
}

# --- validate_sync_path -------------------------------------------------

@test "validate_sync_path: accepts a deep absolute path" {
  run_lib 'LOCAL_DIR=""; REMOTE_DIR=""
           validate_sync_path "/data/projects/myproject" "test path"'
  [ "$status" -eq 0 ]
}

@test "validate_sync_path: rejects a relative path" {
  run_lib 'validate_sync_path "data/myproject" "test path"'
  [[ "$output" == *"must be an absolute path"* ]]
}

@test "validate_sync_path: rejects a path containing .." {
  run_lib 'validate_sync_path "/data/../etc" "test path"'
  [[ "$output" == *"must not contain"* ]]
}

@test "validate_sync_path: rejects a forbidden system directory" {
  run_lib 'validate_sync_path "/etc" "test path"'
  [[ "$output" == *"system directory"* ]]
}

@test "validate_sync_path: rejects the root directory" {
  run_lib 'validate_sync_path "/" "test path"'
  [[ "$output" == *"system directory"* ]]
}

@test "validate_sync_path: rejects a path only one level deep" {
  run_lib 'validate_sync_path "/data" "test path"'
  [[ "$output" == *"one level below"* ]]
}

@test "validate_sync_path: accepts a path exactly two levels deep" {
  run_lib 'validate_sync_path "/data/project" "test path"'
  [ "$status" -eq 0 ]
}

# --- count_itemized_changes ---------------------------------------------

@test "count_itemized_changes: counts file and dir change lines" {
  run_lib 'count_itemized_changes ">f+++++++++ newfile.txt
cd+++++++++ newdir/
.d..t...... unchanged-dir/"'
  [ "$output" -eq 2 ]
}

@test "count_itemized_changes: counts deletion lines" {
  run_lib 'count_itemized_changes "*deleting   oldfile.txt
*deleting   olddir/"'
  [ "$output" -eq 2 ]
}

@test "count_itemized_changes: returns 0 for empty input" {
  run_lib 'count_itemized_changes ""'
  [ "$output" -eq 0 ]
}

@test "count_itemized_changes: returns 0 when nothing changed" {
  run_lib 'count_itemized_changes ".d..t...... somedir/
.f..t...... somefile.txt"'
  [ "$output" -eq 0 ]
}

# --- shell_quote ----------------------------------------------------------

@test "shell_quote: wraps a plain path in single quotes" {
  run_lib 'shell_quote "/srv/project"'
  [ "$output" == "'/srv/project'" ]
}

@test "shell_quote: escapes an embedded single quote" {
  run_lib "shell_quote \"/srv/it's-project\""
  [[ "$output" == "'/srv/it'\\''s-project'" ]]
}

@test "shell_quote output round-trips through the shell unchanged" {
  run_lib 'q=$(shell_quote "weird \$(rm -rf /) name"); eval "printf %s $q"'
  [ "$output" == 'weird $(rm -rf /) name' ]
}

# --- build_inotify_exclude_regex ----------------------------------------

@test "build_inotify_exclude_regex: always excludes .sync and sync.conf" {
  run_lib 'EXCLUDES=(); build_inotify_exclude_regex'
  [[ "$output" == *'\.sync(/|$)'* ]]
  [[ "$output" == *'sync\.conf$'* ]]
}

@test "build_inotify_exclude_regex: translates an unanchored glob exclude" {
  run_lib 'EXCLUDES=("node_modules/"); build_inotify_exclude_regex'
  [[ "$output" == *'/node_modules(/|$)'* ]]
}

@test "build_inotify_exclude_regex: skips comments and negated patterns" {
  run_lib 'EXCLUDES=("# a comment" "!important.log"); build_inotify_exclude_regex'
  [[ "$output" != *"comment"* ]]
  [[ "$output" != *"important.log"* ]]
}
