#!/usr/bin/env bash
# =============================================================================
#  lib/snapshot.sh -- Snapshot (class-diagram.md)
# =============================================================================
#  Snapshot-driven deletion for the PULL direction, plus trash/conflict
#  pruning and the push-side journal.
#
#  Why a snapshot is needed:
#    A plain --delete on the pull removes anything present locally but absent
#    remotely -- which includes files the user just created locally and has not
#    pushed yet. rsync cannot distinguish "new on the local side" from "deleted
#    on the remote side".
#
#  How it works:
#    After every successful cycle a sorted list of remote paths is written to
#    .sync/remote-snapshot. On the next cycle the current remote listing is
#    compared against it: a path in the snapshot but no longer on the remote was
#    genuinely DELETED remotely, so it is removed locally. A path that only
#    exists locally and was never in the snapshot is simply new, and is left
#    alone for the push to upload.
#
#  Snapshot record format:
#    Each line is "path<TAB>size<TAB>xxh128<TAB>mtime" — one remote path
#    per record, not just a bare path. The size/hash let deletion-detection
#    tell "the path is genuinely gone" apart from "the path is still there
#    but its content changed": comparisons against this file MUST be done
#    on the path field only, never on whole records (see the comment in
#    apply_remote_deletions() -- comparing whole records would make an
#    ordinary remote edit look like a deletion, since the hash column would
#    differ). The mtime field (epoch seconds from rsync %T) lets move/
#    rename detection distinguish "file was just moved" from "file was
#    deleted and a new one appeared". The extra fields also lay the
#    groundwork for matching a MOVED_FROM/MOVED_TO pair by content instead
#    of by name.
#
#  Journal-driven deletion for the push direction.
#
#  Why not a plain --delete on push?
#    rsync compares two trees; it cannot distinguish "new here" from "deleted
#    there" -- both appear as "present on one side only". A blanket --delete on
#    push would therefore delete every file newly created on the REMOTE, and a
#    blanket --delete on pull would delete every file newly created LOCALLY.
#
#  What happens instead:
#    The inotify watcher appends every local delete / move-out to
#    .sync/pending-deletes. The push then removes exactly those paths from the
#    remote and nothing else, so genuinely new remote files always survive.
#
#  Deletion is performed with a targeted `rm` over ssh rather than rsync,
#  because rsync has no "delete just these paths" mode. Every path is
#  re-validated against the tree before use.
# =============================================================================

# Delete trash/conflict snapshots older than TRASH_KEEP_DAYS.
prune_old_snapshots() {
  ((TRASH_KEEP_DAYS == 0)) && return 0
  local base
  for base in "$STATE_DIR/trash" "$STATE_DIR/conflicts"; do
    [[ -d $base ]] || continue
    # -mindepth 1 -maxdepth 1: only the timestamped snapshot dirs themselves.
    find "$base" -mindepth 1 -maxdepth 1 -type d -mtime "+$TRASH_KEEP_DAYS" \
      -exec rm -rf {} + 2> /dev/null || true
  done
  log_debug "pruned snapshots older than ${TRASH_KEEP_DAYS}d"
}

# Emits one TAB-separated record per remote path: "path<TAB>size<TAB>xxh128<TAB>mtime".
# Honours the same excludes as the transfer, since filter rules are shared
# with build_filter_opts(). --list-only is deliberately NOT used: it ignores
# --out-format and prints an ls-style long listing ("perms size date time
# path -> target"), which is fragile to parse for names containing spaces or
# " -> ". A --dry-run against an empty scratch destination with a custom
# --out-format prints one record per line instead.
list_remote_paths() {
  local -a filters=()
  mapfile -t filters < <(build_filter_opts)

  # A MINIMAL option set is used on purpose. build_common_opts() adds
  # --itemize-changes (and possibly --verbose), which changes the output
  # format. Only what is needed to enumerate the tree the same way a real
  # transfer would see is passed: recursion, symlinks-as-symlinks, the
  # identical filter rules -- plus --checksum, added so the hash column
  # below is actually populated.
  #
  # --checksum is REQUIRED, not optional: without it rsync's quick check
  # (size+mtime) decides what "changed" means and the checksum field is left
  # blank, since no full-file comparison ever happens. Against the
  # always-empty scratch destination every path is a "transfer candidate"
  # either way, so this does not change which paths get listed -- only
  # whether a real xxh128 gets computed for each one. That computation is a
  # full read of every remote file, every time this runs (twice per
  # pull-enabled cycle: apply_remote_deletions() and update_remote_snapshot()),
  # on top of the read PULL_COMPARE="checksum" already performs for do_pull()
  # itself. See issues-discovered-by-qwen.md for the tradeoff.
  local out_format
  out_format=$'%n\t%l\t%C\t%T'
  local -a opts=(--recursive --links --dry-run --checksum \
    --checksum-choice=xxh128 --out-format="$out_format")
  [[ $SAFE_LINKS == "true" ]] && opts+=(--safe-links)
  ((RSYNC_TIMEOUT > 0)) && opts+=(--timeout="$RSYNC_TIMEOUT")
  if [[ -n $REMOTE ]]; then
    opts+=(-e "$(build_rsync_ssh_transport)")
    [[ -n $REMOTE_RSYNC ]] && opts+=(--rsync-path="$REMOTE_RSYNC")
  fi

  # The scratch destination is only ever read as a name: --dry-run guarantees
  # nothing is created or written there.
  local scratch="$STATE_DIR/.listing-scratch"

  # Directories arrive with a trailing slash and the tree root as "./" -- both
  # are normalised away on the PATH FIELD ONLY, leaving the size/hash/mtime
  # fields untouched, so the result is a plain sorted list of
  # "path<TAB>size<TAB>hash<TAB>mtime" records. Non-regular entries (directories,
  # symlinks) get an empty or all-zero hash from rsync; that is fine, since
  # they are only ever matched by path, never by hash.
  rsync "${opts[@]}" "${filters[@]}" "$(remote_endpoint)" "$scratch/" 2> /dev/null |
    awk -F'\t' 'BEGIN { OFS="\t" }
      {
        name = $1
        sub(/\/$/, "", name)
        if (name == "" || name == ".") next
        print name, $2, $3, $4
      }' |
    LC_ALL=C sort -u
}

# Compare the previous remote snapshot with the current listing and remove
# locally only what genuinely disappeared from the remote.
apply_remote_deletions() {
  [[ $DELETE_MODE == "both" || $DELETE_MODE == "pull" ]] || return 0

  local snapshot="$STATE_DIR/remote-snapshot"
  local current
  current="$(mktemp "$STATE_DIR/.remote-list.XXXXXX")" || return 0

  if ! list_remote_paths > "$current"; then
    log_warn "could not list the remote tree; skipping pull-side deletions"
    rm -f "$current"
    return 0
  fi

  # No snapshot yet (first run): record the baseline and delete nothing.
  if [[ ! -f $snapshot ]]; then
    [[ $DRY_RUN == "true" ]] || mv -f "$current" "$snapshot"
    rm -f "$current" 2> /dev/null || true
    log_debug "remote snapshot initialised; no pull-side deletions on a first run"
    return 0
  fi

  # Paths that were in the snapshot but are gone from the remote now.
  #
  # Compared on the PATH FIELD ONLY, never on whole "path<TAB>size<TAB>hash"
  # records: a file whose content changed keeps the same path but gets a new
  # hash, so a whole-record comm(1) would see the old record "vanish" and
  # delete a file locally on every ordinary remote edit. cut -f1 reduces
  # each side to bare paths before diffing, which is what keeps this a pure
  # existence check.
  local -a vanished=()
  mapfile -t vanished < <(
    LC_ALL=C comm -23 \
      <(cut -f1 "$snapshot" | LC_ALL=C sort -u) \
      <(cut -f1 "$current" | LC_ALL=C sort -u)
  )

  # --- Move/rename detection ------------------------------------------------
  # If a file's content hash (xxh128) disappears from Path A but appears at
  # Path B in the same cycle, treat it as a MOVE rather than DELETE + CREATE.
  #
  # Strategy:
  #   1. Build hash -> path maps from (a) vanished paths in the old snapshot
  #      and (b) "new" paths in the current listing that weren't in the old
  #      snapshot.
  #   2. Cross-reference: vanished.hash == new.hash => same content, different
  #      name => rename local file to track the new location.
  #   3. Vanished paths NOT matched as moves proceed as genuine deletions.

  # Hashes of paths that vanished (path -> content_hash from old snapshot).
  # Snapshot format: path<TAB>size<TAB>xxh128<TAB>mtime
  # We need field 3 (xxh128 hash); field 2 is size, field 4 is mtime.
  local -A old_hash_map=()
  local path_v _size_v hash_v _mtime_v
  while IFS=$'\t' read -r path_v _size_v hash_v _mtime_v; do
    old_hash_map["$path_v"]="$hash_v"
  done < "$snapshot"

  # Hashes of "newly appeared" paths (in current listing but not in old snapshot).
  local new_paths_file
  new_paths_file="$(mktemp)"
  LC_ALL=C comm -13 \
    <(cut -f1 "$snapshot" | LC_ALL=C sort -u) \
    <(cut -f1 "$current"  | LC_ALL=C sort -u) > "$new_paths_file"

  local -A new_hash_map=()
  local path_c _size_c hash_c mtime_c
  while IFS=$'\t' read -r path_c _size_c hash_c mtime_c; do
    [[ -n "${new_hash_map["$hash_c"]+x}" ]] && continue # first match wins
    new_hash_map["$hash_c"]="$path_c"
  done < "$current"
  rm -f "$new_paths_file"

  # Detect moves: vanished hash present in new-path hashes.
  local -A moved_to=()   # old_path -> new_path
  local old_path new_path vanish_hash
  for vanish_hash in "${!old_hash_map[@]}"; do
    old_path="${old_hash_map["$vanish_hash"]}"
    new_path="${new_hash_map["$vanish_hash"]:-}"
    [[ -n $new_path ]] || continue

    # Containment guard for both sides of the rename.
    [[ $old_path == /* || $old_path == *".."* ]] && continue
    [[ $new_path == /* || $new_path == *".."* ]] && continue
    [[ $old_path == "$STATE_DIR_NAME"* || $old_path == "$CONF_NAME" ]] && continue
    [[ $new_path == "$STATE_DIR_NAME"* || $new_path == "$CONF_NAME" ]] && continue

    if [[ -e "$LOCAL_DIR/$old_path" || -L "$LOCAL_DIR/$old_path" ]]; then
      if [[ $DRY_RUN == "true" ]]; then
        log_info "  would rename: $old_path -> $new_path (move detected on remote)"
      else
        mkdir -p "$(dirname -- "$LOCAL_DIR/$new_path")" 2>/dev/null || true
        mv -f "$LOCAL_DIR/$old_path" "$LOCAL_DIR/$new_path" 2>/dev/null ||
          log_warn "move detected $old_path -> $new_path but local rename failed"
        log_debug "move detected: $old_path -> $new_path (content hash $vanish_hash)"
      fi
      moved_to["$old_path"]="$new_path"
    fi
  done

  # Paths NOT detected as moves are genuine deletions.
  local -a to_delete=()
  local rel
  for rel in "${vanished[@]}"; do
    [[ -z $rel ]] && continue
    # Containment: never act on absolute paths, traversal, or our own state.
    [[ $rel == /* || $rel == *".."* ]] && continue
    [[ $rel == "$STATE_DIR_NAME"* || $rel == "$CONF_NAME" ]] && continue
    # Only delete if it still exists locally (may have been renamed above).
    [[ -e "$LOCAL_DIR/$rel" || -L "$LOCAL_DIR/$rel" ]] || continue
    to_delete+=("$rel")
  done

  if ((${#to_delete[@]} == 0)); then
    [[ $DRY_RUN == "true" ]] || mv -f "$current" "$snapshot"
    rm -f "$current" 2> /dev/null || true
    log_debug "no remote deletions to apply"
    return 0
  fi

  # Deletion cap applies here too.
  if ((MAX_DELETE >= 0 && ${#to_delete[@]} > MAX_DELETE)); then
    log_error "${#to_delete[@]} remote deletion(s) detected, over MAX_DELETE=$MAX_DELETE."
    log_error "Refusing to apply them. This often means the remote path is wrong or unmounted."
    rm -f "$current"
    return 1
  fi

  log_info "applying ${#to_delete[@]} remote deletion(s) locally"

  if [[ $DRY_RUN == "true" ]]; then
    printf '  would delete locally: %s\n' "${to_delete[@]}" >&2
    rm -f "$current"
    return 0
  fi

  local trash_dir="$STATE_DIR/trash/$RUN_TS"
  for rel in "${to_delete[@]}"; do
    if [[ $TRASH_ENABLED == "true" ]]; then
      mkdir -p "$trash_dir/$(dirname -- "$rel")" 2> /dev/null || true
      mv -f "$LOCAL_DIR/$rel" "$trash_dir/$rel" 2> /dev/null ||
        log_warn "could not move '$rel' to the trash"
    else
      # ${var:?} makes bash abort rather than expand to "/" if either variable
      # is somehow empty -- a last line of defence around a recursive delete.
      rm -rf -- "${LOCAL_DIR:?}/${rel:?}" 2> /dev/null || log_warn "could not delete '$rel'"
    fi
  done

  mv -f "$current" "$snapshot"
  log_ok "removed ${#to_delete[@]} path(s) locally (deleted on the remote)"
  return 0
}

# Refresh the snapshot at the end of a cycle, so the next cycle compares
# against the state the two sides actually converged on.
update_remote_snapshot() {
  [[ $DELETE_MODE == "both" || $DELETE_MODE == "pull" ]] || return 0
  [[ $DRY_RUN == "true" ]] && return 0
  local snapshot="$STATE_DIR/remote-snapshot"
  local tmp
  tmp="$(mktemp "$STATE_DIR/.remote-list.XXXXXX")" || return 0
  if list_remote_paths > "$tmp"; then
    mv -f "$tmp" "$snapshot"
    log_debug "remote snapshot updated ($(wc -l < "$snapshot") path(s))"
  else
    rm -f "$tmp"
  fi
  return 0
}

apply_journaled_deletes() {
  [[ $DELETE_MODE == "both" || $DELETE_MODE == "push" ]] || return 0
  [[ -s $DELETE_JOURNAL ]] || {
    log_debug "delete journal empty"
    return 0
  }

  # Read, then immediately truncate, so events arriving during this pass are
  # not lost and not double-applied.
  local -a paths=()
  mapfile -t paths < "$DELETE_JOURNAL"
  : > "$DELETE_JOURNAL"

  local -a valid=()
  local rel
  for rel in "${paths[@]}"; do
    [[ -z $rel ]] && continue

    # Containment re-check. The journal is a file on disk; treat it as
    # untrusted input. Reject absolute paths and any traversal attempt so a
    # corrupted or tampered journal cannot delete outside REMOTE_DIR.
    [[ $rel == /* ]] && {
      log_warn "journal: skipping absolute path '$rel'"
      continue
    }
    [[ $rel == *".."* ]] && {
      log_warn "journal: skipping traversal path '$rel'"
      continue
    }
    [[ $rel == "$STATE_DIR_NAME/"* ]] && continue # never touch .sync/
    [[ $rel == "$CONF_NAME" ]] && continue        # never touch sync.conf

    # If the path exists locally again it was recreated (a "delete" that was
    # really an editor's atomic save), so it must not be deleted remotely.
    if [[ -e "$LOCAL_DIR/$rel" ]]; then
      log_debug "journal: '$rel' exists again locally; not deleting remotely"
      continue
    fi

    valid+=("$rel")
  done

  ((${#valid[@]})) || {
    log_debug "no valid journaled deletions"
    return 0
  }

  # Respect the deletion cap here too.
  if ((MAX_DELETE >= 0 && ${#valid[@]} > MAX_DELETE)); then
    log_error "journal holds ${#valid[@]} deletions, over MAX_DELETE=$MAX_DELETE."
    log_error "Refusing to apply them; this often means a bulk local delete was unintended."
    log_error "Review .sync/pending-deletes, then raise MAX_DELETE or clear the journal."
    printf '%s\n' "${valid[@]}" >> "$DELETE_JOURNAL"
    return 1
  fi

  log_info "applying ${#valid[@]} local deletion(s) to the remote"

  if [[ $DRY_RUN == "true" ]]; then
    printf '  would delete remotely: %s\n' "${valid[@]}" >&2
    # Put them back so a later real run still applies them.
    printf '%s\n' "${valid[@]}" >> "$DELETE_JOURNAL"
    return 0
  fi

  # Build one remote command: move each path into the remote trash when the
  # bin is enabled, otherwise remove it outright. Paths are single-quoted.
  local remote_script
  remote_script="set -e; cd $(shell_quote "$REMOTE_DIR") || exit 1;"
  if [[ $TRASH_ENABLED == "true" ]]; then
    remote_script+=" mkdir -p $(shell_quote "$STATE_DIR_NAME/trash/$RUN_TS");"
  fi

  for rel in "${valid[@]}"; do
    local q
    q="$(shell_quote "$rel")"
    if [[ $TRASH_ENABLED == "true" ]]; then
      # --parents keeps the original directory layout inside the trash dir.
      remote_script+=" if [ -e $q ] || [ -L $q ]; then mkdir -p \"\$(dirname $(shell_quote "$STATE_DIR_NAME/trash/$RUN_TS/$rel"))\"; mv -f $q $(shell_quote "$STATE_DIR_NAME/trash/$RUN_TS/$rel") 2>/dev/null || true; fi;"
    else
      remote_script+=" rm -rf -- $q;"
    fi
  done

  if ssh_cmd "$remote_script" 2> /dev/null; then
    log_ok "removed ${#valid[@]} path(s) from the remote"
    return 0
  fi

  log_warn "some remote deletions failed; re-queueing them for the next cycle"

  printf '%s\n' "${valid[@]}" >> "$DELETE_JOURNAL"
  return 1
}
