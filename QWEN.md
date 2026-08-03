# QWEN.md — rsync-live-mirror

Read this file before making changes. It captures the project's architecture,
behavioral invariants, development workflow, and known issues so that AI
assistants and new contributors can work safely and idiomatically.

## What this project is

**rsync-live-mirror** (displayed as *rsync-live-mirror*) is a bash-based
tool for **continuous bidirectional folder sync over SSH**, driven by
filesystem events (`inotify`) rather than polling on a fixed schedule.

Core technologies: `rsync` + `ssh` + `inotifywait` + `flock`, with
**xxh128** checksums and **lz4** compression for transfers.

### Key behavioral invariants (do not break these)

1. **Remote always wins conflicts.** The pull omits `--update` so any
   differing file is overwritten by the remote copy. The losing local copy
   is archived to `.sync/conflicts/<timestamp>/` — never silently destroyed.
2. **Deletions propagate both ways, confined to the sync tree.** Four
   independent guards prevent deletion from escaping:
   - No `--keep-dirlinks` (symlinks to outside directories are replaced
     in-tree)
   - Path validation (absolute, no `..`, not a system directory, ≥2 levels
     deep)
   - `.sync/.sync-root` sentinel required on **both** sides
   - Journal/snapshot entries are re-validated before any deletion
3. **Symlinks are copied as symlinks, never followed.** `--links` is always
   used; `--copy-links`, `--copy-dirlinks`, `--keep-dirlinks` are all omitted.
4. **Cycles are serialized with `flock`.** Overlapping triggers are dropped,
   not queued.

## Architecture

The entry point `rsync-live-mirror.sh` is a **thin script** that
sources modules from `lib/` in strict dependency order, then calls `main "$@"`.

**`lib/globals.sh` MUST be sourced first** — it declares every default and
runtime variable that other modules reference under `set -u`. Beyond that,
load order is not critical because all functions resolve at call time.

### Module map (`lib/*.sh`)

| File | Responsibility |
| --- | --- |
| `globals.sh` | Shared constants, config defaults, runtime state |
| `logging.sh` | Logging levels (`error`/`warn`/`info`/`debug`/`ok`), `die()`, log rotation |
| `config.sh` | CLI arg parsing, locating and loading `sync.conf` |
| `validation.sh` | Validates resolved config, sync paths, tool/version deps |
| `state.sh` | `.sync/` state directory and sentinel files |
| `connection.sh` | SSH options/transport, multiplexed control sockets |
| `rsync_options.sh` | Builds rsync argument sets (common/filter/pull/push) |
| `snapshot.sh` | Remote snapshot tracking for deletion detection, trash retention |
| `sync.sh` | Core sync engine: pull/push cycles, change estimation, deletion propagation |
| `watcher.sh` | Local `inotifywait`, remote `inotifywait`/polling, periodic full-sync |
| `controller.sh` | Top-level orchestration: run modes, signal handling, summary |

See `class-diagram.md` for a Mermaid UML class diagram with relationships.

### How a sync cycle works (order is load-bearing)

1. **Local deletions → remote** (from inotify journal) — must happen *before*
   the pull, or the pull would re-download a file just deleted locally.
2. **Remote deletions → local** (from snapshot diff) — must happen *before*
   the push, or the push would re-upload a deleted file.
3. **Pull** remote → local — **no `--update`** (remote always overwrites).
4. **Push** local → remote — **with `--update`** (never clobbers a newer
   remote file).
5. **Snapshot** the remote listing — baseline for next cycle's deletion diff.

## Development workflow

### Preferring module edits over the entry point

Always edit the relevant `lib/*.sh` module. Keep
`rsync-live-mirror.sh` thin — it should only source modules and call
`main`.

### ShellCheck

```bash
shellcheck --version                        # confirm ≥ 0.11.0
shellcheck rsync-live-mirror.sh lib/*.sh
shellcheck -x rsync-live-mirror.sh    # follows source'd lib files
```

Run ShellCheck against **every** `.sh` file you touch (including `tests/`).
The repo has `.shellcheckrc` with project defaults. Keep all changes
ShellCheck-clean.

### Testing

Tests use **bats-core** (≥ 1.10.0) under `tests/`. All tests run in
**local-to-local mode** (`REMOTE=""`) — no SSH/network needed.

```bash
bats tests/                                  # full suite
bats tests/sync_cycle.bats                   # single file
bats -f 'remote wins' tests/                 # filter by name
bats --print-output-on-failure tests/        # verbose on failure
```

**Before merging any change to `lib/*.sh`, run `bats tests/` to verify
nothing broke.** Add or update `.bats` tests alongside behavioral changes.

### Test files

- `test_helper.bash` — shared setup (fixture dirs, a `sync.conf` writer) and
  the machinery for unit-testing individual functions. Sources a copy of the
  main script with its trailing `main "$@"` stripped, inside an isolated
  `bash -c` subshell per call, so the script's `set -Eeuo pipefail`, global
  `IFS`, and EXIT/TERM traps never leak into the test runner.
- `unit_functions.bats` — pure/self-contained functions (`version_ge`,
  `validate_sync_path`, `count_itemized_changes`, `shell_quote`,
  `build_inotify_exclude_regex`).
- `cli_and_config.bats` — argument parsing and `validate_config()`: required
  keys, enum/boolean/numeric checks, path-safety checks, `sync.conf`
  permission/syntax handling, `--check`.
- `sync_cycle.bats` — full sync cycles: first-run gate, basic push/pull,
  `--pull-only`/`--push-only`, remote-wins conflict resolution and conflict
  backups, both deletion mechanisms (journal-driven push, snapshot-diff-driven
  pull), `MAX_DELETE`, `DELETE_MODE=none`, symlink handling.
- `regression_bugfixes.bats` — pinned regressions. See `tests/README.md` for
  current status.

### Known test issues

- **Flaky:** Two `start_periodic_watcher` PID-reaping tests in
  `regression_bugfixes.bats` can fail because the background subshell inherits
  `EXIT`/`TERM` traps. May require `kill -9` to reap.
- **Intentionally failing:** The last test in `regression_bugfixes.bats`
  documents a known bug in `count_itemized_changes()` — its regex `[<>ch.*]`
  incorrectly matches attribute-only itemize lines. Left failing (not skipped)
  so it stays visible. Check `tests/README.md` for the full details.

### Known design limitations

See `issues-discovered-by-qwen.md` for a catalog of known issues and their
severity:

| Issue | Severity |
| --- | --- |
| Edit-vs-delete conflicts archived to trash only, not `.sync/conflicts/` | Medium |
| Renames/directory moves fan out into delete+create pairs | Medium |
| Safety gates + `Restart=on-failure` trigger systemd restart loops | Medium |
| Stale `EXCLUDES` silently freeze files | Low |
| Hardlink groups crossing an exclude boundary | Low |
| No distributed locking across multiple peers | Low (out of scope) |

## Configuration

User config lives in `sync.conf` inside the folder being synced. See
`sync.conf.example` for the complete, documented option list. Key settings:

| Key | Purpose |
| --- | --- |
| `REMOTE` | SSH destination (`user@host`) or `""` for local-to-local |
| `REMOTE_DIR` | Absolute path on the remote side |
| `EXCLUDES` | Bash array of rsync glob patterns |
| `REMOTE_CHMOD` / `REMOTE_CHOWN` | Permissions/ownership applied on push |
| `DELETE_MODE` | `both` · `pull` · `push` · `none` |
| `MAX_DELETE` | Deletion cap per run (`-1` = unlimited) |
| `PULL_COMPARE` | `checksum` (xxh128) or `quick` (size+mtime) |
| `REMOTE_WATCH` | `poll` or `inotify` |
| `REQUIRE_SENTINEL` | Refuse to run unless both sides are marked |

### First-run gate

`--force-first-run` is required on the first real run. That gate prevents a
misconfigured path from mirroring an empty tree over real data.

### Exit codes

`0` ok · `1` config · `2` dependency · `3` safety gate · `4` connection ·
`5` rsync

## Quick reference commands

```bash
# Validate config + connectivity
./rsync-live-mirror.sh --dir ~/myproject --check

# Preview changes without applying
./rsync-live-mirror.sh --dir ~/myproject --once --dry-run

# First real run
./rsync-live-mirror.sh --dir ~/myproject --force-first-run

# Continuous watch
./rsync-live-mirror.sh --dir ~/myproject

# Run tests
bats tests/

# Lint
shellcheck -x rsync-live-mirror.sh
```

## When updating documentation

Changes to user-facing behavior require coordinated updates:

- **New config key** → update both `README.md` and `sync.conf.example`
- **Module responsibility change** → update `class-diagram.md`
- **CLI flag change** → update `README.md` usage section

## .sync/ layout

Inside the local root, never transferred, protected from deletion:

```
.sync/
├── sync.log            activity log (rotated at LOG_MAX_KB)
├── sync.lock           flock target serialising cycles
├── .sync-root          sentinel proving this is a real sync root
├── pending-deletes     journal of observed local deletions
├── remote-snapshot     remote listing from the last cycle
├── trash/<ts>/         deleted files (TRASH_ENABLED)
├── conflicts/<ts>/     local files that lost a conflict
├── partial/            partial transfers, for resume
├── events.fifo         event channel between watchers and watch_loop
├── inotify.raw         FIFO for raw local inotify events
├── inotify.pid          pid file for the local inotifywait process
└── ssh-*               ssh ControlMaster sockets
```

`trash/` and `conflicts/` are pruned after `TRASH_KEEP_DAYS`.

## Service deployment

The README includes a systemd user service template. Be aware that safety-gate
exit code (`3`) will trigger `Restart=on-failure` restart loops. The example
should use `RestartPreventExitStatus=3` to avoid this (see
`issues-discovered-by-qwen.md`, issue #9).
