# mirror-remote-directory.sh test suite (bats-core)

To test the application run run:

```sh
sudo apt-get install -y bats      # bats-core, from Ubuntu/Debian repos
bats tests/
```

Everything runs in **local-to-local mode** (`REMOTE=""`), so there's no ssh
or network dependency -- just two plain directories standing in for "local"
and "remote". No fixtures beyond that are needed.

## Files

- `test_helper.bash` -- shared setup: fixture dirs, a `sync.conf` writer,
  and the machinery for unit-testing individual functions (sources a
  copy of `mirror-remote-directory.sh` with its trailing `main "$@"` stripped, inside an
  isolated `bash -c` subshell per call, so the script's `set -Eeuo
  pipefail`, global `IFS`, and EXIT/TERM traps never leak into the test
  runner).
- `unit_functions.bats` -- pure/self-contained functions: `version_ge`,
  `validate_sync_path`, `count_itemized_changes`, `shell_quote`,
  `build_inotify_exclude_regex`.
- `cli_and_config.bats` -- argument parsing and `validate_config()`:
  required keys, enum/boolean/numeric checks, path-safety checks,
  `sync.conf` permission and syntax handling, `--check`.
- `sync_cycle.bats` -- full sync cycles: the first-run gate, basic
  push/pull, `--pull-only`/`--push-only`, remote-wins conflict resolution
  and conflict backups, both deletion mechanisms (journal-driven push,
  snapshot-diff-driven pull), `MAX_DELETE`, `DELETE_MODE=none`, and
  symlink handling.
- `regression_bugfixes.bats` -- pinned regressions for four bugs:
  SSH transport IFS/space-join, the periodic-watcher PID leak,
  `MAX_CHANGES_PER_CYCLE` ignoring `$DIRECTION`, and attribute-only
  itemize lines being counted as changes. All four are now fixed;
  the test suite should be fully green.

## Status as of last run

All 74 tests are green. Fixes applied:

- **SSH transport test 24**: `read -ra words <<<"$t"` split on global
  `IFS=$'\n\t'` instead of spaces, collapsing the transport string.
  Fixed by using `printf "%s\n" "$t" | wc -w` to count words correctly.
- **`count_itemized_changes` regex**: `[<>ch.*]` included a literal `.`
  so attribute-only lines (`.d..t......`) were counted as changes.
  Fixed by narrowing to `[<>ch]`.
- **Periodic-watcher PID leak and hang**: background subshell inherited
  `trap cleanup EXIT` from the parent script; on `kill -9`, bash waits
  for the process to actually terminate, but `cleanup()` fires first and
  blocks on FIFO writes. Fixed by adding `trap - EXIT` inside every
  watcher subshell so `cleanup()` never fires. Watchers now write via
  the inherited fd (`1>&"$EVENT_FIFO_FD"`) instead of reopening the
  FIFO path (`> "$EVENT_FIFO"`), avoiding a blocking `open()` that
  `kill -9` can't interrupt. The periodic watcher uses `read -t`
  (interruptible) instead of `sleep` (which blocks on `kill -9`).
