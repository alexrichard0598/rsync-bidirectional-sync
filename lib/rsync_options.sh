#!/usr/bin/env bash
# =============================================================================
#  lib/rsync_options.sh -- RsyncOptions (class-diagram.md)
# =============================================================================
#  THIS IS THE PLACE TO EDIT TRANSFER BEHAVIOUR.
#
#  build_common_opts()  flags shared by both directions
#  build_filter_opts()  the exclude/protect rules
#  build_pull_opts()    remote -> local  (remote wins, real --delete)
#  build_push_opts()    local -> remote  (--update, journal-driven deletes)
#
#  -a/--archive is deliberately NOT used. It is shorthand for -rlptgoD, which
#  hides exactly the symlink and ownership behaviour that matters here, so
#  every flag is listed explicitly instead.
# =============================================================================

build_common_opts() {
  local -a o=()

  # --- traversal and metadata ---
  o+=(--recursive)          # descend the tree
  o+=(--times)              # preserve mtimes (required for --update to work)
  o+=(--perms)              # preserve the permission bits
  o+=(--devices --specials) # device and fifo/socket nodes (needs privilege)
  o+=(--omit-link-times)    # do not try to set mtimes on symlinks; many
  # filesystems reject it and it only adds noise

  # --- SYMLINKS: copy them, never follow them ---
  # --links recreates each symlink as a symlink.
  # Deliberately absent:
  #   --copy-links (-L)        would replace links with their contents
  #   --copy-unsafe-links      would dereference links pointing outside
  #   --copy-dirlinks (-k)     would dereference symlinks to directories
  #   --keep-dirlinks (-K)     would let the receiver WRITE AND DELETE THROUGH
  #                            a symlinked directory, which is precisely how a
  #                            --delete could escape the sync tree
  o+=(--links)

  # Optional hardening: skip links pointing outside the tree (and all absolute
  # links). Off by default so ordinary symlinks replicate faithfully -- safe
  # because without --keep-dirlinks such a link is never traversed.
  [[ $SAFE_LINKS == "true" ]] && o+=(--safe-links)

  [[ $PRESERVE_HARDLINKS == "true" ]] && o+=(--hard-links)
  [[ $PRESERVE_GROUP == "true" ]] && o+=(--group)
  [[ $PRESERVE_OWNER == "true" ]] && o+=(--owner)

  # --- integrity: xxh128 ---
  # --checksum-choice selects the algorithm used for the whole-file comparison
  # (with --checksum) and for the delta-transfer block checks. xxh128 is far
  # faster than md5 at equal-or-better collision resistance for this purpose.
  o+=(--checksum-choice=xxh128)

  # --- compression: lz4 ---
  # lz4 is chosen for latency: it compresses fast enough not to become the
  # bottleneck on a fast link, unlike zlib/zstd at higher levels.
  o+=(--compress --compress-choice=lz4)

  # --- efficiency ---
  o+=(--sparse) # store holes efficiently (VM images, DBs)
  o+=(--human-readable)

  # Resume interrupted large files instead of restarting them. The partial dir
  # sits in .sync/ so half-written files never appear in the live tree.
  if [[ $PARTIAL_TRANSFERS == "true" ]]; then
    o+=(--partial --partial-dir="$STATE_DIR_NAME/partial")
  fi

  [[ -n $BWLIMIT ]] && o+=(--bwlimit="$BWLIMIT")
  ((RSYNC_TIMEOUT > 0)) && o+=(--timeout="$RSYNC_TIMEOUT")

  # --- transport ---
  if [[ -n $REMOTE ]]; then
    o+=(-e "$(build_rsync_ssh_transport)")
    [[ -n $REMOTE_RSYNC ]] && o+=(--rsync-path="$REMOTE_RSYNC")
  fi

  # --- reporting ---
  # --itemize-changes gives one parseable line per change, which is what the
  # change counting and dry-run summaries read.
  o+=(--itemize-changes)
  [[ $DRY_RUN == "true" ]] && o+=(--dry-run)
  [[ $LOG_LEVEL == "debug" ]] && o+=(--verbose)

  printf '%s\n' "${o[@]}"

  # Filter rules. Order is significant: rsync applies the FIRST matching rule,
}
# so protections and exclusions must precede anything broader.
build_filter_opts() {
  local -a o=()

  # 1. The state directory is never transferred, and -- crucially -- is
  #    PROTECTED from deletion on the receiver. Without the protect rule a
  #    --delete pass would remove the other side's .sync/ (its sentinel, its
  #    trash, its log) because the sender has no such path to justify it.
  o+=(--filter="protect /$STATE_DIR_NAME/")
  o+=(--filter="exclude /$STATE_DIR_NAME/")

  # 2. sync.conf itself stays local: it names this machine's remote, and each
  #    side legitimately has its own. Protected so it is never deleted either.
  o+=(--filter="protect /$CONF_NAME")
  o+=(--filter="exclude /$CONF_NAME")
  o+=(--filter="protect /sync.conf.example")
  o+=(--filter="exclude /sync.conf.example")

  # 3. User excludes. A "protect" rule is emitted alongside each one so an
  #    excluded file on the receiver is not deleted merely because the sender
  #    cannot see it.
  local pattern
  for pattern in "${EXCLUDES[@]}"; do
    [[ -z $pattern ]] && continue
    [[ $pattern == "#"* ]] && continue # allow commented entries

    # A leading "!" means re-include (rsync's "include" rule).
    if [[ $pattern == "!"* ]]; then
      o+=(--filter="include ${pattern#!}")
      continue
    fi

    o+=(--filter="protect $pattern")
    o+=(--filter="exclude $pattern")
  done

  printf '%s\n' "${o[@]}"
}

# ---------------------------------------------------------------------------
#  PULL: remote -> local. The remote is authoritative.
# ---------------------------------------------------------------------------
build_pull_opts() {
  local -a o=()

  # NO --update here. That omission IS the "remote wins" policy: any file that
  # differs is overwritten with the remote copy, regardless of which side has
  # the newer mtime.

  # Content-based comparison. Across two hosts mtime is unreliable (clock skew,
  # differing timestamp granularity), so conflicts are detected by xxh128
  # content hash rather than by timestamp.
  [[ $PULL_COMPARE == "checksum" ]] && o+=(--checksum)

  # Preserve the local copy that loses a conflict. --backup moves the existing
  # local file aside instead of overwriting it in place; combined with --delete
  # below it also captures files removed on the remote.
  if [[ $CONFLICT_BACKUP == "true" ]]; then
    o+=(--backup --backup-dir="$STATE_DIR/conflicts/$RUN_TS")
    # Without --suffix rsync appends "~"; the timestamped dir already
    # disambiguates, so keep the original filenames.
    o+=(--suffix=)
  fi

  # NOTE: no --delete here, deliberately.
  #
  # A blanket --delete on the pull would remove every file that exists only on
  # the local side -- which includes files the user just CREATED locally and
  # that have not been pushed yet. rsync cannot tell "new here" from "deleted
  # there"; both look like "present on one side only".
  #
  # Remote deletions are therefore detected by comparing the remote file list
  # against a snapshot of the previous cycle (see apply_remote_deletions), and
  # only genuinely-vanished paths are removed locally.
  if [[ $DELETE_MODE == "both" || $DELETE_MODE == "pull" ]]; then
    ((MAX_DELETE >= 0)) && o+=(--max-delete="$MAX_DELETE")
  fi

  printf '%s\n' "${o[@]}"
}

# ---------------------------------------------------------------------------
#  PUSH: local -> remote. Must never overwrite newer remote work.
# ---------------------------------------------------------------------------
build_push_opts() {
  local -a o=()

  # --update: skip any remote file whose mtime is newer than the local one.
  # This is the second half of "remote wins" -- even if the pull missed a
  # change (say it landed mid-cycle), the push still refuses to clobber it.
  o+=(--update)

  # Remote-side permissions and ownership, push direction only.
  [[ -n $REMOTE_CHMOD ]] && o+=(--chmod="$REMOTE_CHMOD")
  [[ -n $REMOTE_CHOWN ]] && o+=(--chown="$REMOTE_CHOWN")

  # Keep a recycle bin on the remote so a push-side delete is recoverable.
  if [[ $TRASH_ENABLED == "true" && ($DELETE_MODE == "both" || $DELETE_MODE == "push") ]]; then
    o+=(--backup --backup-dir="$STATE_DIR_NAME/trash/$RUN_TS")
    o+=(--suffix=)
  fi

  printf '%s\n' "${o[@]}"
}
