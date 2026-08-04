# rsync-live-mirror

Continuous **bidirectional** folder sync over SSH, driven by filesystem events
(`inotify`) rather than a fixed schedule.

- Transfers with `rsync` over `ssh`
- **xxh128** checksums, **lz4** compression
- **Remote wins** on conflicts; the losing local copy is archived
- Symlinks are **copied as symlinks**, never followed
- Deletions propagate **both ways**, confined to the synced tree
- Configured by a `sync.conf` inside the folder being synced

---

## Requirements

| Side | Needs |
| — | — |
| Local | `bash` 4+, `rsync` ≥ 3.1.3 (xxhash + lz4), `ssh`, `inotify-tools`, `flock`, `realpath` |
| Remote | `rsync` (same features); `inotify-tools` only if `REMOTE_WATCH="inotify"` |

`sudo apt install rsync openssh-client inotify-tools util-linux coreutils`

Verify: `rsync --version | grep -A1 -E 'Checksum list|Compress list'`

---

## Setup

1. **Place `sync.conf` in the folder to sync.** Copy `sync.conf.example`, edit `REMOTE` and `REMOTE_DIR`.
2. **SSH key auth** must work without a prompt (`ssh user@host true`).
3. **Create the remote directory** if needed.
4. **Validate and run:**

```bash
./rsync-live-mirror.sh --dir ~/myproject --check              # config + connectivity
./rsync-live-mirror.sh --dir ~/myproject --once --dry-run     # preview changes
./rsync-live-mirror.sh --dir ~/myproject --force-first-run    # first real run
./rsync-live-mirror.sh --dir ~/myproject                       # watch continuously
```

The first run requires `--force-first-run` to prevent a misconfigured path from
mirroring an empty tree over real data.

---

## Usage

```
./rsync-live-mirror.sh [OPTIONS]

-d, --dir PATH        Local sync root (folder holding sync.conf)
-1, --once            One cycle, then exit
    --check           Validate config, deps, connectivity, then exit
-n, --dry-run         Report changes without modifying anything
    --pull-only       Remote -> local only
    --push-only       Local -> remote only
    --force-first-run Allow the first real run
-v, --verbose         Debug logging
-q, --quiet           Errors only
-h, --help            Help
```

Exit codes: `0` ok · `1` config · `2` dependency · `3` safety gate · `4` connection · `5` rsync.

---

## How a sync cycle works

1. **Local deletions → remote** (from inotify journal)
2. **Remote deletions → local** (from snapshot diff)
3. **PULL** remote → local (no `--update`, remote overwrites)
4. **PUSH** local → remote (with `--update`, never clobbers newer remote)
5. **Snapshot** remote listing (baseline for next cycle)

Cycles are serialized with `flock`; overlapping triggers are dropped, not queued.

---

## Conflict resolution: remote wins

- The **pull omits `--update`** — remote always overwrites local differences.
- The **push uses `--update`** — never overwrites a newer remote file.
- Comparison uses **xxh128 content hashing**, not timestamps.
- The losing local copy is archived to `.sync/conflicts/<timestamp>/`.

---

## Deletion: bidirectional, confined to the tree

- **Local → remote**: inotify journals every `DELETE`/`MOVED_FROM`; only journaled paths are removed remotely.
- **Remote → local**: remote listing is snapshotted each cycle; anything gone from the remote is removed locally.

The snapshot records each remote path as a 4-field record:
`path<TAB>size<TAB>xxh128<TAB>mtime`.  This lets deletion detection tell
"the file is actually gone" apart from "the file is still there, but its
content changed" — the comparison is always done on the **path field only**,
so an ordinary remote edit is never mistaken for a deletion.  The xxh128 hash
is also used for **move/rename detection**: when a path vanishes from the
remote, but a new path appears with the same content hash, the local side
recognizes the rename and moves the local file rather than deleting and
recreating.  The mtime field (epoch seconds from rsync `%T`) records the
remote modification time for each path.  The trade-off: computing the hash
means every remote file is fully read once per cycle for the snapshot, on
top of the read `PULL_COMPARE="checksum"` already performs for the pull
itself.

Four guards prevent deletion from escaping:
1. **No `--keep-dirlinks`** — symlinks pointing outside the tree are replaced in-tree
2. **Path validation** — absolute, no `..`, not a system directory, ≥2 levels deep
3. **Sentinels** — `.sync/.sync-root` required on both sides
4. **Re-validated paths** — journal/snapshot entries are treated as untrusted input

---

## Configuration

See `sync.conf.example` for the full documented list.

| Key | Meaning |
| — | — |
| `REMOTE` | `user@host`, SSH alias, or `""` for local-to-local |
| `REMOTE_DIR` | absolute path on remote |
| `EXCLUDES` | bash array of rsync glob patterns |
| `DELETE_MODE` | `both` · `pull` · `push` · `none` |
| `MAX_DELETE` | deletion cap per run (`-1` = unlimited) |
| `PULL_COMPARE` | `checksum` (xxh128) or `quick` (size+mtime) |
| `REMOTE_WATCH` | `poll` or `inotify` |

---

## Troubleshooting

- **Cannot connect** — key auth must work: `ssh user@host true`
- **Sentinel missing** — check both paths, then re-register with `--force-first-run`
- **Deletions don't reach remote** — push deletion needs the live watcher; `--once` only applies journaled deletions
- **Partial transfer (rsync 23)** — usually `--owner`/`--group` without privilege; try `PRESERVE_OWNER="false"`
- **Too many cycles** — raise `DEBOUNCE_SECONDS`, add noisy dirs to `EXCLUDES`

---

## Local-to-local mode

Set `REMOTE=""` in `sync.conf` to sync two local paths with no SSH. Useful
for testing or syncing to a mounted drive.

---

## Service deployment

```
 # ~/.config/systemd/user/rsync-monitor.service
[Service]
ExecStart=%h/bin/rsync-live-mirror.sh
Restart=on-failure
```

Or with `--once` from cron:

` */15 * * * * /home/me/bin/rsync-live-mirror.sh --dir /home/me/myproject --once --quiet`
