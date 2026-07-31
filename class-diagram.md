# OOP Class Diagram for `mirror-remote-directory.sh`

`mirror-remote-directory.sh` is a bash script, not a true OOP language, but its
functions cluster tightly around distinct responsibilities and shared state.
This document maps that structure onto a conventional UML class diagram:
each "class" is a conceptual module, each bash global becomes an attribute of
the class that owns it, and each function becomes a method. Bash has no
enforced visibility, so the `_`-prefix naming convention is treated as
`private` and everything else as `public`.

## Diagram

```mermaid
classDiagram
    class Controller {
        -MODE : string
        -DIRECTION : string
        -FORCE_FIRST_RUN : bool
        -VERBOSE : bool
        -RUN_TS : string
        -SHUTTING_DOWN : bool
        +main()
        +run_check()
        +cleanup()
        +on_signal()
        +print_summary()
    }

    class Configuration {
        -LOCAL_DIR : string
        -CONF_FILE : string
        -REMOTE : string
        -REMOTE_DIR : string
        -CLI_DIR : string
        -CLI_DRY_RUN : string
        +usage()
        +parse_args()
        +find_config_upward()
        +resolve_config()
        +load_config()
    }

    class Validation {
        -REQUIRE_SENTINEL : bool
        -MAX_CHANGES_PER_CYCLE : int
        +validate_config()
        +validate_sync_path()
        +check_dependencies()
        +version_ge()
    }

    class Logging {
        -LOG_FILE : string
        -LOG_LEVEL : string
        -LOG_PATH : string
        -LOG_MAX_KB : int
        -_log_level_num()
        -_log()
        +log_error()
        +log_warn()
        +log_info()
        +log_debug()
        +log_ok()
        +die()
    }

    class LogRotation {
        +rotate_log_if_needed()
    }

    class State {
        -STATE_DIR : string
        -SENTINEL_PATH : string
        -LOCK_FILE : string
        -DELETE_JOURNAL : string
        +init_state_dir()
        +local_sentinel_exists()
        +write_local_sentinel()
        +write_remote_sentinel()
        +remote_sentinel_exists()
        +check_sentinels()
        +shell_quote()
    }

    class Snapshot {
        -TRASH_ENABLED : bool
        -TRASH_KEEP_DAYS : int
        +prune_old_snapshots()
        +update_remote_snapshot()
        +apply_journaled_deletes()
    }

    class Connection {
        -REMOTE_PORT : string
        -SSH_KEY : string
        -SSH_EXTRA_OPTS : array
        -SSH_CONTROL_PATH : string
        -SSH_MULTIPLEXING : bool
        +build_ssh_opts()
        +build_rsync_ssh_transport()
        +ssh_cmd()
        +check_connection()
    }

    class RsyncOptions {
        -EXCLUDES : array
        -REMOTE_CHMOD : string
        -REMOTE_CHOWN : string
        -PRESERVE_OWNER : bool
        -PRESERVE_GROUP : bool
        -CONFLICT_BACKUP : bool
        -PULL_COMPARE : string
        -SAFE_LINKS : bool
        -PRESERVE_HARDLINKS : bool
        +build_common_opts()
        +build_filter_opts()
        +build_pull_opts()
        +build_push_opts()
    }

    class Sync {
        -DELETE_MODE : string
        -DELETE_PUSH_UNSAFE : bool
        -MAX_DELETE : int
        -BWLIMIT : string
        -RSYNC_TIMEOUT : int
        -LAST_CHANGE_COUNT : int
        +sync_cycle()
        +sync_cycle_locked()
        +run_rsync()
        +do_pull()
        +do_push()
        +estimate_changes()
        +list_remote_paths()
        +apply_remote_deletions()
        +remote_endpoint()
        +local_endpoint()
        +count_itemized_changes()
    }

    class Watcher {
        -REMOTE_WATCH : string
        -REMOTE_POLL_INTERVAL : int
        -DEBOUNCE_SECONDS : int
        -PERIODIC_FULL_SYNC : int
        -WATCHER_PIDS : array
        -EVENT_FIFO : string
        +watch_loop()
        +pause_watchers()
        +resume_watchers()
        +start_local_watcher()
        +remote_has_inotifywait()
        +start_remote_inotify_watcher()
        +start_remote_poll_watcher()
        +start_remote_watcher()
        +start_periodic_watcher()
        +build_inotify_exclude_regex()
    }

    Controller *-- Configuration : owns
    Controller *-- Validation : owns
    Controller *-- Logging : owns
    Controller *-- State : owns
    Controller *-- Snapshot : owns
    Controller *-- Sync : owns
    Controller *-- Watcher : owns

    Logging *-- LogRotation : owns

    Configuration ..> Logging : uses
    Validation ..> Logging : uses

    Sync *-- Connection : owns
    Sync *-- RsyncOptions : owns
    Sync --> Snapshot : uses
    Sync --> State : uses
    Sync ..> Logging : uses
    Sync o-- Watcher : pauses/resumes

    Watcher ..> Logging : uses
    Watcher --> Sync : triggers

    Snapshot --> Connection : uses
    Snapshot ..> Logging : uses

    State --> Connection : uses
    State ..> Logging : uses

    Connection ..> Logging : uses

    RsyncOptions --> Configuration : reads
```

## Class Descriptions

| Class | Responsibility |
|---|---|
| `Controller` | Top-level orchestrator. Entry point, run mode dispatch (`watch`/`once`/`check`), signal handling, and shutdown/summary reporting. |
| `Configuration` | Argument parsing and config-file loading; locates `sync.conf` by searching upward from the working directory. |
| `Validation` | Validates the resolved configuration, sync paths, and required external tool availability/versions. |
| `Logging` | Centralized logging facility with severity levels (`error`/`warn`/`info`/`debug`/`ok`) and a `die()` fatal-error path. |
| `LogRotation` | Rotates the log file once it exceeds a configured size, so it stays bounded. |
| `State` | Owns the `.sync` state directory and the sentinel files used to detect first-run and track sync progress. |
| `Snapshot` | Snapshot-based remote-file tracking used to detect and journal deletions, with trash retention. |
| `Connection` | Builds SSH options/transport and multiplexed control sockets; verifies remote reachability. |
| `RsyncOptions` | Builds the `rsync` argument sets (common, filter, pull, push) from the loaded configuration. |
| `Sync` | Core sync engine: pull/push cycles, change estimation, remote path listing, and deletion propagation. |
| `Watcher` | File-change detection: local `inotifywait`, remote `inotifywait`/polling, and a periodic full-sync fallback. |

## Relationship Legend

- `*--` **Composition** — the owning class creates and is responsible for the lifetime of the owned class's state (e.g. `Controller` composes `Configuration`, `Sync` composes `Connection`).
- `o--` **Aggregation** — a looser "has-a" link where the related object exists independently (`Sync` aggregates `Watcher`: it pauses/resumes it, but does not own its lifecycle — `Controller` does).
- `-->` **Association** — one class calls into another's public interface without owning it (e.g. `Sync --> State`).
- `..>` **Dependency** — a lightweight, typically read-only or cross-cutting usage (nearly every class depends on `Logging`).

## Notes

- Private methods are prefixed with `_` in the source (e.g. `_log`, `_log_level_num`) and are marked `-` (private) above; everything else is marked `+` (public).
- Attributes shown are the bash global variables each class reads or writes; the script itself has no formal encapsulation, so this grouping reflects usage patterns rather than enforced scope.
- `RsyncOptions` depends on `Configuration` for its inputs (excludes, ownership/permission settings) but has no reverse dependency.
- `Sync` and `Watcher` have a mutual relationship: `Sync` pauses/resumes `Watcher` during a sync cycle, and `Watcher` triggers `Sync` cycles on detected changes.
