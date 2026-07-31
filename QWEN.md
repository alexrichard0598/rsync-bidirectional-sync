# QWEN.md — rsync-monitor

This file provides enduring context for AI assistants working in this repository.
Read it before making changes.

## What this project is

**rsync-monitor** (also called `rsync-bidirectional-sync`) is a bash-based tool
for **continuous bidirectional folder sync over SSH**, driven by filesystem
events (`inotify`) rather than polling on a fixed schedule.

Core technologies: `rsync` + `ssh` + `inotifywait` + `flock`, with **xxh128**
checksums and **lz4** compression for transfers.

### Key behavioral invariants (do not break these)

1. **Remote always wins conflicts.** The pull omits `--update` so any differing
   file is overwritten by the remote copy. The losing local copy is archived to
   `.sync/conflicts/<timestamp>/` — never silently destroyed.
2. **Deletions propagate both ways, confined to the sync tree.** Four
   independent guards prevent deletion from escaping:
   - No `--keep-dirlinks` (symlinks to outside directories are replaced in-tree)
   - Path validation (absolute, no `..`, not a system directory, ≥2 levels deep)
   - `.sync/.sync-root` sentinel required on **both** sides
   - Journal/snapshot entries are re-validated before any deletion
3. **Symlinks are copied as symlinks, never followed.** `--links` is always
   used; `--copy-links`, `--copy-dirlinks`, `--keep-dirlinks` are all omitted.
4. **Cycles are serialized with `flock`.** Overlapping triggers are dropped,
   not queued.

## Architecture

The entry point `mirror-remote-directory.sh` is a **thin script** that sources
modules from `lib/` in strict dependency order, then calls `main "$@"`.

**`lib/globals.sh` MUST be sourced first** — it declares every default and
runtime variable that other modules reference under `set -u`. Beyond that, load
order is not critical because all functions resolve at call time.

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
4. **Push** local → remote — **with `--update`** (never clobbers a newer remote file).
5. **Snapshot** the remote listing — baseline for next cycle's deletion diff.

## Development workflow

### Preferring module edits over the entry point

Always edit the relevant `lib/*.sh` module. Keep `mirror-remote-directory.sh`
thin — it should only source modules and call `main`.

### ShellCheck

```bash
shellcheck --version                        # confirm ≥ 0.11.0
shellcheck mirror-remote-directory.sh lib/*.sh
shellcheck -x mirror-remote-directory.sh    # follows source'd lib files
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

**Before merging any change to `lib/*.sh`, run `bats tests/` to verify nothing
broke.** Add or update `.bats` tests alongside behavioral changes.

### Known test issues

- **Flaky:** Two `start_periodic_watcher` PID-reaping tests in
  `regression_bugfixes.bats` can fail because the background subshell inherits
  `EXIT`/`TERM` traps. May require `kill -9` to reap.
- **Intentionally failing:** The last test in `regression_bugfixes.bats`
  documents a known bug in `count_itemized_changes()` — its regex `[<>ch.*]`
  incorrectly matches attribute-only itemize lines. Left failing (not skipped)
  so it stays visible. Check `tests/README.md` for the full details.

## Configuration

User config lives in `sync.conf` inside the folder being synced. See
`sync.conf.example` for the complete, documented option list. Key settings:

| Key | Purpose |
| --- | --- |
| `REMOTE` | SSH destination (`user@host`) or `""` for local-to-local |
| `REMOTE_DIR` | Absolute path on the remote side |
| `EXCLUDES` | Bash array of rsync glob patterns |
| `DELETE_MODE` | `both` · `pull` · `push` · `none` |
| `PULL_COMPARE` | `checksum` (xxh128) or `quick` (size+mtime) |
| `REMOTE_WATCH` | `poll` or `inotify` |

### First-run gate

`--force-first-run` is required on the first real run. This gate prevents a
misconfigured path from mirroring an empty tree over real data.

### Exit codes

`0` ok · `1` config · `2` dependency · `3` safety gate · `4` connection · `5` rsync

## When updating documentation

Changes to user-facing behavior require coordinated updates:

- **New config key** → update both `README.md` and `sync.conf.example`
- **Module responsibility change** → update `class-diagram.md`
- **CLI flag change** → update `README.md` usage section

## Quick reference commands

```bash
# Validate config + connectivity
./mirror-remote-directory.sh --dir ~/project --check

# Preview changes without applying
./mirror-remote-directory.sh --dir ~/project --once --dry-run

# First real run
./mirror-remote-directory.sh --dir ~/project --force-first-run

# Continuous watch
./mirror-remote-directory.sh --dir ~/project

# Run tests
bats tests/

# Lint
shellcheck -x mirror-remote-directory.sh
```
