#!/usr/bin/env bash
# =============================================================================
#  lib/state.sh -- State (class-diagram.md)
# =============================================================================
#  .sync/ holds the log, lock, delete journal, trash and conflict snapshots.
#  It lives inside the synced root for locality, and is unconditionally
#  excluded from transfer and protected from deletion.
#
#  The sentinel (.sync/.sync-root) exists to catch the classic mirror
#  disaster: an unmounted drive or mistyped path looks like an empty
#  directory, and --delete faithfully replicates that emptiness. Requiring a
#  marker on both sides means "empty and unmarked" is refused, not mirrored.
# =============================================================================

init_state_dir() {
  local -a dirs=(
    "$STATE_DIR"
    "$STATE_DIR/trash"
    "$STATE_DIR/conflicts"
  )
  [[ $PARTIAL_TRANSFERS == "true" ]] && dirs+=("$STATE_DIR/partial")

  local d
  for d in "${dirs[@]}"; do
    mkdir -p "$d" || die "$EX_CONFIG" "cannot create state directory: $d"
  done

  chmod 700 "$STATE_DIR" 2> /dev/null || true

  # ControlMaster socket lives under a short base dir to avoid
  # "unix_listener: path too long" errors; keep it private as well.
  mkdir -p "$(dirname "$SSH_CONTROL_PATH")" || true
  chmod 700 "$(dirname "$SSH_CONTROL_PATH")" 2> /dev/null || true

  touch "$LOG_PATH" 2> /dev/null || die "$EX_CONFIG" "cannot write log file: $LOG_PATH"
  touch "$DELETE_JOURNAL" 2> /dev/null || true

  rotate_log_if_needed
}

# True when this root has synced successfully at least once.
local_sentinel_exists() { [[ -f $SENTINEL_PATH ]]; }

write_local_sentinel() {
  {
    echo "# rsync-live-mirror sync root marker -- do not delete"
    echo "# Removing this file makes sync.sh refuse to run (REQUIRE_SENTINEL)."
    echo "created=$(date -Iseconds)"
    echo "host=$(hostname 2> /dev/null || echo unknown)"
    echo "local_dir=$LOCAL_DIR"
    echo "remote=${REMOTE:-<local>}"
    echo "remote_dir=$REMOTE_DIR"
  } > "$SENTINEL_PATH" 2> /dev/null || log_warn "could not write sentinel: $SENTINEL_PATH"
}

# Create the remote .sync/ and its sentinel. Uses ssh, or plain mkdir in
# local-to-local mode.
write_remote_sentinel() {
  local content
  content="# rsync-live-mirror sync root marker -- do not delete
created=$(date -Iseconds)
paired_local=$LOCAL_DIR"

  if [[ -z $REMOTE ]]; then
    mkdir -p "$REMOTE_DIR/$STATE_DIR_NAME" 2> /dev/null || return 1
    printf '%s\n' "$content" > "$REMOTE_DIR/$STATE_DIR_NAME/$SENTINEL_NAME" 2> /dev/null || return 1
    return 0
  fi

  # Single quotes around the remote path stop the remote shell from expanding
  # anything in it; embedded single quotes are escaped the standard way.
  local q_state
  q_state="$(shell_quote "$REMOTE_DIR/$STATE_DIR_NAME")"
  printf '%s\n' "$content" |
    ssh_cmd "mkdir -p $q_state && cat > $q_state/$SENTINEL_NAME" 2> /dev/null || return 1
  return 0
}

remote_sentinel_exists() {
  if [[ -z $REMOTE ]]; then
    [[ -f "$REMOTE_DIR/$STATE_DIR_NAME/$SENTINEL_NAME" ]]
    return $?
  fi
  local q
  q="$(shell_quote "$REMOTE_DIR/$STATE_DIR_NAME/$SENTINEL_NAME")"
  ssh_cmd "test -f $q" > /dev/null 2>&1
}

# Wrap a string in single quotes for safe use in a remote shell command.
shell_quote() {
  local s="$1"
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

# The gate itself: both sides must be marked, or the run is refused.
check_sentinels() {
  [[ $REQUIRE_SENTINEL == "true" ]] || {
    log_debug "sentinel check disabled"
    return 0
  }

  local local_ok="false" remote_ok="false"
  local_sentinel_exists && local_ok="true"
  remote_sentinel_exists && remote_ok="true"

  # Both present: normal steady state.
  if [[ $local_ok == "true" && $remote_ok == "true" ]]; then
    log_debug "sentinels present on both sides"
    return 0
  fi

  # Neither present: a genuine first run. Establish both markers.
  if [[ $local_ok == "false" && $remote_ok == "false" ]]; then
    log_warn "no sentinel on either side -- treating this as FIRST RUN"
    if [[ $FORCE_FIRST_RUN != "true" && $DRY_RUN != "true" ]]; then
      log_error "First run refused without an explicit go-ahead."
      log_error "Preview it first:   $SCRIPT_NAME --dir '$LOCAL_DIR' --once --dry-run"
      log_error "Then commit to it:  $SCRIPT_NAME --dir '$LOCAL_DIR' --force-first-run"
      exit "$EX_SAFETY"
    fi
    if [[ $DRY_RUN == "true" ]]; then
      log_info "dry run: sentinels would be created on both sides"
      return 0
    fi
    write_local_sentinel
    write_remote_sentinel || log_warn "could not create the remote sentinel (continuing)"
    log_ok "sentinels created; this root is now registered"
    return 0
  fi

  # Exactly one side marked: the dangerous asymmetry. Either a path is wrong,
  # or a filesystem is not mounted, or the far side was wiped.
  local missing_side
  [[ $local_ok == "false" ]] && missing_side="LOCAL ($LOCAL_DIR)" || missing_side="REMOTE (${REMOTE:-local}:$REMOTE_DIR)"
  log_error "sentinel MISSING on the $missing_side side, but present on the other."
  log_error "This usually means one of:"
  log_error "  * the path is wrong in $CONF_NAME"
  log_error "  * a filesystem is not mounted, so the directory looks empty"
  log_error "  * that side's .sync/ was deleted"
  log_error "Syncing now could mirror an empty tree over real data, so it is refused."
  log_error "If the state is genuinely correct, re-register with --force-first-run"
  log_error "after removing the remaining sentinel."
  exit "$EX_SAFETY"
}
