#!/usr/bin/env bash
# =============================================================================
#  lib/connection.sh -- Connection (class-diagram.md)
# =============================================================================
#  One ssh option set is built and shared by rsync (-e) and by the direct ssh
#  calls (sentinels, remote watching), so the transport behaves identically
#  everywhere.
#
#  ControlMaster matters here: an event-driven syncer opens many short-lived
#  rsync runs, and without a shared master socket each one pays a full
#  TCP + key-exchange + auth round trip.
# =============================================================================

# Emits the ssh options as separate words (one per line, for IFS=$'\n' arrays).
build_ssh_opts() {
  local -a opts=()

  [[ -n $REMOTE_PORT ]] && opts+=(-p "$REMOTE_PORT")
  [[ -n $SSH_KEY ]] && opts+=(-i "$SSH_KEY" -o "IdentitiesOnly=yes")

  if [[ $SSH_MULTIPLEXING == "true" ]]; then
    opts+=(
      -o "ControlMaster=auto"
      -o "ControlPath=$SSH_CONTROL_PATH"
      -o "ControlPersist=120"
    )
  fi

  # Detect a dead peer reasonably fast instead of hanging a sync cycle.
  opts+=(
    -o "ServerAliveInterval=15"
    -o "ServerAliveCountMax=3"
    -o "BatchMode=yes"  # never prompt; fail instead (unattended use)
    -o "Compression=no" # rsync does lz4 itself; double-compressing wastes CPU
  )

  ((${#SSH_EXTRA_OPTS[@]})) && opts+=("${SSH_EXTRA_OPTS[@]}")

  printf '%s\n' "${opts[@]}"
}

# The -e value for rsync: a single shell word list, so it is space-joined.
build_rsync_ssh_transport() {
  local -a opts=()
  mapfile -t opts < <(build_ssh_opts)
  # IFS is $'\n\t' globally (see rsync-live-mirror.sh), so "${opts[*]}"
  # would join on a newline rather than a space here. rsync's own -e parser
  # splits its argument on literal spaces only, so a newline-joined string
  # collapses into one glued argv element when it reaches ssh -- silently
  # dropping or mangling every -o option after the first. Force a space join
  # locally.
  local IFS=' '
  printf 'ssh %s' "${opts[*]}"
}

# Run a command on the remote (no-op wrapper in local-to-local mode).
ssh_cmd() {
  local remote_command="$1"
  if [[ -z $REMOTE ]]; then
    bash -c "$remote_command"
    return $?
  fi
  local -a opts=()
  mapfile -t opts < <(build_ssh_opts)
  ssh "${opts[@]}" "$REMOTE" '$remote_command'
}

# Verify we can reach the remote and that REMOTE_DIR is usable there.
check_connection() {
  if [[ -z $REMOTE ]]; then
    log_info "local-to-local mode: skipping the ssh check"
    [[ -d $REMOTE_DIR ]] || die "$EX_CONN" "target directory missing: $REMOTE_DIR"
    return 0
  fi

  log_info "testing ssh to $REMOTE ..."
  local -a opts=()
  mapfile -t opts < <(build_ssh_opts)

  # ConnectTimeout is added only here so a slow link cannot stall the check.
  if ! ssh "${opts[@]}" -o "ConnectTimeout=10" "$REMOTE" true 2> /dev/null; then
    log_error "cannot connect to '$REMOTE'."
    log_error "Checks: host reachable? key loaded (ssh-add -l)? BatchMode forbids prompts,"
    log_error "so password-only auth will fail -- set up key auth or an ssh-agent."
    log_error "Reproduce manually:  ssh $(
      IFS=' '
      echo "${opts[*]}"
    ) $REMOTE true"
    exit "$EX_CONN"
  fi
  log_debug "ssh connection ok"

  # REMOTE_DIR must exist and be writable; pushes and remote deletes need both.
  local q
  q="$(shell_quote "$REMOTE_DIR")"
  if ! ssh_cmd "test -d $q" 2> /dev/null; then
    log_error "REMOTE_DIR does not exist on $REMOTE: $REMOTE_DIR"
    log_error "Create it first:  ssh $REMOTE 'mkdir -p $REMOTE_DIR'"
    exit "$EX_CONN"
  fi
  if ! ssh_cmd "test -w $q" 2> /dev/null; then
    die "$EX_CONN" "REMOTE_DIR is not writable by this ssh user: $REMOTE_DIR"
  fi

  # Warn (do not fail) if the remote rsync lacks the algorithms we request:
  # rsync negotiates, so a mismatch degrades rather than breaks.
  local remote_caps
  if remote_caps="$(ssh_cmd "${REMOTE_RSYNC:-rsync} --version 2>/dev/null | head -20" 2> /dev/null)"; then
    grep -qi 'xxh128' <<< "$remote_caps" || log_warn "remote rsync may not support xxh128; rsync will negotiate a fallback"
    grep -qi 'lz4' <<< "$remote_caps" || log_warn "remote rsync may not support lz4; rsync will negotiate a fallback"
  else
    log_warn "could not query the remote rsync version"
  fi

}
