#!/usr/bin/env bash
# =============================================================================
#  lib/controller.sh -- Controller (class-diagram.md)
# =============================================================================
#  Top-level orchestrator. Entry point, run mode dispatch, signal handling,
#  and shutdown/summary reporting.
# =============================================================================

cleanup() {
  local exit_code=$?
  [[ $SHUTTING_DOWN == "true" ]] && return
  SHUTTING_DOWN="true"

  # Terminate the watcher subshells and everything they spawned. The negative
  # PID targets the whole process group, which is what actually stops
  # inotifywait (a child of the subshell) rather than orphaning it.
  local pid
  for pid in "${WATCHER_PIDS[@]:-}"; do
    [[ -z $pid ]] && continue
    kill -TERM "-$pid" 2> /dev/null || kill -TERM "$pid" 2> /dev/null || true
  done

  # Reap them briefly, then insist.
  local waited=0
  while ((waited < 3)); do
    local alive="false"
    for pid in "${WATCHER_PIDS[@]:-}"; do
      [[ -z $pid ]] && continue
      kill -0 "$pid" 2> /dev/null && alive="true"
    done
    [[ $alive == "false" ]] && break
    sleep 1
    ((waited++))
  done
  for pid in "${WATCHER_PIDS[@]:-}"; do
    [[ -z $pid ]] && continue
    kill -KILL "-$pid" 2> /dev/null || kill -KILL "$pid" 2> /dev/null || true
  done

  # Close the shared ssh master so no socket is left behind.
  if [[ -n $REMOTE && $SSH_MULTIPLEXING == "true" ]]; then
    local -a opts=()
    mapfile -t opts < <(build_ssh_opts 2> /dev/null) || true
    ssh "${opts[@]}" -O exit "$REMOTE" 2> /dev/null || true
  fi

  [[ -n $EVENT_FIFO && -p $EVENT_FIFO ]] && rm -f "$EVENT_FIFO"
  [[ -n $STATE_DIR && -p "$STATE_DIR/inotify.raw" ]] && rm -f "$STATE_DIR/inotify.raw"

  # Deliberately NOT removed: .sync/pending-deletes (a journal that survives a
  # restart), the log, the trash and the conflict snapshots.

  if ((exit_code == 0)); then
    log_info "stopped cleanly"
  else
    log_warn "stopped with exit code $exit_code"
  fi
}

# INT/TERM exit 0: Ctrl-C is a normal way to stop a watcher, not a failure.
on_signal() {
  log_info "signal received, shutting down ..."
  exit 0
}

# cleanup runs on every exit path; on_signal turns a Ctrl-C into a clean stop.
trap cleanup EXIT
trap on_signal INT TERM

print_summary() {
  local delete_desc
  case "$DELETE_MODE" in
    both) delete_desc="both directions (push side is journal-driven)" ;;
    pull) delete_desc="remote -> local only" ;;
    push) delete_desc="local -> remote only (journal-driven)" ;;
    none) delete_desc="disabled" ;;
  esac

  cat >&2 << EOF

${C_GREEN}=== configuration ===${C_RESET}
  config file     $CONF_FILE
  local root      $LOCAL_DIR
  remote          ${REMOTE:-<local-to-local mode>}
  remote dir      $REMOTE_DIR
  state dir       $STATE_DIR

${C_GREEN}=== policy ===${C_RESET}
  conflicts       remote wins (pull runs first, without --update)
  conflict backup ${CONFLICT_BACKUP} -> .sync/conflicts/
  compare on pull ${PULL_COMPARE}
  deletions       ${delete_desc}
  max delete      ${MAX_DELETE}
  trash           ${TRASH_ENABLED} (keep ${TRASH_KEEP_DAYS}d)
  symlinks        copied as symlinks, never followed (safe-links=${SAFE_LINKS})

${C_GREEN}=== transfer ===${C_RESET}
  checksum        xxh128
  compression     lz4
  transport       $([[ -n $REMOTE ]] && echo "ssh (multiplexing=${SSH_MULTIPLEXING})" || echo "local filesystem")
  bandwidth cap   ${BWLIMIT:-unlimited}
  excludes        ${#EXCLUDES[@]} pattern(s)

${C_GREEN}=== watching ===${C_RESET}
  remote watch    ${REMOTE_WATCH}$([[ $REMOTE_WATCH == "poll" ]] && echo " (every ${REMOTE_POLL_INTERVAL}s)")
  debounce        ${DEBOUNCE_SECONDS}s
  periodic sync   $( ((PERIODIC_FULL_SYNC > 0)) && echo "every ${PERIODIC_FULL_SYNC}s" || echo "disabled")

EOF
}

run_check() {
  print_summary
  log_info "verifying dependencies and connectivity ..."
  check_connection

  # Report sentinel state without enforcing the gate, so --check is read-only.
  local l="missing" r="missing"
  local_sentinel_exists && l="present"
  remote_sentinel_exists && r="present"
  log_info "sentinel: local=$l remote=$r"

  if [[ $l == "missing" && $r == "missing" ]]; then
    log_warn "neither side is registered yet; the first real run needs --force-first-run"
    log_warn "(preview it first with --once --dry-run)"
  elif [[ $l != "$r" ]]; then
    log_error "sentinels are ASYMMETRIC -- a normal run would refuse to start."
    log_error "Check both paths in $CONF_NAME and that every filesystem is mounted."
    return "$EX_SAFETY"
  fi

  # Show what a cycle would do, without touching anything.
  log_info "counting pending changes (dry run) ..."
  local saved="$DRY_RUN"
  DRY_RUN="true"
  local -a common=() filters=() popts=()
  mapfile -t common < <(build_common_opts)
  mapfile -t filters < <(build_filter_opts)
  mapfile -t popts < <(build_pull_opts)
  local out
  out="$(rsync "${common[@]}" "${filters[@]}" "${popts[@]}" \
    "$(remote_endpoint)" "$(local_endpoint)" 2>&1)" || true
  DRY_RUN="$saved"
  log_info "pull would apply $(count_itemized_changes "$out") change(s)"

  log_ok "configuration looks good"
  return 0
}

main() {
  parse_args "$@"

  # Order matters: find the root -> load its config -> validate -> create state
  # -> check deps/connection -> enforce the sentinel gate -> run.
  resolve_config
  load_config
  check_dependencies
  validate_config
  init_state_dir

  log_info "$SCRIPT_NAME $SCRIPT_VERSION starting (mode: $MODE, direction: $DIRECTION)"
  log_debug "config: $CONF_FILE"

  case "$MODE" in
    check)
      run_check
      exit $?
      ;;
    once)
      check_connection
      check_sentinels
      sync_cycle_locked "once"
      local rc=$?
      if ((rc == 0)); then
        log_ok "single sync cycle complete"
        exit "$EX_OK"
      fi
      log_error "the sync cycle failed"
      exit "$rc"
      ;;
    watch)
      check_connection
      check_sentinels
      watch_loop # never returns; exits via the signal handler
      ;;
    *)
      die "$EX_CONFIG" "unknown mode: $MODE"
      ;;
  esac
}
