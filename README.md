# rsync-monitor

Continuous **bidirectional** folder sync over SSH, driven by filesystem events
(`inotify`) rather than a fixed schedule.

- Transfers with `rsync` over `ssh`
- **xxh128** checksums, **lz4** compression
- **Remote wins** every conflict; the losing local copy is archived
- Symlinks are **copied as symlinks**, never followed
- Deletions propagate **both ways**, and cannot escape the synced tree
- Configured by a `sync.conf` that lives **inside the folder being synced**

---

## Requirements

| Side | Needs |
|---|---|
| Local | `bash` 4+, `rsync` ≥ 3.1.3 built with xxhash + lz4, `ssh`, `inotify-tools`, `flock`, `realpath` |
| Remote | `rsync` (ideally same features); `inotify-tools` only for `REMOTE_WATCH="inotify"` |

On Debian / Ubuntu / Pop!_OS:

```bash
sudo apt install rsync openssh-client inotify-tools util-linux coreutils
```

Verify your rsync has the required algorithms:

```bash
rsync --version | grep -A1 -E 'Checksum list|Compress list'
# Checksum list: xxh128 xxh3 xxh64 md5 md4 sha1 none
# Compress list: zstd lz4 zlibx zlib none
```

The script checks both at startup and refuses to run if either is missing.

---

## Setup

1. **Put the config in the folder you want to sync.** Its location *is* the
   local sync root, so there is no `LOCAL_DIR` setting.

   ```bash
   cp sync.conf.example ~/myproject/sync.conf
   $EDITOR ~/myproject/sync.conf     # set REMOTE and REMOTE_DIR
   ```

2. **Set up SSH key authentication.** The script runs `ssh` with
   `BatchMode=yes` and will never prompt, so password-only auth fails:

   ```bash
   ssh-copy-id user@host
   ssh user@host true      # must succeed without a prompt
   ```

3. **Create the remote directory** if it does not exist:

   ```bash
   ssh user@host 'mkdir -p /srv/project'
   ```

4. **Validate, preview, then commit:**

   ```bash
   ./mirror-remote-directory.sh --dir ~/myproject --check            # config + connectivity
   ./mirror-remote-directory.sh --dir ~/myproject --once --dry-run   # what would change
   ./mirror-remote-directory.sh --dir ~/myproject --force-first-run  # first real run
   ./mirror-remote-directory.sh --dir ~/myproject                    # watch continuously
   ```

The first real run needs `--force-first-run`. That gate exists so a
misconfigured path cannot mirror an empty tree over real data on its first
attempt.

---

## Usage

```
./mirror-remote-directory.sh [OPTIONS]

-d, --dir PATH        Local sync root (the folder holding sync.conf)
-c, --config PATH     Use this config; its directory becomes the root
-1, --once            One cycle, then exit (cron / systemd timers)
    --check           Validate config, deps and connectivity, then exit
-n, --dry-run         Report changes without modifying anything
    --pull-only       Remote -> local only
    --push-only       Local -> remote only
    --force-first-run Allow the first real run
-v, --verbose         Debug logging
-q, --quiet           Errors only
-h, --help            Help
```

The sync root is located via `--dir`, then `$RSYNC_SYNC_DIR`, then by searching
upward from the current directory — so inside the folder, plain `./mirror-remote-directory.sh`
works.

Exit codes: `0` ok · `1` config · `2` dependency · `3` safety gate ·
`4` connection · `5` rsync.

---

## How a cycle works

Order is load-bearing:

| # | Step | Why here |
|---|---|---|
| 1 | **Local deletions → remote** (inotify journal) | Before the pull, or the pull would re-download the file you just deleted |
| 2 | **Remote deletions → local** (snapshot diff) | Before the pull, or the push would re-upload it |
| 3 | **PULL** remote → local | No `--update`, so the remote overwrites local differences |
| 4 | **PUSH** local → remote | With `--update`, so a newer remote file is never clobbered |
| 5 | **Snapshot** remote listing | Baseline for the next cycle's deletion diff |

Cycles are serialised with `flock`; overlapping triggers are dropped rather
than queued, since the running cycle already covers them.

---

## Conflict resolution: remote wins

A conflict is the same path changing on **both** sides between cycles.

- The **pull deliberately omits `--update`**, so any differing file is
  overwritten by the remote copy — regardless of which side has the newer
  mtime. That omission *is* the policy.
- The **push uses `--update`**, so it can never overwrite a remote file whose
  mtime is newer.
- Comparison uses **xxh128 content hashing** (`PULL_COMPARE="checksum"`), not
  timestamps, because mtime is unreliable across hosts with skewed clocks or
  different filesystem timestamp precision.
- The losing local copy is moved to `.sync/conflicts/<timestamp>/` — nothing is
  silently destroyed.

```bash
# recover a local version that lost a conflict
ls ~/myproject/.sync/conflicts/
diff ~/myproject/.sync/conflicts/20260130-140533/notes.md ~/myproject/notes.md
```

---

## Deletion: bidirectional, and confined to the tree

### Why not just `--delete` both ways

rsync compares two trees. It **cannot** distinguish *"new on this side"* from
*"deleted on the other side"* — both look like "present here, absent there". A
blanket `--delete` in both directions therefore destroys newly created files.
Neither direction uses one. Instead each side keeps an explicit record of what
actually disappeared:

- **Local → remote**: the inotify watcher journals every `DELETE` /
  `MOVED_FROM` to `.sync/pending-deletes`. Only those exact paths are removed
  remotely. A path that reappeared locally (an editor's atomic save) is skipped.
- **Remote → local**: after each cycle the remote listing is saved to
  `.sync/remote-snapshot`. Next cycle, anything in the snapshot but no longer
  on the remote was genuinely deleted there, so it is removed locally.

With `--once` there is no live watcher, so push-side deletion is limited to
whatever is already in the journal. `DELETE_PUSH_UNSAFE="true"` opts into a
blanket `--delete` for one-way mirror jobs — it *will* delete new remote files.

### Why deletion cannot escape the tree

Four independent guards:

1. **No `--keep-dirlinks`.** This is the main one. With it, a symlinked
   directory on the receiver pointing outside the tree would be written and
   deleted *through*, so `--delete` could reach the link target. Omitting it
   makes rsync replace the symlink in-tree instead of descending through it.
   `--copy-links`, `--copy-dirlinks` and `--copy-unsafe-links` are omitted for
   the same reason.
2. **Path validation.** Both roots must be absolute, free of `..`, not a system
   directory (`/`, `/etc`, `/home`, `/usr`, …), and at least two levels deep.
3. **Sentinels.** `.sync/.sync-root` must exist on **both** sides. If one is
   missing the run is refused — this is what catches an unmounted drive or a
   typo'd path presenting an empty directory.
4. **Re-validated paths.** Journal and snapshot entries are treated as
   untrusted input: absolute paths, `..`, and anything under `.sync/` are
   rejected before any deletion.

Plus: `--max-delete` caps deletions per run, and `TRASH_ENABLED` moves files to
`.sync/trash/<timestamp>/` instead of unlinking them.

```bash
# restore something deleted by mistake
ls ~/myproject/.sync/trash/
cp ~/myproject/.sync/trash/20260130-141020/report.pdf ~/myproject/
```

---

## Symlinks

`--links` is used and every dereferencing option is deliberately omitted, so a
symlink is always recreated as a symlink — including one pointing outside the
tree, which is copied as an inert link and never followed.

Set `SAFE_LINKS="true"` to make the receiver skip out-of-tree and absolute
symlinks entirely. Note this also blocks legitimate absolute symlinks.


---

## Change detection

**Local** — `inotifywait` on `close_write,create,delete,move,attrib`.
`modify` is not watched: `close_write` covers completed writes with far fewer
duplicate events. The `EXCLUDES` globs are translated into an inotify exclude
regex so the watcher ignores exactly what the transfer ignores (otherwise
activity in `node_modules/` would trigger cycles that transfer nothing).

**Remote** — inotify is a local-kernel API and cannot watch a remote
filesystem, so there are two options:

| `REMOTE_WATCH` | Mechanism | Trade-off |
|---|---|---|
| `poll` (default) | re-pull every `REMOTE_POLL_INTERVAL`s | no remote deps; latency up to that interval |
| `inotify` | `inotifywait` over ssh, events streamed back | near-instant; needs `inotify-tools` remotely; auto-falls back to poll |

**Debounce** — one editor save emits several events, so a sync fires only after
`DEBOUNCE_SECONDS` of quiet; a burst becomes exactly one cycle.

**Safety net** — `PERIODIC_FULL_SYNC` runs a full cycle every N seconds to
catch anything missed (inotify queue overflow, events during a dropped link).

---

## `.sync/` layout

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
└── ssh-*               ssh ControlMaster sockets
```

`trash/` and `conflicts/` are pruned after `TRASH_KEEP_DAYS`.

---

## Configuration reference

See `sync.conf.example` — every option is documented inline. The essentials:

| Key | Meaning |
|---|---|
| `REMOTE` | `user@host`, an ssh_config alias, or `""` for local-to-local |
| `REMOTE_DIR` | absolute path on the remote |
| `EXCLUDES` | bash array of rsync glob patterns |
| `REMOTE_CHMOD` / `REMOTE_CHOWN` | permissions/ownership applied on push |
| `DELETE_MODE` | `both` · `pull` · `push` · `none` |
| `MAX_DELETE` | deletion cap per run (`-1` = unlimited) |
| `PULL_COMPARE` | `checksum` (xxh128) or `quick` (size+mtime) |
| `REMOTE_WATCH` | `poll` or `inotify` |
| `REQUIRE_SENTINEL` | refuse to run unless both sides are marked |

Validate after editing:

```bash
./mirror-remote-directory.sh --dir ~/myproject --check
```

---

## Running as a service

```ini
# ~/.config/systemd/user/rsync-monitor.service
[Unit]
Description=Bidirectional rsync sync for ~/myproject
After=network-online.target

[Service]
Type=simple
Environment=RSYNC_SYNC_DIR=%h/myproject
ExecStart=%h/bin/mirror-remote-directory.sh
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now rsync-monitor
journalctl --user -u rsync-monitor -f
```

For periodic instead of continuous syncing, use `--once` from cron:

```cron
*/15 * * * * /home/me/bin/mirror-remote-directory.sh --dir /home/me/myproject --once --quiet
```

---

## Local-to-local mode

Set `REMOTE=""` to sync two local paths with no ssh — useful for testing the
configuration, or syncing to a mounted drive. The script refuses overlapping
(nested) roots, since rsync would recurse into its own destination.


---

## Troubleshooting

**`cannot connect to 'host'`** — `BatchMode=yes` forbids prompts. Ensure key
auth works: `ssh user@host true`. Reproduce with the exact options the script
uses via `--verbose`.

**`sentinel MISSING on the … side`** — a path is wrong, a filesystem is not
mounted, or that side's `.sync/` was deleted. Verify both paths, then
re-register by removing the remaining sentinel and using `--force-first-run`.

**`hit MAX_DELETE=…, remaining deletions were SKIPPED`** (rsync 25) — usually a
wrong path or an unmounted filesystem, not a real intent to erase. Verify both
sides before raising the cap.

**`partial transfer … (rsync 23)`** — typically `--owner`/`--group` without
privilege on the receiver. Set `PRESERVE_OWNER="false"` and
`PRESERVE_GROUP="false"`, or use `REMOTE_RSYNC="sudo rsync"`.

**Deletions do not reach the remote** — push-side deletion needs the live
watcher. `--once` only applies whatever is already journaled.

**A file keeps coming back** — it is excluded, and therefore also `protect`ed
from deletion, so the other side never removes it. Check `EXCLUDES`.

**Too many cycles** — raise `DEBOUNCE_SECONDS`, and make sure noisy build
directories are in `EXCLUDES` so the watcher ignores them.

---

## Known limitations

- **No true 3-way merge.** Conflicts are resolved by policy (remote wins), not
  merged. The losing copy is archived, not reconciled.
- **Deletion detection needs the watcher.** Push-side deletions are
  event-sourced, so a `--once` run cannot discover deletions that happened
  while nothing was watching.
- **Snapshot granularity.** A remote file deleted *and* recreated between two
  cycles looks unchanged.
- **`--owner`/`--devices`/`--specials`** need privilege on the receiver;
  without it rsync reports exit 23.
- **Large trees with `PULL_COMPARE="checksum"`** read both copies every cycle.
  Use `quick` if that is too expensive.
- **inotify watch limits.** Very large trees may exhaust
  `fs.inotify.max_user_watches`; raise it via sysctl or exclude more paths.
