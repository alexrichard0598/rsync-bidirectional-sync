#!/usr/bin/env bash
# =============================================================================
#  lib/sync.sh -- Sync (class-diagram.md)
# =============================================================================
#  Core sync operations: pull, push, estimate changes, rsync execution,
#  endpoint construction, and the sync cycle itself.
#
#  Order in sync_cycle() is deliberate and load-bearing:
#
#    1. LOCAL DELETES   paths the watcher saw deleted locally are removed from
#                       the remote (inotify journal). FIRST, so the pull cannot
#                       re-download a file the user just deleted.
#    2. REMOTE DELETES  paths that vanished from the remote since the last cycle
#                       (snapshot diff) are removed locally. Also before the
#                       pull, so the push cannot re-upload them.
#    3. PULL            remote -> local. No --update, so the remote overwrites
#                       local differences: remote wins every conflict.
#    4. PUSH            local -> remote, with --update so a remote file that is
#                       newer can never be clobbered. New local files go up.
#    5. SNAPSHOT        the remote listing is recorded for the next cycle.
#
#  Neither direction uses a blanket --delete. Both use an explicit record of
#  what actually disappeared (snapshot for the remote, inotify journal for the
#  local side), because rsync alone cannot tell "newly created here" from
#  "deleted over there" -- and guessing wrong destroys data.
#
#  Pulling before pushing means that if the same file changed on both sides, the
#  local edit is overwritten (and archived under .sync/conflicts/) BEFORE the
#  push can send it up, so the local version never reaches the remote.
# =============================================================================

# Build the "[user@]host:path/" or "path/" endpoint string.
# The TRAILING SLASH is essential: "src/" copies the contents of src into the
# destination, whereas "src" would create "dest/src". Getting this wrong with
# --delete active would be destructive, so it is centralised here.
remote_endpoint() {
  if [[ -z $REMOTE ]]; then
    printf '%s/' "$REMOTE_DIR"
  else
    printf '%s:%s/' "$REMOTE" "$REMOTE_DIR"
  fi
}
local_endpoint() { printf '%s/' "$LOCAL_DIR"; }

# Count real changes in rsync's --itemize-changes output. Lines starting with
# ">f" / "<f" / "cd" etc. are changes; "." in the first two columns means
# "nothing changed but attributes", and deletions are reported as "*deleting".
count_itemized_changes() {
  local output="$1"
  # `grep -c` exits 1 when it matches nothing, which under `set -e` needs the
  # `|| true`. Using `|| echo 0` here would print a SECOND line ("0\n0") and
  # break the arithmetic contexts that consume this value.
  local n
  n="$(grep -cE '^([<>ch.*][fdLDS]|\*deleting)' <<< "$output" 2> /dev/null || true)"
  # Strip anything non-numeric (empty output, stray whitespace) and default to 0.
  n="${n//[^0-9]/}"
  printf '%s' "${n:-0}"
}

# One rsync invocation. Returns rsync's exit status; the caller decides how to
# treat it, since 24 and 25 are benign in this workflow.
run_rsync() {
  local label="$1" src="$2" dst="$3"
  shift 3
  local -a extra=("$@")

  local -a cmd=(rsync)
  local -a common=() filters=()
  mapfile -t common < <(build_common_opts)
  mapfile -t filters < <(build_filter_opts)

  cmd+=("${common[@]}" "${filters[@]}" "${extra[@]}" "$src" "$dst")

  log_debug "$label: ${cmd[*]}"

  local output status
  # `set -e` must not abort on a non-zero rsync status, hence the || capture.
  output="$("${cmd[@]}" 2>&1)" && status=0 || status=$?

  # Surface rsync's own output at debug level, or whenever it actually changed
  # something (so the log records what moved).
  if [[ -n $output ]]; then
    if [[ $LOG_LEVEL == "debug" || $DRY_RUN == "true" ]]; then
      printf '%s\n' "$output" >&2
    fi
  fi

  local changes
  changes="$(count_itemized_changes "$output")"

  case "$status" in
    0)
      if ((changes > 0)); then
        log_ok "$label: $changes change(s)"
      else
        log_debug "$label: already in sync"
      fi
      ;;
    24)
      # "Partial transfer due to vanished source files" -- normal when a build
      # or editor removes a temp file mid-run. Not an error.
      log_debug "$label: some source files vanished during transfer (rsync 24)"
      status=0
      ;;
    25)
      # --max-delete tripped. Deliberately loud: it usually means a wrong path
      # or an unmounted filesystem.
      log_error "$label: hit MAX_DELETE=$MAX_DELETE, remaining deletions were SKIPPED."
      log_error "Verify both paths are correct and mounted before raising the limit."
      ;;
    23)
      log_warn "$label: partial transfer, some files/attrs were not transferred (rsync 23)"
      log_warn "Usually permissions, or --owner/--group without privilege on the receiver."
      ;;
    *)
      log_error "$label: rsync failed with status $status"
      [[ -n $output ]] && printf '%s\n' "$output" >&2
      ;;
  esac

  # Record the change count so callers can read it after the fact.
  # shellcheck disable=SC2034  # consumed by callers/summaries, not here
  LAST_CHANGE_COUNT="$changes"
  return "$status"
}

# --- PULL: remote -> local, remote wins ------------------------------------
do_pull() {
  local -a opts=()
  mapfile -t opts < <(build_pull_opts)
  log_info "pull: ${REMOTE:-local}:$REMOTE_DIR -> $LOCAL_DIR"
  run_rsync "pull" "$(remote_endpoint)" "$(local_endpoint)" "${opts[@]}"
}

# --- PUSH: local -> remote, never clobbers newer remote files --------------
do_push() {
  local -a opts=()
  mapfile -t opts < <(build_push_opts)
  log_info "push: $LOCAL_DIR -> ${REMOTE:-local}:$REMOTE_DIR"
  run_rsync "push" "$(local_endpoint)" "$(remote_endpoint)" "${opts[@]}"
}

# Pre-flight change estimate, used by MAX_CHANGES_PER_CYCLE. Runs a dry-run
# of whichever direction(s) this cycle will actually perform, purely to
# count, before anything is actually modified.
#
# NOTE: this used to always dry-run the pull only, regardless of $DIRECTION.
# That meant --push-only cycles were never gated by MAX_CHANGES_PER_CYCLE at
# all (the wrong direction was measured), and --pull-only cycles paid for an
# extra, redundant dry-run pull. Both directions are now measured (only the
# ones this cycle will run) and summed.
estimate_changes() {
  ((MAX_CHANGES_PER_CYCLE == 0)) && return 0

  # Force --dry-run into the option set while counting.
  local saved_dry="$DRY_RUN"
  DRY_RUN="true"

  local -a common=() filters=()
  mapfile -t common < <(build_common_opts)
  mapfile -t filters < <(build_filter_opts)

  local out total=0
  if [[ $DIRECTION == "both" || $DIRECTION == "pull" ]]; then
    local -a popts=()
    mapfile -t popts < <(build_pull_opts)
    out="$(rsync "${common[@]}" "${filters[@]}" "${popts[@]}" \
      "$(remote_endpoint)" "$(local_endpoint)" 2> /dev/null)" || true
    ((total += $(count_itemized_changes "$out")))
  fi
  if [[ $DIRECTION == "both" || $DIRECTION == "push" ]]; then
    local -a pushopts=()
    mapfile -t pushopts < <(build_push_opts)
    out="$(rsync "${common[@]}" "${filters[@]}" "${pushopts[@]}" \
      "$(local_endpoint)" "$(remote_endpoint)" 2> /dev/null)" || true
    ((total += $(count_itemized_changes "$out")))
  fi

  DRY_RUN="$saved_dry"

  if ((total > MAX_CHANGES_PER_CYCLE)); then
    log_error "this cycle would change $total files, over MAX_CHANGES_PER_CYCLE=$MAX_CHANGES_PER_CYCLE."
    log_error "Refusing to proceed. Inspect with: $SCRIPT_NAME --dir '$LOCAL_DIR' --once --dry-run"
    return 1
  fi
  log_debug "change estimate: $total"
  return 0
}

sync_cycle() {
  local reason="${1:-manual}"
  local rc=0

  # Fresh timestamp per cycle so trash/conflict snapshots stay distinguishable.
  RUN_TS="$(date '+%Y%m%d-%H%M%S')"

  log_info "--- sync cycle start (trigger: $reason) ---"
  [[ $DRY_RUN == "true" ]] && log_warn "DRY RUN: nothing will be modified"

  rotate_log_if_needed

  # Safety gate: refuse an implausibly large cycle.
  if ! estimate_changes; then
    log_error "cycle aborted by the MAX_CHANGES_PER_CYCLE gate"
    return "$EX_SAFETY"
  fi

  # --- 1. Local deletions -> remote (inotify journal) ---
  # MUST run before the pull. If it ran afterwards, the pull would see the file
  # still present on the remote, re-download the copy the user just deleted, and
  # then the journal step would find it "exists again locally" and skip it -- so
  # the deletion would silently undo itself every cycle.
  if [[ $DIRECTION == "both" || $DIRECTION == "push" ]]; then
    if [[ $MODE == "watch" || -s $DELETE_JOURNAL ]]; then
      apply_journaled_deletes || log_warn "journaled deletions incomplete"
    fi
  fi

  # --- 2. Remote deletions -> local (snapshot diff, not a blanket --delete) ---
  # Also before the pull, so a file deleted remotely is removed locally instead
  # of being re-uploaded by the push later in this same cycle.
  if [[ $DIRECTION == "both" || $DIRECTION == "pull" ]]; then
    apply_remote_deletions || log_warn "pull-side deletions incomplete"
  fi

  # --- 3. PULL (remote authoritative) ---
  if [[ $DIRECTION == "both" || $DIRECTION == "pull" ]]; then
    if ! do_pull; then
      rc=$?
      # 25 (max-delete) is reported but does not abort the push: the transfer
      # itself succeeded, only deletions were curtailed.
      if ((rc != 25)); then
        log_error "pull failed (status $rc); skipping the push to avoid acting on a partial state"
        log_info "--- sync cycle end (failed) ---"
        return "$EX_RSYNC"
      fi
    fi
  fi

  # --- 3. PUSH (never clobbers a newer remote file) ---
  if [[ $DIRECTION == "both" || $DIRECTION == "push" ]]; then
    if ! do_push; then
      rc=$?
      ((rc != 25)) && log_error "push failed (status $rc)"
    fi
  fi

  # --- 4. Opt-in blanket delete on push (one-shot mirror mode only) ---
  # The journal already ran as step 1. This is the explicitly-unsafe escape
  # hatch for "make the remote exactly match local", with no journal to consult:
  # it cannot distinguish a new remote file from a local deletion.
  if [[ $DIRECTION == "both" || $DIRECTION == "push" ]]; then
    if [[ $MODE != "watch" && $DELETE_PUSH_UNSAFE == "true" ]]; then
      log_warn "DELETE_PUSH_UNSAFE: applying a blanket --delete on push"
      local -a popts=()
      mapfile -t popts < <(build_push_opts)
      popts+=(--delete-after)
      ((MAX_DELETE >= 0)) && popts+=(--max-delete="$MAX_DELETE")
      run_rsync "push-delete" "$(local_endpoint)" "$(remote_endpoint)" "${popts[@]}" || true
    elif [[ $MODE != "watch" ]]; then
      log_debug "one-shot run: push-side deletion limited to the journal"
    fi
  fi

  # --- 5. Record the converged remote state for the next cycle's diff ---
  update_remote_snapshot

  prune_old_snapshots

  # First successful cycle registers the sentinels.
  if [[ $DRY_RUN != "true" ]] && ! local_sentinel_exists; then
    write_local_sentinel
    write_remote_sentinel || true
  fi

  log_info "--- sync cycle end ---"
  return 0
}

# Serialise cycles with flock. inotify bursts and the poll timer can both fire
# at once; two concurrent rsyncs over the same tree would race (and could
# double-apply deletions), so only one cycle runs at a time.
sync_cycle_locked() {
  local reason="${1:-manual}"

  exec {lock_fd}> "$LOCK_FILE" || {
    log_error "cannot open lock file: $LOCK_FILE"
    return 1
  }

  # Non-blocking: if a cycle is already running, the trigger is dropped rather
  # than queued. The event that caused it will be covered by the running cycle
  # or by the next one, so no change is lost.
  if ! flock -n "$lock_fd"; then
    log_debug "a sync is already running; skipping this trigger ($reason)"
    exec {lock_fd}>&-
    return 0
  fi

  # Pause watchers before sync to prevent stale events from triggering cycles
  pause_watchers

  local rc=0
  sync_cycle "$reason" || rc=$?

  # Resume watchers and drain any events accumulated while paused
  resume_watchers

  exec {lock_fd}>&-
  return "$rc"
}
