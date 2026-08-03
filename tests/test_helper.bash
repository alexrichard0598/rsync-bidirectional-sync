#!/usr/bin/env bash
# =============================================================================
# test_helper.bash -- shared fixtures and helpers for the rsync-live-mirror.sh bats suite
# =============================================================================
#
# All integration tests run in LOCAL-TO-LOCAL mode (REMOTE="") so the suite
# needs no sshd, no network, and no fixtures beyond two plain directories.
# Every code path that matters (validation, pull/push, conflict handling,
# both deletion mechanisms, symlinks, sentinels) is exercised identically in
# this mode -- the only thing local-to-local mode skips is the ssh transport
# itself, which is covered separately by unit tests against
# build_rsync_ssh_transport().
# =============================================================================

# Repo root and the script under test.
SYNC_SH="${BATS_TEST_DIRNAME}/../rsync-live-mirror.sh"

# ---------------------------------------------------------------------------
# Unit-testing support: rsync-live-mirror.sh ends with an unconditional `main "$@"`, so it
# can't be sourced directly without launching the whole program. A copy with
# that last line stripped is sourced instead, inside a throwaway `bash -c`
# subprocess per call -- never into the bats shell itself -- so the script's
# `set -Eeuo pipefail`, global IFS, readonly vars, and EXIT/INT/TERM traps
# never leak into the test runner.
# ---------------------------------------------------------------------------
setup_sourceable_lib() {
  SYNC_LIB="${BATS_FILE_TMPDIR}/sync_lib.sh"
  cp -r "${BATS_TEST_DIRNAME}/../lib" "${BATS_FILE_TMPDIR}"
  sed '$d' "$SYNC_SH" > "$SYNC_LIB"
}

# Run one or more statements against the sourced library in an isolated
# subshell. Usage: run_lib 'validate_sync_path "/tmp/x" "test"'
#
# LOG_LEVEL is forced to "error" before sourcing: cleanup() runs as an EXIT
# trap even in this throwaway subshell and logs an info-level "stopped
# cleanly" line to stderr, which `run` merges into $output and would
# otherwise corrupt assertions on a function's actual return value.
# log_error output (what die()/validate_sync_path failures print) is
# unaffected, since error is the most verbose level that still passes.
run_lib() {
  run bash -c "source '$SYNC_LIB'; LOG_LEVEL=error; $1"
}

# ---------------------------------------------------------------------------
# Integration-testing support: local/remote fixture directories and a
# sync.conf writer. Every test gets its own pair under BATS_TEST_TMPDIR so
# tests never share state.
# ---------------------------------------------------------------------------
setup_sync_dirs() {
  LOCAL_DIR="${BATS_TEST_TMPDIR}/local"
  REMOTE_DIR="${BATS_TEST_TMPDIR}/remote"
  mkdir -p "$LOCAL_DIR" "$REMOTE_DIR"
}

# Write sync.conf into LOCAL_DIR. Accepts KEY=VALUE overrides on top of a set
# of defaults that are fast and safe for tests (short intervals, no ssh).
# Usage: write_conf REMOTE_DIR="$REMOTE_DIR" MAX_DELETE=5
write_conf() {
  local conf="$LOCAL_DIR/sync.conf"
  {
    echo 'REMOTE=""'
    echo "REMOTE_DIR=\"$REMOTE_DIR\""
    echo 'DELETE_MODE="both"'
    echo 'MAX_DELETE="100"'
    echo 'TRASH_ENABLED="true"'
    echo 'CONFLICT_BACKUP="true"'
    echo 'PULL_COMPARE="checksum"'
    echo 'REQUIRE_SENTINEL="true"'
    echo 'LOG_LEVEL="debug"'
    echo 'MAX_CHANGES_PER_CYCLE="0"'
  } > "$conf"

  # Apply overrides, one KEY=VALUE per argument. Later assignment for the
  # same key wins because sync.conf is sourced top-to-bottom.
  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    printf '%s="%s"\n' "$key" "$val" >> "$conf"
  done
}

# Invoke rsync-live-mirror.sh against LOCAL_DIR and capture status/output via bats' `run`.
# Usage: run_sync --once --force-first-run
run_sync() {
  run "$SYNC_SH" --dir "$LOCAL_DIR" "$@"
}

# Establish a registered sync root: one real cycle with --force-first-run so
# both sentinels exist and the remote snapshot baseline is recorded. Tests
# that only care about steady-state behaviour call this in setup rather than
# repeating the first-run dance themselves.
establish_baseline() {
  run_sync --once --force-first-run
  # shellcheck disable=SC2154
  [ "$status" -eq 0 ]
}

# Byte-for-byte content check, with a clearer failure message than `diff`.
assert_file_content() {
  local path="$1" expected="$2"
  [ -f "$path" ] || {
    echo "expected file to exist: $path" >&2
    return 1
  }
  local actual
  actual="$(cat "$path")"
  if [[ $actual != "$expected" ]]; then
    echo "content mismatch in $path" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    return 1
  fi
}
