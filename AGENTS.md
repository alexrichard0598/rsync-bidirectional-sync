# AGENTS.md

Instructions for AI coding agents working in this repository.

## Project overview

`rsync-live-mirror` is a bash-based tool for continuous **bidirectional**
folder sync over SSH, driven by filesystem events (`inotify`) rather than
polling on a fixed schedule.

Key behaviors, for context before making changes:

- Transfers via `rsync` over `ssh`, using xxh128 checksums and lz4 compression.
- **Remote always wins conflicts**; the losing local copy is archived to
  `.sync/conflicts/<timestamp>/`, never silently destroyed.
- Symlinks are copied as symlinks, never followed/dereferenced.
- Deletions propagate both ways and cannot escape the synced tree (see the
  four guards described in `README.md` under "Why deletion cannot escape the
  tree").
- Configuration lives in a `sync.conf` file inside the folder being synced
  (see `sync.conf.example` for the full, documented option list).

The entry point is `rsync-live-mirror.sh`, which is a thin script that
sources the modules in `lib/*.sh` (in dependency order) and calls `main`.
`lib/globals.sh` must be sourced first — it declares every default/runtime
variable the other modules reference under `set -u`.

### Module map (`lib/*.sh`)

| File | Responsibility |
| --- | --- |
| `globals.sh` | Shared constants, config defaults, runtime state |
| `logging.sh` | Logging levels (`error`/`warn`/`info`/`debug`/`ok`), `die()`, log rotation |
| `config.sh` | CLI arg parsing, locating and loading `sync.conf` |
| `validation.sh` | Validates resolved config, sync paths, and tool/version deps |
| `state.sh` | `.sync/` state dir and sentinel files (first-run / sync-root detection) |
| `connection.sh` | SSH option/transport building, multiplexed control sockets, reachability checks |
| `rsync_options.sh` | Builds rsync argument sets (common/filter/pull/push) from config |
| `snapshot.sh` | Remote snapshot tracking used to detect and journal deletions, trash retention |
| `sync.sh` | Core sync engine: pull/push cycles, change estimation, deletion propagation |
| `watcher.sh` | Local `inotifywait`, remote `inotifywait`/polling, periodic full-sync fallback |
| `controller.sh` | Top-level orchestration: run modes (`watch`/`once`/`check`), signal handling, summary |

For a fuller architectural map (treated as an OOP-style class diagram, since
the module split maps closely onto one), see `class-diagram.md`.

## How a sync cycle works (order is load-bearing)

1. Local deletions → remote (from the inotify journal) — must happen before
   the pull, or the pull would re-download a file just deleted locally.
2. Remote deletions → local (from a snapshot diff) — must happen before the
   push, or the push would re-upload it.
3. **Pull** remote → local, without `--update` (remote always overwrites).
4. **Push** local → remote, with `--update` (never clobbers a newer remote file).
5. Snapshot the remote listing, as the baseline for next cycle's deletion diff.

Cycles are serialized with `flock`; an overlapping trigger is dropped, not
queued.

## Running the tool

```bash
# validate config + connectivity only
./rsync-live-mirror.sh --dir ~/myproject --check

# preview changes without applying them
./rsync-live-mirror.sh --dir ~/myproject --once --dry-run

# first real run (required gate — protects against mirroring an empty tree over real data)
./rsync-live-mirror.sh --dir ~/myproject --force-first-run

# then, ongoing:
./rsync-live-mirror.sh --dir ~/myproject   # watch continuously
```

Useful flags: `--once` (single cycle then exit), `--pull-only` /
`--push-only`, `-v/--verbose`, `-q/--quiet`. Full flag list and exit codes
(`0` ok, `1` config, `2` dependency, `3` safety gate, `4` connection, `5`
rsync) are documented in `README.md`.

For local testing/dev without SSH, set `REMOTE=""` in `sync.conf` to run in
**local-to-local mode** (two plain local paths, no network dependency). The
test suite relies on exactly this mode.

## Testing

Tests use **bats-core** (developed against 1.10.0) and live in `tests/`.

```bash
sudo apt-get install -y bats      # bats-core, from Ubuntu/Debian repos
bats --version                    # confirm 1.10.0+
bats tests/
```

All tests run in local-to-local mode (`REMOTE=""`) against two plain
directories standing in for "local" and "remote" — no SSH/network needed, no
external fixtures required.

Useful `bats` invocations while iterating:

```bash
bats tests/sync_cycle.bats                        # a single file
bats -f 'remote wins' tests/                       # only tests matching a name/regex
bats --print-output-on-failure tests/              # show $output on failures
bats -T tests/                                     # with per-test timing
```

Test files:

- `test_helper.bash` — shared setup (fixture dirs, a `sync.conf` writer) and
  the machinery for unit-testing individual functions. It sources a copy of
  `rsync-live-mirror.sh` with the trailing `main "$@"` stripped, inside
  an isolated `bash -c` subshell per call, so the script's `set -Eeuo
  pipefail`, global `IFS`, and EXIT/TERM traps never leak into the test
  runner.
- `unit_functions.bats` — pure/self-contained functions (`version_ge`,
  `validate_sync_path`, `count_itemized_changes`, `shell_quote`,
  `build_inotify_exclude_regex`).
- `cli_and_config.bats` — argument parsing and `validate_config()`: required
  keys, enum/boolean/numeric checks, path-safety checks, `sync.conf`
  permission/syntax handling, `--check`.
- `sync_cycle.bats` — full sync cycles: first-run gate, push/pull,
  `--pull-only`/`--push-only`, remote-wins conflict resolution and conflict
  backups, both deletion mechanisms, `MAX_DELETE`, `DELETE_MODE=none`,
  symlink handling.
- `regression_bugfixes.bats` — pinned regressions for historically
  problematic areas. The suite is now fully green; see `tests/README.md`
  for the fix history.

Before relying on test results, check `tests/README.md` for the current
status — it records the state of the suite as of the last run.

See `issues-discovered-by-qwen.md` for a catalog of known design limitations
that are not yet fixed (e.g. edit-vs-delete conflicts, rename fan-out,
systemd restart loops).

When changing behavior in `lib/*.sh`, run the full suite (`bats tests/`)
before considering the change done, and update or add `.bats` tests
alongside the change rather than only manually verifying.

## Working conventions

- Shell style is checked with **shellcheck** (developed against 0.11.0; repo
  defaults live in `.shellcheckrc`, so a plain invocation picks them up
  automatically). Keep changes shellcheck-clean:

  ```bash
  shellcheck --version                        # confirm version
  shellcheck rsync-live-mirror.sh lib/*.sh
  shellcheck -x rsync-live-mirror.sh     # follow `source`d lib/*.sh files too
  shellcheck -S warning lib/sync.sh            # ignore style-only nits, focus on warning+
  shellcheck -f gcc lib/*.sh                   # gcc-style output, easier to grep/parse
  ```

  Run it against every `.sh` file you touch (`rsync-live-mirror.sh` and
  anything under `lib/` or `tests/`) before considering a change done, not
  just the one you edited — `-x` only follows `source`, it doesn't check
  files you didn't pass in.
- Prefer editing the relevant `lib/*.sh` module directly over adding logic to
  `rsync-live-mirror.sh`, which is meant to stay a thin entry point.
- If a change affects the module responsibilities or dependencies described
  above, update `class-diagram.md` to match.
- If a change affects user-facing behavior, flags, or config keys, update
  `README.md` (and `sync.conf.example` for config keys) in the same change.
