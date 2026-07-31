#!/usr/bin/env bash
# =============================================================================
#  lib/validation.sh -- Validation (class-diagram.md)
# =============================================================================
#  Validates configuration, sync paths, and dependency availability. With
#  --delete active in both directions, a wrong path is destructive. These
#  checks run before any rsync and are the reason deletion cannot wander
#  outside the intended trees.
#
#  xxh128 and lz4 are compile-time options in rsync, so their presence is
#  verified against `rsync --version` rather than assumed. A distro build
#  without them would otherwise fail confusingly on the first transfer.
# =============================================================================

# Compare dotted versions without sort -V (absent on some minimal systems).
version_ge() {
  local have="$1" want="$2"
  local -a h w
  IFS='.' read -ra h <<< "$have"
  IFS='.' read -ra w <<< "$want"
  local i
  for i in 0 1 2; do
    local hv="${h[i]:-0}" wv="${w[i]:-0}"
    hv="${hv//[^0-9]/}"
    wv="${wv//[^0-9]/}"
    ((${hv:-0} > ${wv:-0})) && return 0
    ((${hv:-0} < ${wv:-0})) && return 1
  done
  return 0
}

check_dependencies() {
  local -a missing=()
  local cmd
  for cmd in rsync ssh flock realpath date stat; do
    command -v "$cmd" > /dev/null 2>&1 || missing+=("$cmd")
  done

  # inotifywait is only needed for continuous watching, not for --once/--check.
  if [[ $MODE == "watch" ]]; then
    command -v inotifywait > /dev/null 2>&1 || missing+=("inotifywait")
  fi

  if ((${#missing[@]})); then
    log_error "missing required commands: ${missing[*]}"
    log_error "on Debian/Ubuntu/Pop!_OS:  sudo apt install rsync openssh-client inotify-tools util-linux coreutils"
    exit "$EX_DEPS"
  fi

  # --- rsync version ---
  # NOTE: `... | head -1` would send SIGPIPE to rsync and, under `set -o
  # pipefail`, make the whole pipeline fail with 141. The version output is
  # captured once into a variable and parsed with pure-bash/awk instead.
  local rsync_caps rsync_ver
  rsync_caps="$(rsync --version 2> /dev/null)" || true
  rsync_ver="$(awk 'NR==1{print $3; exit}' <<< "$rsync_caps")"
  [[ -n $rsync_ver ]] || die "$EX_DEPS" "could not determine the rsync version"
  version_ge "$rsync_ver" "$RSYNC_MIN_VERSION" ||
    die "$EX_DEPS" "rsync $rsync_ver is too old; $RSYNC_MIN_VERSION+ is required for --checksum-choice/--compress-choice"
  log_debug "rsync $rsync_ver"

  # --- required algorithms ---
  # `rsync --version` prints a "Checksum list:" and a "Compress list:" line,
  # each followed by the supported algorithms. Both are checked because xxh128
  # and lz4 are compile-time features, not universal.
  local checksum_line compress_line
  checksum_line="$(awk '/Checksum list/{getline; print; exit}' <<< "$rsync_caps")"
  compress_line="$(awk '/Compress list/{getline; print; exit}' <<< "$rsync_caps")"

  if [[ $checksum_line != *xxh128* ]]; then
    log_error "this rsync build does not support the xxh128 checksum."
    log_error "available:${checksum_line:-  (none reported)}"
    log_error "Install an rsync built with xxhash, or change --checksum-choice in build_common_opts()."
    exit "$EX_DEPS"
  fi

  if [[ $compress_line != *lz4* ]]; then
    log_error "this rsync build does not support lz4 compression."
    log_error "available:${compress_line:-  (none reported)}"
    log_error "Install an rsync built with lz4, or change --compress-choice in build_common_opts()."
    exit "$EX_DEPS"
  fi

  log_debug "rsync supports xxh128 and lz4"
}

# Paths that must never be a sync root. Mirroring --delete onto any of these
# would damage the system.
readonly -a FORBIDDEN_PATHS=(
  "/" "/bin" "/boot" "/dev" "/etc" "/home" "/lib" "/lib32" "/lib64"
  "/media" "/mnt" "/opt" "/proc" "/root" "/run" "/sbin" "/srv" "/sys"
  "/tmp" "/usr" "/var"
)

# A sync root must be absolute, not a system directory, and at least two
# components deep -- "/data" alone is almost always a mistake, whereas
# "/data/project" is a deliberate choice.
validate_sync_path() {
  local path="$1" label="$2"

  [[ -n $path ]] || die "$EX_CONFIG" "$label is empty"
  [[ $path == /* ]] || die "$EX_CONFIG" "$label must be an absolute path, got: $path"
  [[ $path != *".."* ]] || die "$EX_CONFIG" "$label must not contain '..': $path"

  # Normalise away any trailing slashes for comparison.
  local norm="${path%/}"
  [[ -z $norm ]] && norm="/"

  local forbidden
  for forbidden in "${FORBIDDEN_PATHS[@]}"; do
    if [[ $norm == "$forbidden" ]]; then
      die "$EX_SAFETY" "$label points at the system directory '$norm'.
Syncing with --delete there could destroy the system. Choose a dedicated subdirectory."
    fi
  done

  # Depth check: "/x" has one component, "/x/y" has two.
  local depth
  depth="$(tr -cd '/' <<< "$norm" | wc -c)"
  if ((depth < 2)); then
    die "$EX_SAFETY" "$label ('$norm') is only one level below /.
That is dangerously broad for a --delete sync; use a nested directory such as '$norm/project'."
  fi

  log_debug "$label validated: $norm"
}

validate_config() {
  # --- required keys ---
  [[ -n $REMOTE_DIR ]] || die "$EX_CONFIG" "REMOTE_DIR is not set in $CONF_FILE"

  # --- local root ---
  # Never created automatically: an empty local root combined with a push
  # --delete would wipe the remote.
  [[ -d $LOCAL_DIR ]] || die "$EX_CONFIG" "local sync root does not exist: $LOCAL_DIR"
  validate_sync_path "$LOCAL_DIR" "local sync root"
  validate_sync_path "$REMOTE_DIR" "REMOTE_DIR"

  # Strip any trailing slash; the rsync calls add exactly one where needed.
  LOCAL_DIR="${LOCAL_DIR%/}"
  REMOTE_DIR="${REMOTE_DIR%/}"

  # --- local root must be readable and writable (pull writes into it) ---
  [[ -r $LOCAL_DIR ]] || die "$EX_CONFIG" "local sync root is not readable: $LOCAL_DIR"
  [[ -w $LOCAL_DIR ]] || die "$EX_CONFIG" "local sync root is not writable: $LOCAL_DIR"

  # --- enumerated values ---
  case "$DELETE_MODE" in
    both | pull | push | none) ;;
    *) die "$EX_CONFIG" "DELETE_MODE must be both|pull|push|none, got '$DELETE_MODE'" ;;
  esac
  case "$PULL_COMPARE" in
    checksum | quick) ;;
    *) die "$EX_CONFIG" "PULL_COMPARE must be checksum|quick, got '$PULL_COMPARE'" ;;
  esac
  case "$REMOTE_WATCH" in
    poll | inotify) ;;
    *) die "$EX_CONFIG" "REMOTE_WATCH must be poll|inotify, got '$REMOTE_WATCH'" ;;
  esac
  case "$LOG_LEVEL" in
    error | warn | info | debug) ;;
    *) die "$EX_CONFIG" "LOG_LEVEL must be error|warn|info|debug, got '$LOG_LEVEL'" ;;
  esac

  # --- booleans ---
  local bool_var
  for bool_var in CONFLICT_BACKUP DELETE_PUSH_UNSAFE TRASH_ENABLED SAFE_LINKS \
    PRESERVE_HARDLINKS REQUIRE_SENTINEL SSH_MULTIPLEXING \
    PARTIAL_TRANSFERS DRY_RUN PRESERVE_OWNER PRESERVE_GROUP; do
    local val="${!bool_var}"
    [[ $val == "true" || $val == "false" ]] ||
      die "$EX_CONFIG" "$bool_var must be true or false, got '$val'"
  done

  # --- numbers (MAX_DELETE additionally allows -1 for "unlimited") ---
  local num_var
  for num_var in TRASH_KEEP_DAYS REMOTE_POLL_INTERVAL DEBOUNCE_SECONDS \
    PERIODIC_FULL_SYNC MAX_CHANGES_PER_CYCLE RSYNC_TIMEOUT LOG_MAX_KB; do
    local nval="${!num_var}"
    [[ $nval =~ ^[0-9]+$ ]] ||
      die "$EX_CONFIG" "$num_var must be a non-negative integer, got '$nval'"
  done
  [[ $MAX_DELETE =~ ^(-1|[0-9]+)$ ]] ||
    die "$EX_CONFIG" "MAX_DELETE must be -1 or a non-negative integer, got '$MAX_DELETE'"

  # A debounce of 0 would fire a sync per inotify event; editors emit dozens
  # per save, so clamp to a sane floor.
  ((DEBOUNCE_SECONDS < 1)) && {
    DEBOUNCE_SECONDS=1
    log_warn "DEBOUNCE_SECONDS raised to 1"
  }
  ((REMOTE_POLL_INTERVAL < 5)) && {
    REMOTE_POLL_INTERVAL=5
    log_warn "REMOTE_POLL_INTERVAL raised to 5"
  }

  # --- ssh key ---
  if [[ -n $SSH_KEY ]]; then
    [[ $SSH_KEY == "~"* ]] && SSH_KEY="${HOME}${SSH_KEY#\~}"
    [[ -f $SSH_KEY ]] || die "$EX_CONFIG" "SSH_KEY not found: $SSH_KEY"
    [[ -r $SSH_KEY ]] || die "$EX_CONFIG" "SSH_KEY not readable: $SSH_KEY"
  fi

  # --- chown needs privilege on the remote ---
  if [[ -n $REMOTE_CHOWN && -z $REMOTE_RSYNC ]]; then
    log_warn "REMOTE_CHOWN='$REMOTE_CHOWN' usually needs root on the remote."
    log_warn "If pushes fail with 'chown failed', set REMOTE_RSYNC=\"sudo rsync\" in $CONF_NAME."
  fi

  # --- local-only mode ---
  if [[ -z $REMOTE ]]; then
    log_warn "REMOTE is empty: operating in LOCAL-TO-LOCAL mode (no ssh)."
    [[ -d $REMOTE_DIR ]] ||
      die "$EX_CONFIG" "local-to-local mode needs REMOTE_DIR to exist: $REMOTE_DIR"
    # Catch a root that contains, or is contained by, the other side --
    # rsync would recurse into its own destination.
    if [[ "$REMOTE_DIR/" == "$LOCAL_DIR/"* || "$LOCAL_DIR/" == "$REMOTE_DIR/"* ]]; then
      die "$EX_SAFETY" "LOCAL_DIR and REMOTE_DIR overlap:
  local  = $LOCAL_DIR
  remote = $REMOTE_DIR
Nested sync roots would recurse. Use two independent directories."
    fi
  fi

  log_debug "configuration validated"

}
