# rsync-live-mirror — Program Design Language

> A structured design specification for the bidirectional rsync+inotify folder
> sync tool. Read this before changing sync semantics, deletion propagation, or
> the watcher lifecycle.

---

## 1. System Overview

### 1.1 Purpose

`rsync-live-mirror` keeps a local directory tree and a remote directory tree in
continuous, bidirectional sync over SSH by reacting to filesystem events
(`inotify`) rather than polling on a fixed schedule.

### 1.2 Design Principles

| Principle | Enforcement |
|---|---|
| **Remote wins conflicts** | Pull omits `--update` (remote overwrites). Push uses `--update` (never clobbers newer remote). Losing local copy → `.sync/conflicts/<ts>/`. |
| **Deletion confined to sync tree** | Four guards: no `--keep-dirlinks`, path validation (absolute, no `..`, not system dir, ≥2 levels), `.sync/.sync-root` sentinels both sides, journal/snapshot re-validation. |
| **Symlinks as symlinks** | `--links` always; never `--copy-links`/`--copy-dirlinks`/`--keep-dirlinks`. |
| **Cycles serialized** | `flock` on `.sync/sync.lock`; overlapping triggers dropped, not queued. |
| **Bash purity** | No external JS/Python wrappers. ShellCheck-clean (`shellcheck -x`), `set -Eeuo pipefail`. |

### 1.3 Technology Stack

| Layer | Tool | Version Constraint |
|---|---|---|
| Shell | `bash` | ≥ 4.0 |
| Transfer | `rsync` | ≥ 3.1.3 (xxh128 + lz4) |
| Remote access | `ssh` | any |
| Event detection | `inotify-tools` (`inotifywait`) | any |
| Serialization | `flock` (util-linux) | any |
| Checksum | xxh128 (rsync builtin) | — |
| Compression | lz4 (rsync builtin) | — |

---

## 2. Architecture

### 2.1 Module Decomposition

The entry point `rsync-live-mirror.sh` is a thin script that sources `lib/*.sh`
in strict dependency order and calls `main`. Sourcing order:

```
lib/globals.sh        →  Globals (constants, defaults, runtime state)
lib/logging.sh        →  Logging, LogRotation
lib/config.sh         →  Configuration
lib/validation.sh     →  Validation
lib/state.sh          →  State
lib/connection.sh     →  Connection
lib/rsync_options.sh  →  RsyncOptions
lib/snapshot.sh       →  Snapshot
lib/sync.sh           →  Sync (core engine)
lib/watcher.sh        →  Watcher
lib/controller.sh     →  Controller (entry point, signal handling)
```

`lib/globals.sh` MUST be first — it declares every default/runtime variable
that later modules reference under `set -u`. Beyond that, load order is not
load-bearing: every function is resolved at call time.

### 2.2 Module Responsibilities

See `class-diagram.md` for the full UML-style class diagram with relationships.
Key module summary:

| Module | Owns | Calls |
|---|---|---|
| `Controller` | Run mode dispatch (`watch`/`once`/`check`), signal handling, shutdown | Configuration, Validation, Sync, Watcher |
| `Configuration` | CLI args, `sync.conf` loading and resolution | — |
| `Validation` | Config, path, and tool-version validation | — |
| `Logging` | Severity levels, `die()`, log rotation | — |
| `State` | `.sync/` directory, sentinel files, first-run detection | Connection |
| `Snapshot` | Remote-file tracking, deletion detection, trash retention | Connection |
| `Connection` | SSH options, multiplexed control sockets, reachability | — |
| `RsyncOptions` | Builds rsync arg sets (common, filter, pull, push) | Configuration (reads) |
| `Sync` | Pull/push engine, change estimation, deletion propagation | Connection, RsyncOptions, Snapshot, State |
| `Watcher` | Local/remote inotify, periodic full-sync fallback | — |

### 2.3 State Directory Layout (`.sync/`)

Local-only, never transferred:

```
.sync/
├── sync.log            # Activity log
├── sync.lock           # flock target
├── .sync-root          # Sentinel: "this is a real sync root"
├── pending-deletes     # Journal of observed local deletions
├── trash/<ts>/         # Deleted files (when TRASH_ENABLED=true)
├── conflicts/<ts>/     # Local files that lost a conflict
├── partial/            # Partial transfers for resume
├── ssh-%C              # SSH ControlMaster sockets
├── remote-snapshot     # Current remote listing baseline
├── events.fifo         # inotify event FIFO
├── inotify.raw         # Raw inotify output buffer
├── inotify.pid         # inotify watcher PID
└── ssh-*               # SSH multiplexing state
```

---

## 3. Sync Cycle Algorithm

The order of operations is load-bearing. A cycle runs:

```
┌─────────────────────────────────────────────────────────────────┐
│                    Acquire flock(.sync/sync.lock)               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Step 1:  Local deletions → remote                             │
│            ─────────────────                                   │
│            Read .sync/pending-deletes (inotify journal).       │
│            For each recorded local deletion, remove the path    │
│            from the remote. Must happen BEFORE the pull, or the │
│            pull would re-download a file just deleted locally.  │
│                                                                 │
│  Step 2:  Remote deletions → local                             │
│            ────────────────────                                 │
│            Diff current remote listing against the last          │
│            snapshot (.sync/remote-snapshot). Anything gone      │
│            from the remote is removed locally. Must happen      │
│            BEFORE the push, or the push would re-upload it.     │
│                                                                 │
│  Step 3:  PULL remote → local (no --update)                   │
│            ──────────────────────────────                       │
│            Remote overwrites local differences. This is the     │
│            "remote wins" step. The losing local copy is         │
│            archived to .sync/conflicts/<ts>/ when               │
│            CONFLICT_BACKUP=true.                                │
│                                                                 │
│  Step 4:  PUSH local → remote (with --update)                 │
│            ─────────────────────────────────                   │
│            --update means "never overwrite a newer remote       │
│            file." This complements Step 3: the pull is the      │
│            authoritative direction, the push respects remote    │
│            recency.                                             │
│                                                                 │
│  Step 5:  Snapshot remote listing                              │
│            ──────────────────────                               │
│            Save current remote ls as .sync/remote-snapshot.     │
│            Baseline for next cycle's deletion diff.              │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                    Release flock                                │
└─────────────────────────────────────────────────────────────────┘
```

### 3.1 Bidirectional Deletion Mechanics

The core problem: rsync cannot distinguish "new on this side" from
"deleted on the other side" — both look like "present here, absent
there." A naive `--delete` in both directions destroys newly created
files.

**Solution:**

| Direction | Mechanism |
|---|---|
| **Pull (remote→local)** | NO blanket `--delete`. A blanket `--delete` on pull would remove every file that exists only on the local side — including files the user just CREATED locally and that have not been pushed yet. Remote deletions are detected by comparing the remote file list against a snapshot of the previous cycle (see `apply_remote_deletions` in `sync.sh`), and only genuinely-vanished paths are removed locally. |
| **Push (local→remote)** | NO blanket `--delete`. The inotify watcher journals every `DELETE`/`MOVED_FROM` into `.sync/pending-deletes`. The push removes ONLY those recorded paths. New local files are never mistaken for remote deletions. |

**Journal lifecycle:**

```
inotifywait event (DELETE/MOVED_FROM)
  →  appended to .sync/pending-deletes
  →  next push cycle: read journal, delete those paths remotely
  →  journal entry consumed (not re-queued)
```

### 3.2 Conflict Detection and Resolution

A "conflict" is the same path changed on both sides between two sync
cycles.

**Detection:**

| Direction | How |
|---|---|
| Pull | `PULL_COMPARE` config: `checksum` (xxh128 content hash, default) or `quick` (rsync's size+mtime default). |
| Push | `--update` flag — rsync skips files whose mtime hasn't changed on the destination. |

**Resolution:** Remote wins. The pull omits `--update` so the remote
copy always overwrites. The losing local copy is moved (not deleted) to
`.sync/conflicts/<timestamp>/` when `CONFLICT_BACKUP=true`.

---

## 4. Configuration Model

### 4.1 Resolution Order

The sync root is located in this priority:

1. `--dir PATH` CLI flag
2. `$RSYNC_SYNC_DIR` environment variable
3. Nearest ancestor of `$PWD` containing a `sync.conf`

### 4.2 Key Configuration Axes

See `sync.conf.example` for the full documented config. Key axes:

| Axis | Options | Default |
|---|---|---|
| **Connection** | `REMOTE`, `REMOTE_DIR`, `REMOTE_PORT`, `SSH_KEY`, `SSH_EXTRA_OPTS` | — |
| **Filtering** | `EXCLUDES` (bash array of rsync globs) | `()` |
| **Deletion** | `DELETE_MODE` ∈ {`both`, `pull`, `push`, `none`}, `MAX_DELETE`, `DELETE_PUSH_UNSAFE` | `both`, `100`, `false` |
| **Conflict** | `CONFLICT_BACKUP`, `PULL_COMPARE` | `true`, `checksum` |
| **Symlinks** | `SAFE_LINKS`, `PRESERVE_HARDLINKS` | `false`, `true` |
| **Detection** | `REMOTE_WATCH` ∈ {`poll`, `inotify`}, `DEBOUNCE_SECONDS`, `PERIODIC_FULL_SYNC` | `poll`, `2s`, `300s` |
| **Safety** | `REQUIRE_SENTINEL`, `MAX_CHANGES_PER_CYCLE` | `true`, `0` |
| **Performance** | `BWLIMIT`, `SSH_MULTIPLEXING`, `PARTIAL_TRANSFERS`, `RSYNC_TIMEOUT` | `""`, `true`, `true`, `300` |
| **Logging** | `LOG_LEVEL` ∈ {`error`, `warn`, `info`, `debug`}, `LOG_MAX_KB`, `DRY_RUN` | `info`, `5120`, `false` |

### 4.3 First-Run Gate

On first invocation the script requires `--force-first-run` before it
writes any sentinel. This prevents the classic disaster: an unmounted
drive or typo'd path presents an empty directory, and `--delete`
faithfully mirrors that emptiness onto the other side.

### 4.4 Safety Gates

| Gate | Trigger | Exit Code |
|---|---|---|
| Config error | Missing required keys, invalid enum values | 1 |
| Dependency missing | rsync version too old, inotifywait absent | 2 |
| Safety gate tripped | `MAX_CHANGES_PER_CYCLE`, `MAX_DELETE`, sentinel missing | 3 |
| Connection failure | SSH unreachable, auth failure | 4 |
| Rsync failure | Transfer error, permission denied | 5 |

Note: exit code 3 (safety) is distinct from errors (1, 2, 4, 5). When
deploying as a systemd service, use `RestartPreventExitStatus=3` to
avoid restart loops on legitimate safety refusals.

---

## 5. Watcher Lifecycle

### 5.1 Local Watcher

```
start_local_watcher()
  └─ inotifywait -m -r --exclude <EXCLUDES> "$LOCAL_DIR"
     └─ Events → .sync/events.fifo (debounced by DEBOUNCE_SECONDS)
        └─ On event: trigger sync_cycle()
```

### 5.2 Remote Watcher (Two Modes)

**Poll mode** (default, no remote dependency):

```
Remote inotifywait every REMOTE_POLL_INTERVAL seconds
  →  Treats any interval as "something may have changed"
  →  Latency bounded by the interval
```

**inotify mode** (requires inotify-tools on remote):

```
Remote inotifywait streamed over SSH
  →  Near-instant event delivery
  →  Falls back to poll if inotifywait is missing
```

### 5.3 Periodic Fallback

Regardless of watchers, a full sync fires every `PERIODIC_FULL_SYNC`
seconds (default 300) to catch anything inotify missed (queue overflow,
remote edits when using poll on a busy tree).

### 5.4 PID Management

Watcher subshells inherit the parent's `trap cleanup EXIT`. On `kill -9`:
- bash waits for the process to terminate
- `cleanup()` fires first and blocks on FIFO writes

**Fix:** watcher subshells run `trap - EXIT` so `cleanup()` never fires.
Writers use the inherited fd (`>&"$EVENT_FIFO_FD"`) instead of reopening
the FIFO path (`> "$EVENT_FIFO"`), avoiding a blocking `open()` that
`kill -9` can't interrupt. The periodic watcher uses `read -t`
(interruptible) instead of `sleep` (which blocks on `kill -9`).

---

## 6. Validation and Safety

### 6.1 Path Validation (`validate_sync_path`)

A valid sync path must:

1. Be absolute
2. Not contain `..` components
3. Not be a system directory (`/`, `/home`, etc.)
4. Be ≥ 2 path levels deep

### 6.2 Sentinel Protection

Both local and remote must have `.sync/.sync-root` before any sync runs.
Created on first successful run. This is what stops the empty-directory
disaster: if the sentinel is missing, the script refuses to run.

### 6.3 MAX_DELETE Guard

`MAX_DELETE` caps the number of files a single rsync invocation will
delete. A sudden huge delete count almost always means a wrong path or
an unmounted filesystem, not a real intent to erase everything. Default
is 100; set to `-1` for unlimited (not recommended).

---

## 7. SSH and Transport

### 7.1 Control Socket Multiplexing

All rsync invocations in a cycle share one SSH connection via
`ControlMaster`/`ControlPath`. An event-driven syncer makes many short
connections and would otherwise pay a full TCP+auth handshake each time.

### 7.2 Local-to-Local Mode

Setting `REMOTE=""` in `sync.conf` disables SSH entirely. Two plain local
paths are synced with no network dependency. The test suite runs entirely
in this mode.

---

## 8. Rsync Option Sets

Four option sets are built from config:

| Set | Used For | Key Flags |
|---|---|---|
| **Common** | Both directions | `--checksum-choice=xxh128`, `--compress` (lz4), `--links`, `--partial-dir`, `--itemize-changes` |
| **Filter** | Both directions | EXCLUDES translated to `--filter` rules, `--protect-dirs` |
| **Pull** | Remote→local | NO `--update` (remote wins), `--checksum` (content-based), backup to `.sync/conflicts/<ts>/` on conflict |
| **Push** | Local→remote | `--update`, `--chmod`, `--chown` (remote permissions), journal-driven deletion |

---

## 9. Known Design Limitations

See `issues-discovered-by-qwen.md` for the full catalog.

| # | Issue | Severity | Status |
|---|---|---|---|
| 1 | Edit-vs-delete conflicts not archived to `.sync/conflicts/` (trash only) | Medium | Known |
| 4 | Renames fan out into delete+create pairs | Medium | Known |
| 5 | Stale EXCLUDES silently freeze files | Low | Known |
| 6 | No distributed locking across multiple peers | Low | Out of scope |
| 9 | Safety gates + `Restart=on-failure` restart loop | Medium | Known |
| 10 | Hardlink groups crossing exclude boundary | Low | Known |

---

## 10. Test Strategy

### 10.1 Approach

All tests run in **local-to-local mode** (`REMOTE=""`) — two plain
directories, no SSH, no network. Uses **bats-core** (≥ 1.10.0).

### 10.2 Files

| File | Coverage |
|---|---|
| `test_helper.bash` | Fixture setup, isolated function testing |
| `unit_functions.bats` | Pure functions: `version_ge`, `validate_sync_path`, `count_itemized_changes`, `shell_quote`, `build_inotify_exclude_regex` |
| `cli_and_config.bats` | Argument parsing, `validate_config()`, config loading |
| `sync_cycle.bats` | Full sync cycles: first-run gate, push/pull, conflicts, deletions, symlinks |
| `regression_bugfixes.bats` | Pinned historical regressions |

### 10.3 Running

```bash
shellcheck -x rsync-live-mirror.sh   # Lint
bats tests/                            # Full suite
```

---

## 11. Deployment Notes

### 11.1 systemd Service

```ini
[Service]
ExecStart=%h/bin/rsync-live-mirror.sh
Restart=on-failure
# CRITICAL: safety-gate exits (code 3) should NOT restart
RestartPreventExitStatus=3
```

### 11.2 Cron Alternative

```cron
*/15 * * * * /home/me/bin/rsync-live-mirror.sh --dir /home/me/myproject --once --quiet
```

### 11.3 Service Lifecycle

The service starts, acquires the lock for the first cycle, and then
enters the watcher loop. Signal handling:

- `SIGINT`/`SIGTERM`: graceful shutdown — watchers stop, lock releases

---

## Appendix A: Exit Codes

| Code | Meaning |
|---|---|
| `0` | OK |
| `1` | Config/usage error |
| `2` | Dependency missing or wrong version |
| `3` | Safety gate tripped (path, sentinel, MAX_DELETE) |
| `4` | Connection failure |
| `5` | Rsync failure |

## Appendix B: Configuration Quick Reference

| Key | Values | Default |
|---|---|---|
| `REMOTE` | `user@host`, SSH alias, or `""` (local) | (required) |
| `REMOTE_DIR` | Absolute remote path | (required) |
| `EXCLUDES` | Bash array of rsync globs | `()` |
| `DELETE_MODE` | `both` / `pull` / `push` / `none` | `both` |
| `MAX_DELETE` | Integer or `-1` | `100` |
| `PULL_COMPARE` | `checksum` / `quick` | `checksum` |
| `REMOTE_WATCH` | `poll` / `inotify` | `poll` |
| `REQUIRE_SENTINEL` | `true` / `false` | `true` |

## Appendix C: Environment

| Variable | Purpose |
|---|---|
| `LC_ALL` | Forced to `C` for stable sorting |
| `IFS` | Forced to `$'\n\t'` to prevent whitespace path bugs |
