#!/usr/bin/env bash
# =============================================================================
#  lib/watcher.sh -- Watcher (class-diagram.md)
# =============================================================================
#  Three producers can feed the event channel:
#    * local inotify   -- immediate, kernel-level
#    * remote watcher  -- inotifywait over ssh, or a periodic poll
#    * periodic timer  -- safety-net full sync
#  All of them write a single line to $EVENT_FIFO; watch_loop() (Controller,
#  called from main()) debounces.
# =============================================================================

# Pause all watcher processes (inotifywait, ssh tails) so they stop producing
# events while a sync cycle is running. This prevents the event FIFO from
# filling with events that will become stale after the sync completes.
pause_watchers() {
  [[ ${#WATCHER_PIDS[@]} -eq 0 ]] && return 0

  local count=0
  for pid in "${WATCHER_PIDS[@]}"; do
    if kill -0 "$pid" 2> /dev/null; then
      log_debug "pausing watcher pid $pid"
      kill -STOP "$pid" 2> /dev/null || true
      count=$((count + 1))
    else
      log_debug "watcher pid $pid no longer exists (not pausing)"
    fi
  done

  # Drain the FIFO to discard events that were buffered while watchers were
  # running but are about to become stale after the sync completes.
  # We use cat with a short timeout to avoid blocking forever.
  if [[ -p $EVENT_FIFO ]]; then
    cat "$EVENT_FIFO" &> /dev/null &
    local drain_pid=$!
    local drain_timeout=2 # seconds
    local drain_elapsed=0
    while kill -0 "$drain_pid" 2> /dev/null && [[ $drain_elapsed -lt $drain_timeout ]]; do
      sleep 0.5
      drain_elapsed=$((drain_elapsed + 1))
    done
    # If the drain is still running after timeout, terminate it.
    kill "$drain_pid" 2> /dev/null && wait "$drain_pid" 2> /dev/null || true
    log_debug "drained event FIFO after pausing watchers"
  fi

  log_info "paused $count watcher(s); will resume after sync"
}

# Resume previously paused watchers and drain any events they accumulated
# while paused, so stale events don't trigger spurious sync cycles.
resume_watchers() {
  [[ ${#WATCHER_PIDS[@]} -eq 0 ]] && return 0

  local count=0
  for pid in "${WATCHER_PIDS[@]}"; do
    if kill -0 "$pid" 2> /dev/null; then
      log_debug "resuming watcher pid $pid"
      kill -CONT "$pid" 2> /dev/null || true
      count=$((count + 1))
    fi
  done

  # Brief pause so watchers can flush any buffered writes to the FIFO before
  # we drain. This ensures we discard events that arrived during the sync
  # but were written to the FIFO while watchers were paused.
  sleep 0.3

  # Drain the FIFO again to discard events that accumulated while watchers
  # were paused (now written to the FIFO after resume).
  if [[ -p $EVENT_FIFO ]]; then
    cat "$EVENT_FIFO" &> /dev/null &
    local drain_pid=$!
    local drain_timeout=2
    local drain_elapsed=0
    while kill -0 "$drain_pid" 2> /dev/null && [[ $drain_elapsed -lt $drain_timeout ]]; do
      sleep 0.5
      drain_elapsed=$((drain_elapsed + 1))
    done
    kill "$drain_pid" 2> /dev/null && wait "$drain_pid" 2> /dev/null || true
    log_debug "drained event FIFO after resuming watchers"
  fi

  log_info "resumed $count watcher(s); drained stale events"
}

# Translate the rsync globs in EXCLUDES into one POSIX ERE for inotifywait, so
# the watcher ignores exactly what the transfer ignores. Without this, activity
# in node_modules/ or .git/ would trigger cycles that then transfer nothing.
build_inotify_exclude_regex() {
  local -a parts=()

  # Always ignore our own state dir; otherwise writing the log or the trash
  # would trigger a sync, which would write the log again -> feedback loop.
  parts+=("/\\.sync(/|$)")
  parts+=("/${CONF_NAME//./\\.}$")

  local pattern
  for pattern in "${EXCLUDES[@]}"; do
    [[ -z $pattern || $pattern == "#"* || $pattern == "!"* ]] && continue

    local p="$pattern"
    local anchored="false" dir_only="false"
    [[ $p == /* ]] && {
      anchored="true"
      p="${p#/}"
    }
    [[ $p == */ ]] && {
      dir_only="true"
      p="${p%/}"
    }

    # Escape regex metacharacters, then convert glob wildcards.
    # Order matters: escape first so "." becomes "\." before "*" becomes ".*".
    local re="$p"
    re="${re//\\/\\\\}"
    re="${re//./\\.}"
    re="${re//+/\\+}"
    re="${re//(/\\(}"
    re="${re//)/\\)}"
    re="${re//|/\\|}"
    re="${re//^/\\^}"
    re="${re//\$/\\\$}"
    re="${re//\{/\\\{}"
    re="${re//\}/\\\}}"
    re="${re//\?/.}"     # glob ? -> any single char
    re="${re//\*/[^/]*}" # glob * -> anything but a slash

    if [[ $anchored == "true" ]]; then
      # Anchored at the sync root: match only just below LOCAL_DIR.
      local root_re="${LOCAL_DIR//./\\.}"
      if [[ $dir_only == "true" ]]; then
        parts+=("^${root_re}/${re}(/|$)")
      else
        parts+=("^${root_re}/${re}$")
      fi
    else
      # Unanchored: match at any depth.
      if [[ $dir_only == "true" ]]; then
        parts+=("/${re}(/|$)")
      else
        parts+=("/${re}$")
      fi
    fi
  done

  # Join with "|" into a single alternation.
  local IFS='|'
  printf '(%s)' "${parts[*]}"
}

# Local inotify watcher. Runs in the background, writes to the FIFO, and
# journals deletions so the push knows what to remove remotely.
start_local_watcher() {
  local exclude_re
  exclude_re="$(build_inotify_exclude_regex)"
  log_debug "inotify exclude regex: $exclude_re"

  # Events chosen deliberately:
  #   close_write  a file finished being written (better than "modify", which
  #                fires repeatedly mid-write)
  #   create/delete/move  structural changes
  #   attrib       permission/ownership changes
  # NOT "modify": close_write already covers completed writes with far fewer
  # duplicate events.
  #
  # inotifywait runs inside a pipeline in a background subshell, so its PID is
  # NOT the subshell's PID and a kill aimed at the subshell would leave it
  # orphaned. It therefore records its own PID into $STATE_DIR/inotify.pid so
  # cleanup() can signal it directly.
  # inotifywait is started in its own background job FIRST, so its real PID can
  # be recorded. Had it been the left-hand side of a pipeline inside a
  # background subshell, $! would name the subshell instead and a kill aimed
  # there would leave inotifywait running as an orphan holding kernel watches.
  local fifo_in="$STATE_DIR/inotify.raw"
  rm -f "$fifo_in"
  mkfifo -m 600 "$fifo_in" || die "$EX_CONFIG" "cannot create the inotify FIFO: $fifo_in"

  inotifywait \
    --monitor \
    --recursive \
    --quiet \
    --event close_write \
    --event create \
    --event delete \
    --event move \
    --event attrib \
    --exclude "$exclude_re" \
    --format '%e|%w%f' \
    "$LOCAL_DIR" > "$fifo_in" 2> /dev/null &

  local inotify_pid=$!
  WATCHER_PIDS+=("$inotify_pid")

  # Reader: translates raw inotify lines into event-channel messages and
  # journals deletions on the way through.
  (
    # Watcher subshells must not run cleanup() on exit — the parent owns
    # that responsibility (stopping watchers, removing FIFOs, etc.).
    trap - EXIT
    while IFS='|' read -r events path; do
      # Record deletions and move-outs for the push-side delete journal.
      # MOVED_FROM means the file left this path, which is a delete from the
      # remote's point of view.
      case "$events" in
        *DELETE* | *MOVED_FROM*)
          # Path relative to the sync root. No `local` here: this loop body
          # runs in a subshell, not inside a function.
          rel="${path#"$LOCAL_DIR"/}"
          if [[ -n $rel && $rel != "$path" ]]; then
            printf '%s\n' "$rel" >> "$DELETE_JOURNAL" 2> /dev/null || true
          fi
          ;;
      esac
      printf 'local|%s|%s\n' "$events" "$path" 1>&"$EVENT_FIFO_FD" 2> /dev/null || break
    done < "$fifo_in"
  ) &

  local reader_pid=$!
  WATCHER_PIDS+=("$reader_pid")
  log_info "local watcher started (inotify pid $inotify_pid) on $LOCAL_DIR"
}

# Does the remote have inotifywait? Determines whether REMOTE_WATCH="inotify"
# is actually usable, or must fall back to polling.
remote_has_inotifywait() {
  [[ -z $REMOTE ]] && {
    command -v inotifywait > /dev/null 2>&1
    return $?
  }
  ssh_cmd "command -v inotifywait >/dev/null 2>&1" > /dev/null 2>&1
}

# Remote watcher, inotify flavour: run inotifywait on the far side over ssh and
# stream its events back down the same channel the local watcher uses.
#
# inotify is a Linux-kernel-local interface -- it cannot watch a remote
# filesystem. Running the watcher *on* the remote and shipping events over the
# existing ssh connection is what makes near-instant remote detection possible.
start_remote_inotify_watcher() {
  local q_dir
  q_dir="$(shell_quote "$REMOTE_DIR")"

  # Excludes .sync/ remotely for the same feedback-loop reason as locally.
  local remote_cmd="inotifywait --monitor --recursive --quiet \
--event close_write --event create --event delete --event move --event attrib \
--exclude '(/\\.sync(/|\$)|/sync\\.conf\$)' \
--format '%e|%w%f' $q_dir 2>/dev/null"

  (
    # Watcher subshells must not run cleanup() on exit — the parent owns
    # that responsibility (stopping watchers, removing FIFOs, etc.).
    trap - EXIT
    # If the ssh stream dies (network drop, remote reboot) retry with a delay
    # rather than silently losing remote change detection for good.
    while [[ $SHUTTING_DOWN != "true" ]]; do
      ssh_cmd "$remote_cmd" 2> /dev/null |
        while IFS='|' read -r events path; do
          printf 'remote|%s|%s\n' "$events" "$path" 1>&"$EVENT_FIFO_FD" 2> /dev/null || break
        done
      [[ $SHUTTING_DOWN == "true" ]] && break
      log_warn "remote inotify stream ended; reconnecting in 10s"
      sleep 10
    done
  ) &

  local pid=$!
  WATCHER_PIDS+=("$pid")
  log_info "remote inotify watcher started (pid $pid) on $REMOTE:$REMOTE_DIR"
}

# Remote watcher, poll flavour: just emit a tick every REMOTE_POLL_INTERVAL
# seconds and let the cycle's pull discover any remote change.
start_remote_poll_watcher() {
  (
    # Watcher subshells must not run cleanup() on exit — the parent owns
    # that responsibility (stopping watchers, removing FIFOs, etc.).
    trap - EXIT
    while [[ $SHUTTING_DOWN != "true" ]]; do
      sleep "$REMOTE_POLL_INTERVAL"
      [[ $SHUTTING_DOWN == "true" ]] && break
      printf 'poll|TIMER|remote\n' 1>&"$EVENT_FIFO_FD" 2> /dev/null || break
    done
  ) &

  local pid=$!
  WATCHER_PIDS+=("$pid")
  log_info "remote poll watcher started (pid $pid, every ${REMOTE_POLL_INTERVAL}s)"
}

start_remote_watcher() {
  if [[ $REMOTE_WATCH == "inotify" ]]; then
    if remote_has_inotifywait; then
      start_remote_inotify_watcher
      return 0
    fi
    log_warn "REMOTE_WATCH=inotify but inotifywait is not on the remote."
    log_warn 'Install it there (e.g. sudo apt install inotify-tools), or set REMOTE_WATCH="poll".'
    log_warn "Falling back to polling."
  fi
  start_remote_poll_watcher
}

# Safety-net timer: a periodic full sync catches anything the watchers missed
# (inotify queue overflow on a busy tree, events during a dropped connection).
start_periodic_watcher() {
  ((PERIODIC_FULL_SYNC == 0)) && {
    log_debug "periodic full sync disabled"
    return 0
  }

  (
    # Watcher subshells must not run cleanup() on exit — the parent owns
    # that responsibility (stopping watchers, removing FIFOs, etc.).
    trap - EXIT
    # Use a dedicated pipe for the timer instead of sleep, so the subshell
    # can be killed instantly: read -t is interruptible by signals, whereas
    # foreground sleep blocks until it finishes even on kill -9.
    local timer_pipe
    timer_pipe=$(mktemp -u)
    mkfifo -m 600 "$timer_pipe"
    exec {timer_fd}<> "$timer_pipe"
    while [[ $SHUTTING_DOWN != "true" ]]; do
      if ! read -r -t "$PERIODIC_FULL_SYNC" -u "$timer_fd" 2> /dev/null; then
        # Timeout expired — time for a periodic full sync.
        printf 'periodic|TIMER|full\n' 1>&"$EVENT_FIFO_FD" 2> /dev/null || break
      fi
    done
    exec {timer_fd}>&-
    rm -f "$timer_pipe"
  ) &

  local pid=$!
  WATCHER_PIDS+=("$pid")
  log_info "periodic full-sync watcher started (pid $pid, every ${PERIODIC_FULL_SYNC}s)"
}

# Saving one file in an editor typically produces several inotify events
# (create temp, write, rename, attrib). Syncing per event would mean several
# redundant rsync runs per keystroke-save.
#
# So events are coalesced: after an event arrives, wait for DEBOUNCE_SECONDS
# of quiet before syncing. Any event during that window restarts the timer, so
# a burst becomes exactly one cycle. `read -t` provides the timeout.
watch_loop() {
  # A FIFO (not a plain file) is used so the watchers block on write and the
  # reader blocks on read -- no polling, no lost events, no growing spool file.
  EVENT_FIFO="$STATE_DIR/events.fifo"
  rm -f "$EVENT_FIFO"
  mkfifo -m 600 "$EVENT_FIFO" || die "$EX_CONFIG" "cannot create the event FIFO: $EVENT_FIFO"

  # Hold the FIFO open read-write for the whole run. Without this the reader
  # would see EOF every time the last writer closed, and the loop would spin.
  exec {fifo_fd}<> "$EVENT_FIFO"
  EVENT_FIFO_FD=$fifo_fd

  start_local_watcher
  start_remote_watcher
  start_periodic_watcher

  # Give the watchers a moment to attach before the initial sync, so changes
  # made during startup are not missed.
  sleep 1

  log_ok "watching for changes -- press Ctrl-C to stop"

  # Initial reconciliation so both sides start from a known state.
  sync_cycle_locked "startup" || log_warn "the startup sync reported problems"

  local pending="false" trigger="" line
  while true; do
    if [[ $pending == "true" ]]; then
      # In a burst: wait only DEBOUNCE_SECONDS for the next event. A timeout
      # means the burst has ended, so sync now.
      if read -r -t "$DEBOUNCE_SECONDS" -u "$fifo_fd" line; then
        log_debug "event during debounce: $line"
        continue # restart the quiet period
      fi
      pending="false"
      sync_cycle_locked "$trigger" || log_warn "sync cycle reported problems"
      trigger=""
    else
      # Idle: block indefinitely for the next event.
      if read -r -u "$fifo_fd" line; then
        local source="${line%%|*}"
        log_debug "event: $line"

        case "$source" in
          poll | periodic)
            # Timer ticks need no debouncing.
            sync_cycle_locked "$source" || log_warn "sync cycle reported problems"
            ;;
          *)
            pending="true"
            trigger="$source"
            ;;
        esac
      fi
    fi
  done
}
