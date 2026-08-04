# QWEN.md — rsync-live-mirror

Bash tool for **continuous bidirectional folder sync over SSH** via `rsync` + `inotifywait` + `flock`. Checksums: xxh128. Compression: lz4. Only load parts of the project at one time, the total size of the project is significantly larger than your context window.

## Invariants (do not break)

1. **Remote wins conflicts.** Pull omits `--update`; losing local → `.sync/conflicts/<ts>/`.
2. **Deletion confined to sync tree.** Guards: no `--keep-dirlinks`, path validation (absolute, no `..`, not system dir, ≥2 levels), `.sync/.sync-root` sentinel both sides, journal/snapshot re-validation.
3. **Symlinks as symlinks.** `--links` always; never `--copy-links/--copy-dirlinks/--keep-dirlinks`.
4. **Cycles serialized with `flock`.** Dropped, not queued.

## Architecture

`rsync-live-mirror.sh` is thin: sources `lib/*.sh` in dependency order, calls `main`.
**`lib/globals.sh` MUST be first** (declares defaults under `set -u`).

### Modules
- `globals.sh` — constants/defaults
- `logging.sh` — levels + `die()` + rotation
- `config.sh` — CLI + `sync.conf`
- `validation.sh` — config/path/tool validation
- `state.sh` — `.sync/` + sentinels
- `connection.sh` — SSH/transport
- `rsync_options.sh` — rsync arg sets
- `snapshot.sh` — deletion detection + trash
- `sync.sh` — pull/push engine + deletion propagation
- `watcher.sh` — inotify + periodic sync
- `controller.sh` — run modes + signals

Full diagram: `class-diagram.md`.

### Sync cycle (order is load-bearing)

1. **Local deletions → remote** (inotify journal) — before pull
2. **Remote deletions → local** (snapshot diff) — before push
3. **Pull** remote→local — **no `--update`** (remote overwrites)
4. **Push** local→remote — **with `--update`** (never clobbers newer remote)
5. **Snapshot** remote listing

## Dev workflow

- **Edit `lib/*.sh` modules, not the entry point.**
- **ShellCheck** before every change: `shellcheck -x rsync-live-mirror.sh` (≥ 0.11.0, `.shellcheckrc` in repo). Keep clean.
- **Tests:** `bats tests/` (bats-core ≥ 1.10.0, local-to-local, no SSH). Run before merging.

### Test files
- `test_helper.bash` — isolated function testing (isolates `set -Eeuo pipefail` + traps)
- `unit_functions.bats` — pure functions
- `cli_and_config.bats` — arg parsing, `validate_config()`
- `sync_cycle.bats` — full cycles, conflicts, deletion, symlinks
- `regression_bugfixes.bats` — pinned regressions. Status: `tests/README.md`.

### Known test issues
- `regression_bugfixes.bats`: two PID-reaping tests flaky (trap inheritance). Last test intentionally failing (`count_itemized_changes` regex bug). See `tests/README.md`.

### Known limitations
See `issues-discovered-by-qwen.md`.

## Configuration (`sync.conf` in synced folder; full: `sync.conf.example`)

| Key | Values |
|---|---|
| `REMOTE` | `user@host` or `""` (local-to-local) |
| `REMOTE_DIR` | absolute remote path |
| `EXCLUDES` | bash array of rsync globs |
| `DELETE_MODE` | `both` / `pull` / `push` / `none` |
| `MAX_DELETE` | cap per run (`-1` = unlimited) |
| `PULL_COMPARE` | `checksum` (xxh128) / `quick` |
| `REMOTE_WATCH` | `poll` / `inotify` |
| `REQUIRE_SENTINEL` | require `.sync/.sync-root` both sides |

First run: `--force-first-run`. Exit codes: `0` ok, `1` config, `2` dep, `3` safety, `4` connection, `5` rsync.

## Commands

```bash
bats tests/                       # test
shellcheck -x rsync-live-mirror.sh  # lint
```

## Docs policy

New config key → `README.md` + `sync.conf.example`. Module change → `class-diagram.md`. CLI flag → `README.md` usage.

## `.sync/` layout

Local only, never transferred: `sync.log`, `sync.lock`, `.sync-root`, `pending-deletes`, `remote-snapshot`, `trash/<ts>/`, `conflicts/<ts>/`, `partial/`, `events.fifo`, `inotify.raw`, `inotify.pid`, `ssh-*`. Pruned after `TRASH_KEEP_DAYS`.

`remote-snapshot` format: one `path<TAB>size<TAB>xxh128` record per remote file, not a bare path list. Deletion-diffing compares the path field only, never the whole record — see `lib/snapshot.sh`.

## Service note

`systemd` template in README. Safety-gate exit `3` → `Restart=on-failure` loops; use `RestartPreventExitStatus=3`.
