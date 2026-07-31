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
- `regression_bugfixes.bats` -- pinned regressions for the three bugs
  fixed in `0001-fix-mirror-remote-directory.sh-bugs.patch` (SSH transport IFS/space-join,
  the periodic-watcher PID leak, and `MAX_CHANGES_PER_CYCLE` ignoring
  `$DIRECTION`), plus one **currently-failing, unpatched** test — see
  below.

## Status as of last run

Everything through `sync_cycle.bats` (66 tests across the first three
files) was green. `regression_bugfixes.bats` surfaced a real bash gotcha
partway through and was mid-fix when this was handed off:

- The two `start_periodic_watcher` PID-registration tests spawn a
  background subshell and then need to reap it. That subshell inherits
  `mirror-remote-directory.sh`'s own `EXIT`/`TERM` traps, and bash defers a caught,
  trap-handled signal until the subshell's current foreground command
  (`sleep`) returns -- so a plain `kill` sits unhandled for the full
  `PERIODIC_FULL_SYNC` duration instead of terminating it. Both tests
  were changed to reap with `kill -9` (SIGKILL can't be caught or
  deferred), which fixed it in isolated manual reproduction. **This
  wasn't re-verified against the actual `.bats` file before handoff --
  run `bats tests/regression_bugfixes.bats` first and re-check those two
  tests specifically.**
- The last test in that file, `[known bug, unpatched] attribute-only
  itemize lines are not counted as changes`, is **expected to fail**.
  It documents a fourth, separate bug found while writing this suite:
  `count_itemized_changes()`'s regex character class `[<>ch.*]`
  contains a literal `.`, so lines rsync itemizes as attribute-only
  (leading `.`, e.g. `.d..t...... somedir/`) get counted as real
  changes -- contradicting the function's own comment and inflating
  both the "N change(s)" log summaries and the `MAX_CHANGES_PER_CYCLE`
  gate. Left failing (not skipped) so it stays visible until fixed;
  the fix is likely narrowing the first character class to `[<>ch]`.
