# OOP Class Diagram for `mirror-remote-directory.sh`

## Classes

### Controller
**Description:** Top-level orchestrator. Manages lifecycle, entry point, check mode, and shutdown.
- `main()`
- `run_check()`
- `cleanup()`
- `on_signal()`
- `print_summary()`

### Logging
**Description:** Centralized logging facility with severity levels and log rotation.
- `_log_level_num()`
- `_log()`
- `log_error()`
- `log_warn()`
- `log_info()`
- `log_debug()`
- `log_ok()`
- `die()`

### LogRotation
**Description:** Log file rotation to prevent unbounded growth.
- `rotate_log_if_needed()`

### Configuration
**Description:** Argument parsing and config file loading. Searches upward for config files.
- `usage()`
- `parse_args()`
- `find_config_upward()`
- `resolve_config()`
- `load_config()`

### Validation
**Description:** Validates configuration, sync paths, and dependency availability.
- `validate_config()`
- `validate_sync_path()`
- `check_dependencies()`
- `version_ge()`

### State
**Description:** Manages sync state directory, sentinel files for tracking sync progress.
- `init_state_dir()`
- `local_sentinel_exists()`
- `write_local_sentinel()`
- `write_remote_sentinel()`
- `remote_sentinel_exists()`
- `check_sentinels()`
- `shell_quote()`

### Snapshot
**Description:** Snapshot-based file tracking for deletion detection.
- `prune_old_snapshots()`
- `update_remote_snapshot()`
- `apply_journaled_deletes()`

### Connection
**Description:** SSH connection management and transport configuration.
- `build_ssh_opts()`
- `build_rsync_ssh_transport()`
- `ssh_cmd()`
- `check_connection()`

### RsyncOptions
**Description:** Builds rsync command options for common, filter, pull, and push scenarios.
- `build_common_opts()`
- `build_filter_opts()`
- `build_pull_opts()`
- `build_push_opts()`

### Sync
**Description:** Core sync operations: pull, push, estimate changes, rsync execution, endpoint construction.
- `sync_cycle()`
- `sync_cycle_locked()`
- `run_rsync()`
- `do_pull()`
- `do_push()`
- `estimate_changes()`
- `list_remote_paths()`
- `apply_remote_deletions()`
- `remote_endpoint()`
- `local_endpoint()`
- `count_itemized_changes()`

### Watcher
**Description:** File change detection via inotifywait, polling, and periodic schedules.
- `watch_loop()`
- `pause_watchers()`
- `resume_watchers()`
- `start_local_watcher()`
- `remote_has_inotifywait()`
- `start_remote_inotify_watcher()`
- `start_remote_poll_watcher()`
- `start_remote_watcher()`
- `start_periodic_watcher()`
- `build_inotify_exclude_regex()`

## Relationships

- `Controller` **uses** `Configuration`, `Validation`, `Logging`, `Sync`, `Watcher`
- `Controller` **uses** `State`, `Snapshot`
- `Configuration` **uses** `Logging`
- `Validation` **uses** `Logging`
- `Sync` **uses** `Logging`, `Connection`, `RsyncOptions`, `Snapshot`, `State`
- `Sync` **uses** `Watcher` (pause/resume during sync)
- `Watcher` **uses** `Logging`, `Sync`
- `Snapshot` **uses** `Logging`, `Connection`
- `State` **uses** `Logging`, `Connection`
- `Connection` **uses** `Logging`
- `RsyncOptions` **uses** `Configuration`
- `LogRotation` **used by** `Logging`

## Notes

- Private functions are prefixed with `_` (e.g., `_log`, `_log_level_num`)
- The script is a bash script, not a true OOP language. This diagram maps bash functions to conceptual classes.
