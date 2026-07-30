#!/usr/bin/env bash
# =============================================================================
#  sync.sh -- bidirectional rsync + inotify folder sync over ssh
# =============================================================================
#
#  WHAT IT DOES
#    Keeps a local directory and a remote directory continuously in sync,
#    reacting to filesystem events rather than polling on a fixed schedule.
#    Transfers run over ssh, hash with xxh128 and compress with lz4.
#
#  CONFIGURATION
#    Read from "sync.conf" IN THE ROOT OF THE LOCAL SYNCED FOLDER.
#    That file's directory is the local sync root, so there is no LOCAL_DIR
#    setting. See sync.conf.example for every option.
#
#    The root is located, in order:
#      1. --dir PATH
#      2. $RSYNC_SYNC_DIR
#      3. nearest ancestor of $PWD containing a sync.conf
#
#  CORE POLICIES
#    Conflicts    Remote wins. Each cycle pulls before pushing; the pull omits
#                 --update (remote overwrites local), the push includes it
#                 (a newer remote file is never clobbered). The losing local
#                 copy is preserved under .sync/conflicts/.
#
#    Deletions    Bidirectional, but asymmetric in mechanism. Pull uses a real
#                 --delete because the remote is authoritative. Push deletes
#                 only paths the inotify watcher actually saw removed locally
#                 (journal at .sync/pending-deletes), so a newly created local
#                 file is never mistaken for a remote deletion.
#
#    Symlinks     Copied as symlinks, never followed: --links is used and
#                 --copy-links/--copy-dirlinks/--keep-dirlinks are all omitted.
#                 Omitting --keep-dirlinks is also what keeps deletion inside
#                 the tree: a symlinked directory pointing outside is replaced
#                 in-tree instead of being descended into, so --delete can
#                 never reach its target.
#
#    Containment  Beyond the symlink rules: absolute-path and system-path
#                 checks, a required .sync/.sync-root sentinel on both sides,
#                 --max-delete, and a dry-run-gated first run.
#
#  LAYOUT OF .sync/ (inside the local root, never transferred)
#    sync.log            activity log
#    sync.lock           flock target serialising cycles
#    .sync-root          sentinel proving this is a real sync root
#    pending-deletes     journal of observed local deletions
#    trash/<ts>/         deleted files, when TRASH_ENABLED=true
#    conflicts/<ts>/     local files that lost a conflict
#    partial/            partial transfers, for resume
#    ssh-%C              ssh ControlMaster sockets
#
#  USAGE
#    ./sync.sh                     watch and sync continuously
#    ./sync.sh --once              one cycle, then exit (cron-friendly)
#    ./sync.sh --check             validate config and connectivity only
#    ./sync.sh --dry-run           show what would change, touch nothing
#    ./sync.sh --pull-only         remote -> local only
#    ./sync.sh --push-only         local -> remote only
#    ./sync.sh --dir /path         choose the sync root explicitly
#    ./sync.sh --help              full option list
#
#  EXIT CODES
#    0 ok   1 config/usage error   2 dependency missing   3 safety gate
#    4 connection failure          5 rsync failure
#
#  REQUIREMENTS
#    local:  bash 4+, rsync 3.1.3+ (xxh128 + lz4 support), ssh, inotifywait,
#            flock, realpath
#    remote: rsync with matching xxh128/lz4 support; inotify-tools only if
#            REMOTE_WATCH="inotify"
# =============================================================================

# Strict mode:
#   -E  ERR traps fire inside functions and subshells
#   -e  abort on unhandled command failure
#   -u  unset variable is an error, so a config typo fails loudly
#   -o pipefail  a pipeline fails if any stage fails, not just the last
set -Eeuo pipefail

# Stable, predictable environment regardless of the caller's locale/PATH.
export LC_ALL=C
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"

# Minimum rsync that supports --checksum-choice and --compress-choice.
readonly RSYNC_MIN_VERSION="3.1.3"

# --- exit codes -------------------------------------------------------------
readonly EX_OK=0
readonly EX_CONFIG=1
readonly EX_DEPS=2
readonly EX_SAFETY=3
readonly EX_CONN=4
readonly EX_RSYNC=5

# --- names inside the sync root --------------------------------------------
# The config lives in the synced folder itself, so these names are also the
# things that must never be transferred or deleted by a sync.
readonly CONF_NAME="sync.conf"
readonly STATE_DIR_NAME=".sync"
readonly SENTINEL_NAME=".sync-root"

# =============================================================================
#  SECTION 1 -- DEFAULTS
# =============================================================================
#  Every setting gets a default here so that (a) `set -u` can never trip on a
#  key the user's sync.conf omits, and (b) an old config keeps working when new
#  options are added. sync.conf overrides these; CLI flags override sync.conf.
# =============================================================================

# connection
REMOTE=""
REMOTE_DIR=""
REMOTE_PORT=""
SSH_KEY=""
SSH_EXTRA_OPTS=()

# excludes
EXCLUDES=()

# remote permissions
REMOTE_CHMOD=""
REMOTE_CHOWN=""
PRESERVE_OWNER="false"
PRESERVE_GROUP="true"
REMOTE_RSYNC=""

# conflicts
CONFLICT_BACKUP="true"
PULL_COMPARE="checksum"

# deletion
DELETE_MODE="both"
DELETE_PUSH_UNSAFE="false"
MAX_DELETE="100"
TRASH_ENABLED="true"
TRASH_KEEP_DAYS="14"

# symlinks
SAFE_LINKS="false"
PRESERVE_HARDLINKS="true"

# change detection
REMOTE_WATCH="poll"
REMOTE_POLL_INTERVAL="30"
DEBOUNCE_SECONDS="2"
PERIODIC_FULL_SYNC="300"

# safety
REQUIRE_SENTINEL="true"
MAX_CHANGES_PER_CYCLE="0"

# performance
BWLIMIT=""
SSH_MULTIPLEXING="true"
PARTIAL_TRANSFERS="true"
RSYNC_TIMEOUT="300"

# logging
LOG_FILE=".sync/sync.log"
LOG_LEVEL="info"
LOG_MAX_KB="5120"
DRY_RUN="false"

# --- runtime state (not user-configurable) ---------------------------------
LOCAL_DIR=""              # resolved sync root (dir containing sync.conf)
CONF_FILE=""              # resolved path to sync.conf
STATE_DIR=""              # $LOCAL_DIR/.sync
LOG_PATH=""               # absolute log path
LOCK_FILE=""              # flock target
SENTINEL_PATH=""          # local sentinel
DELETE_JOURNAL=""         # observed local deletions
SSH_CONTROL_PATH=""       # ControlMaster socket template

MODE="watch"              # watch | once | check
DIRECTION="both"          # both | pull | push
FORCE_FIRST_RUN="false"
VERBOSE="false"
CLI_DRY_RUN=""            # set by --dry-run, overrides config
CLI_DIR=""                # set by --dir

RUN_TS=""                 # timestamp for this run's trash/conflict dirs
WATCHER_PIDS=()           # background inotify/poll pids, killed on exit
EVENT_FIFO=""             # watcher -> main loop event channel
SHUTTING_DOWN="false"


# =============================================================================
#  SECTION 2 -- LOGGING
# =============================================================================
#  Messages go to stderr (so stdout stays clean for --dry-run output) and, once
#  the sync root is known, are appended to the log file. Before the root is
#  resolved LOG_PATH is empty and we log to the terminal only.
# =============================================================================

# Numeric severities, so LOG_LEVEL can gate output with a simple comparison.
_log_level_num() {
  case "$1" in
    error) echo 0 ;;
    warn)  echo 1 ;;
    info)  echo 2 ;;
    debug) echo 3 ;;
    *)     echo 2 ;;
  esac
}

# ANSI colour only when stderr is a terminal; keeps log files and pipes clean.
if [[ -t 2 ]]; then
  readonly C_RESET=$'\033[0m'
  readonly C_RED=$'\033[31m'
  readonly C_YELLOW=$'\033[33m'
  readonly C_BLUE=$'\033[34m'
  readonly C_GREY=$'\033[90m'
  readonly C_GREEN=$'\033[32m'
else
  readonly C_RESET="" C_RED="" C_YELLOW="" C_BLUE="" C_GREY="" C_GREEN=""
fi

_log() {
  local level="$1"; shift
  local msg="$*"

  # Drop anything more verbose than the configured level.
  (( $(_log_level_num "$level") > $(_log_level_num "$LOG_LEVEL") )) && return 0

  local ts colour
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  case "$level" in
    error) colour="$C_RED" ;;
    warn)  colour="$C_YELLOW" ;;
    info)  colour="$C_BLUE" ;;
    debug) colour="$C_GREY" ;;
    *)     colour="" ;;
  esac

  printf '%s%s [%-5s]%s %s\n' \
    "$colour" "$ts" "$level" "$C_RESET" "$msg" >&2

  # Plain (uncoloured) copy to the log file when we have one.
  if [[ -n "$LOG_PATH" && -w "${LOG_PATH%/*}" ]]; then
    printf '%s [%-5s] %s\n' "$ts" "$level" "$msg" >>"$LOG_PATH" 2>/dev/null || true
  fi
}

log_error() { _log error "$@"; }
log_warn()  { _log warn  "$@"; }
log_info()  { _log info  "$@"; }
log_debug() { _log debug "$@"; }

# Success line: always shown (it is an info-level event people look for).
log_ok() {
  printf '%s%s [ ok  ]%s %s\n' \
    "$C_GREEN" "$(date '+%Y-%m-%d %H:%M:%S')" "$C_RESET" "$*" >&2
  [[ -n "$LOG_PATH" && -w "${LOG_PATH%/*}" ]] &&
    printf '%s [ ok  ] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_PATH" 2>/dev/null || true
  return 0
}

# Log, then exit with a specific code.
die() {
  local code="$1"; shift
  log_error "$*"
  exit "$code"
}

# Truncate the log when it outgrows LOG_MAX_KB, keeping the newer half so
# recent history survives. Single generation, no external logrotate needed.
rotate_log_if_needed() {
  [[ -n "$LOG_PATH" && -f "$LOG_PATH" ]] || return 0
  [[ "$LOG_MAX_KB" =~ ^[0-9]+$ ]] || return 0
  (( LOG_MAX_KB == 0 )) && return 0

  local size_kb
  size_kb=$(( $(stat -c %s "$LOG_PATH" 2>/dev/null || echo 0) / 1024 ))
  if (( size_kb > LOG_MAX_KB )); then
    mv -f "$LOG_PATH" "${LOG_PATH}.1" 2>/dev/null || return 0
    : >"$LOG_PATH"
    log_info "log rotated at ${size_kb}KB (previous kept as ${LOG_PATH##*/}.1)"

  fi
}

# =============================================================================
#  SECTION 3 -- CLI
# =============================================================================

usage() {
  cat <<EOF
$SCRIPT_NAME $SCRIPT_VERSION -- bidirectional rsync + inotify sync over ssh

USAGE
  $SCRIPT_NAME [OPTIONS]

Configuration lives in "$CONF_NAME" in the root of the local synced folder.
That folder is found via --dir, then \$RSYNC_SYNC_DIR, then by searching up
from the current directory.

OPTIONS
  -d, --dir PATH        Local sync root (the folder holding $CONF_NAME)
  -c, --config PATH     Use this config file; its directory becomes the root
  -1, --once            Run a single sync cycle and exit (for cron/systemd)
      --check           Validate config, dependencies and connectivity, then exit
  -n, --dry-run         Report what would change without modifying anything
      --pull-only       Remote -> local only
      --push-only       Local -> remote only
      --force-first-run Permit the first real run without a prior dry-run
  -v, --verbose         Debug-level logging
  -q, --quiet           Errors only
  -h, --help            This help
  -V, --version         Version

EXAMPLES
  $SCRIPT_NAME --dir ~/project              # watch continuously
  $SCRIPT_NAME --dir ~/project --check      # verify setup
  $SCRIPT_NAME --dir ~/project --once -n    # preview one cycle
  cd ~/project && $SCRIPT_NAME              # root found automatically

POLICIES
  Conflicts  remote wins; the losing local copy is kept in .sync/conflicts/
  Deletions  both directions; push deletes only what the watcher observed
  Symlinks   copied as links, never followed
EOF
}

parse_args() {
  while (( $# )); do
    case "$1" in
      -d|--dir)
        [[ -n "${2:-}" ]] || die "$EX_CONFIG" "--dir requires a path"
        CLI_DIR="$2"; shift 2 ;;
      -c|--config)
        [[ -n "${2:-}" ]] || die "$EX_CONFIG" "--config requires a path"
        CONF_FILE="$2"; shift 2 ;;
      -1|--once)     MODE="once"; shift ;;
      --check)       MODE="check"; shift ;;
      -n|--dry-run)  CLI_DRY_RUN="true"; shift ;;
      --pull-only)   DIRECTION="pull"; shift ;;
      --push-only)   DIRECTION="push"; shift ;;
      --force-first-run) FORCE_FIRST_RUN="true"; shift ;;
      -v|--verbose)  VERBOSE="true"; LOG_LEVEL="debug"; shift ;;
      -q|--quiet)    LOG_LEVEL="error"; shift ;;
      -h|--help)     usage; exit "$EX_OK" ;;
      -V|--version)  printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit "$EX_OK" ;;
      --)            shift; break ;;
      -*)            usage >&2; die "$EX_CONFIG" "unknown option: $1" ;;
      *)             usage >&2; die "$EX_CONFIG" "unexpected argument: $1" ;;
    esac
  done

}

# =============================================================================
#  SECTION 4 -- LOCATING AND LOADING THE CONFIG
# =============================================================================
#  sync.conf lives inside the folder being synced, so the root must be found
#  before the config can be read. The root is then defined as the directory
#  containing that file -- which is why there is no LOCAL_DIR setting.
# =============================================================================

# Walk up from a starting directory looking for sync.conf. Stops at / so a
# stray config in $HOME cannot be picked up from an unrelated deep path.
find_config_upward() {
  local dir="$1"
  dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  while [[ -n "$dir" && "$dir" != "/" ]]; do
    if [[ -f "$dir/$CONF_NAME" ]]; then
      printf '%s\n' "$dir/$CONF_NAME"
      return 0
    fi
    dir="${dir%/*}"
  done
  [[ -f "/$CONF_NAME" ]] && { printf '%s\n' "/$CONF_NAME"; return 0; }
  return 1
}

resolve_config() {
  # 1. --config PATH wins outright; the root is that file's directory.
  if [[ -n "$CONF_FILE" ]]; then
    [[ -f "$CONF_FILE" ]] || die "$EX_CONFIG" "config not found: $CONF_FILE"
    CONF_FILE="$(realpath -- "$CONF_FILE")"
    LOCAL_DIR="${CONF_FILE%/*}"
    return 0
  fi

  # 2. --dir PATH, or 3. $RSYNC_SYNC_DIR: config must sit directly inside.
  local candidate=""
  [[ -n "$CLI_DIR" ]] && candidate="$CLI_DIR"
  [[ -z "$candidate" && -n "${RSYNC_SYNC_DIR:-}" ]] && candidate="${RSYNC_SYNC_DIR}"

  if [[ -n "$candidate" ]]; then
    # Expand a leading ~ that arrived quoted from a shell or unit file.
    [[ "$candidate" == "~"* ]] && candidate="${HOME}${candidate#\~}"
    [[ -d "$candidate" ]] || die "$EX_CONFIG" "sync root is not a directory: $candidate"
    LOCAL_DIR="$(realpath -- "$candidate")"
    CONF_FILE="$LOCAL_DIR/$CONF_NAME"
    [[ -f "$CONF_FILE" ]] || die "$EX_CONFIG" \
      "no $CONF_NAME in $LOCAL_DIR -- copy sync.conf.example there and edit it"
    return 0
  fi

  # 4. Search upward from the current directory.
  local found
  if found="$(find_config_upward "$PWD")"; then
    CONF_FILE="$found"
    LOCAL_DIR="${found%/*}"
    log_debug "found config by upward search: $CONF_FILE"
    return 0
  fi

  die "$EX_CONFIG" "no $CONF_NAME found in $PWD or any parent.
Point at the synced folder explicitly:   $SCRIPT_NAME --dir /path/to/folder
Or create one from the template:         cp sync.conf.example /path/to/folder/$CONF_NAME"
}

# Source the config. It is bash, so a syntax error must not take the script
# down with a bare parse failure -- validate it first, then source.
load_config() {
  log_debug "loading config: $CONF_FILE"

  bash -n "$CONF_FILE" 2>/dev/null ||
    die "$EX_CONFIG" "syntax error in $CONF_FILE (check with: bash -n '$CONF_FILE')"

  # Refuse a world-writable config: it is sourced as code, so anyone who can
  # write it can run arbitrary commands as this user.
  local perms
  perms="$(stat -c %a "$CONF_FILE" 2>/dev/null || echo 000)"
  if [[ "${perms: -1}" =~ [2367] ]]; then
    die "$EX_CONFIG" "$CONF_FILE is world-writable (mode $perms); refusing to source it.
Fix with: chmod o-w '$CONF_FILE'"
  fi

  # shellcheck source=/dev/null
  source "$CONF_FILE"

  # CLI flags outrank the file.
  [[ -n "$CLI_DRY_RUN" ]] && DRY_RUN="$CLI_DRY_RUN"
  [[ "$VERBOSE" == "true" ]] && LOG_LEVEL="debug"

  # Derive all state paths now that the root is known.
  STATE_DIR="$LOCAL_DIR/$STATE_DIR_NAME"
  SENTINEL_PATH="$STATE_DIR/$SENTINEL_NAME"
  LOCK_FILE="$STATE_DIR/sync.lock"
  DELETE_JOURNAL="$STATE_DIR/pending-deletes"
  SSH_CONTROL_PATH="$STATE_DIR/ssh-%C"

  # LOG_FILE is relative to the root unless given as an absolute path.
  if [[ "$LOG_FILE" == /* ]]; then
    LOG_PATH="$LOG_FILE"
  else
    LOG_PATH="$LOCAL_DIR/$LOG_FILE"
  fi

  RUN_TS="$(date '+%Y%m%d-%H%M%S')"
}



# =============================================================================
#  SECTION 5 -- DEPENDENCIES
# =============================================================================
#  xxh128 and lz4 are compile-time options in rsync, so their presence is
#  verified against `rsync --version` rather than assumed. A distro build
#  without them would otherwise fail confusingly on the first transfer.
# =============================================================================

# Compare dotted versions without sort -V (absent on some minimal systems).
version_ge() {
  local have="$1" want="$2"
  local -a h w
  IFS='.' read -ra h <<<"$have"
  IFS='.' read -ra w <<<"$want"
  local i
  for i in 0 1 2; do
    local hv="${h[i]:-0}" wv="${w[i]:-0}"
    hv="${hv//[^0-9]/}"; wv="${wv//[^0-9]/}"
    (( ${hv:-0} > ${wv:-0} )) && return 0
    (( ${hv:-0} < ${wv:-0} )) && return 1
  done
  return 0
}

check_dependencies() {
  local -a missing=()
  local cmd
  for cmd in rsync ssh flock realpath date stat; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  # inotifywait is only needed for continuous watching, not for --once/--check.
  if [[ "$MODE" == "watch" ]]; then
    command -v inotifywait >/dev/null 2>&1 || missing+=("inotifywait")
  fi

  if (( ${#missing[@]} )); then
    log_error "missing required commands: ${missing[*]}"
    log_error "on Debian/Ubuntu/Pop!_OS:  sudo apt install rsync openssh-client inotify-tools util-linux coreutils"
    exit "$EX_DEPS"
  fi

  # --- rsync version ---
  # NOTE: `... | head -1` would send SIGPIPE to rsync and, under `set -o
  # pipefail`, make the whole pipeline fail with 141. The version output is
  # captured once into a variable and parsed with pure-bash/awk instead.
  local rsync_caps rsync_ver
  rsync_caps="$(rsync --version 2>/dev/null)" || true
  rsync_ver="$(awk 'NR==1{print $3; exit}' <<<"$rsync_caps")"
  [[ -n "$rsync_ver" ]] || die "$EX_DEPS" "could not determine the rsync version"
  version_ge "$rsync_ver" "$RSYNC_MIN_VERSION" ||
    die "$EX_DEPS" "rsync $rsync_ver is too old; $RSYNC_MIN_VERSION+ is required for --checksum-choice/--compress-choice"
  log_debug "rsync $rsync_ver"

  # --- required algorithms ---
  # `rsync --version` prints a "Checksum list:" and a "Compress list:" line,
  # each followed by the supported algorithms. Both are checked because xxh128
  # and lz4 are compile-time features, not universal.
  local checksum_line compress_line
  checksum_line="$(awk '/Checksum list/{getline; print; exit}' <<<"$rsync_caps")"
  compress_line="$(awk '/Compress list/{getline; print; exit}'  <<<"$rsync_caps")"

  if [[ "$checksum_line" != *xxh128* ]]; then
    log_error "this rsync build does not support the xxh128 checksum."
    log_error "available:${checksum_line:-  (none reported)}"
    log_error "Install an rsync built with xxhash, or change --checksum-choice in build_common_opts()."
    exit "$EX_DEPS"
  fi

  if [[ "$compress_line" != *lz4* ]]; then
    log_error "this rsync build does not support lz4 compression."
    log_error "available:${compress_line:-  (none reported)}"
    log_error "Install an rsync built with lz4, or change --compress-choice in build_common_opts()."
    exit "$EX_DEPS"
  fi

  log_debug "rsync supports xxh128 and lz4"
}


# =============================================================================
#  SECTION 6 -- CONFIG VALIDATION AND PATH CONTAINMENT
# =============================================================================
#  With --delete active in both directions, a wrong path is destructive. These
#  checks run before any rsync and are the reason deletion cannot wander
#  outside the intended trees.
# =============================================================================

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

  [[ -n "$path" ]] || die "$EX_CONFIG" "$label is empty"
  [[ "$path" == /* ]] || die "$EX_CONFIG" "$label must be an absolute path, got: $path"
  [[ "$path" != *".."* ]] || die "$EX_CONFIG" "$label must not contain '..': $path"

  # Normalise away any trailing slashes for comparison.
  local norm="${path%/}"
  [[ -z "$norm" ]] && norm="/"

  local forbidden
  for forbidden in "${FORBIDDEN_PATHS[@]}"; do
    if [[ "$norm" == "$forbidden" ]]; then
      die "$EX_SAFETY" "$label points at the system directory '$norm'.
Syncing with --delete there could destroy the system. Choose a dedicated subdirectory."
    fi
  done

  # Depth check: "/x" has one component, "/x/y" has two.
  local depth
  depth="$(tr -cd '/' <<<"$norm" | wc -c)"
  if (( depth < 2 )); then
    die "$EX_SAFETY" "$label ('$norm') is only one level below /.
That is dangerously broad for a --delete sync; use a nested directory such as '$norm/project'."
  fi

  log_debug "$label validated: $norm"
}

validate_config() {
  # --- required keys ---
  [[ -n "$REMOTE_DIR" ]] || die "$EX_CONFIG" "REMOTE_DIR is not set in $CONF_FILE"

  # --- local root ---
  # Never created automatically: an empty local root combined with a push
  # --delete would wipe the remote.
  [[ -d "$LOCAL_DIR" ]] || die "$EX_CONFIG" "local sync root does not exist: $LOCAL_DIR"
  validate_sync_path "$LOCAL_DIR" "local sync root"
  validate_sync_path "$REMOTE_DIR" "REMOTE_DIR"

  # Strip any trailing slash; the rsync calls add exactly one where needed.
  LOCAL_DIR="${LOCAL_DIR%/}"
  REMOTE_DIR="${REMOTE_DIR%/}"

  # --- local root must be readable and writable (pull writes into it) ---
  [[ -r "$LOCAL_DIR" ]] || die "$EX_CONFIG" "local sync root is not readable: $LOCAL_DIR"
  [[ -w "$LOCAL_DIR" ]] || die "$EX_CONFIG" "local sync root is not writable: $LOCAL_DIR"

  # --- enumerated values ---
  case "$DELETE_MODE" in
    both|pull|push|none) ;;
    *) die "$EX_CONFIG" "DELETE_MODE must be both|pull|push|none, got '$DELETE_MODE'" ;;
  esac
  case "$PULL_COMPARE" in
    checksum|quick) ;;
    *) die "$EX_CONFIG" "PULL_COMPARE must be checksum|quick, got '$PULL_COMPARE'" ;;
  esac
  case "$REMOTE_WATCH" in
    poll|inotify) ;;
    *) die "$EX_CONFIG" "REMOTE_WATCH must be poll|inotify, got '$REMOTE_WATCH'" ;;
  esac
  case "$LOG_LEVEL" in
    error|warn|info|debug) ;;
    *) die "$EX_CONFIG" "LOG_LEVEL must be error|warn|info|debug, got '$LOG_LEVEL'" ;;
  esac

  # --- booleans ---
  local bool_var
  for bool_var in CONFLICT_BACKUP DELETE_PUSH_UNSAFE TRASH_ENABLED SAFE_LINKS \
                  PRESERVE_HARDLINKS REQUIRE_SENTINEL SSH_MULTIPLEXING \
                  PARTIAL_TRANSFERS DRY_RUN PRESERVE_OWNER PRESERVE_GROUP; do
    local val="${!bool_var}"
    [[ "$val" == "true" || "$val" == "false" ]] ||
      die "$EX_CONFIG" "$bool_var must be true or false, got '$val'"
  done

  # --- numbers (MAX_DELETE additionally allows -1 for "unlimited") ---
  local num_var
  for num_var in TRASH_KEEP_DAYS REMOTE_POLL_INTERVAL DEBOUNCE_SECONDS \
                 PERIODIC_FULL_SYNC MAX_CHANGES_PER_CYCLE RSYNC_TIMEOUT LOG_MAX_KB; do
    local nval="${!num_var}"
    [[ "$nval" =~ ^[0-9]+$ ]] ||
      die "$EX_CONFIG" "$num_var must be a non-negative integer, got '$nval'"
  done
  [[ "$MAX_DELETE" =~ ^(-1|[0-9]+)$ ]] ||
    die "$EX_CONFIG" "MAX_DELETE must be -1 or a non-negative integer, got '$MAX_DELETE'"

  # A debounce of 0 would fire a sync per inotify event; editors emit dozens
  # per save, so clamp to a sane floor.
  (( DEBOUNCE_SECONDS < 1 )) && { DEBOUNCE_SECONDS=1; log_warn "DEBOUNCE_SECONDS raised to 1"; }
  (( REMOTE_POLL_INTERVAL < 5 )) && { REMOTE_POLL_INTERVAL=5; log_warn "REMOTE_POLL_INTERVAL raised to 5"; }

  # --- ssh key ---
  if [[ -n "$SSH_KEY" ]]; then
    [[ "$SSH_KEY" == "~"* ]] && SSH_KEY="${HOME}${SSH_KEY#\~}"
    [[ -f "$SSH_KEY" ]] || die "$EX_CONFIG" "SSH_KEY not found: $SSH_KEY"
    [[ -r "$SSH_KEY" ]] || die "$EX_CONFIG" "SSH_KEY not readable: $SSH_KEY"
  fi

  # --- chown needs privilege on the remote ---
  if [[ -n "$REMOTE_CHOWN" && -z "$REMOTE_RSYNC" ]]; then
    log_warn "REMOTE_CHOWN='$REMOTE_CHOWN' usually needs root on the remote."
    log_warn "If pushes fail with 'chown failed', set REMOTE_RSYNC=\"sudo rsync\" in $CONF_NAME."
  fi

  # --- local-only mode ---
  if [[ -z "$REMOTE" ]]; then
    log_warn "REMOTE is empty: operating in LOCAL-TO-LOCAL mode (no ssh)."
    [[ -d "$REMOTE_DIR" ]] ||
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

# =============================================================================
#  SECTION 7 -- STATE DIRECTORY AND SENTINELS
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
  [[ "$PARTIAL_TRANSFERS" == "true" ]] && dirs+=("$STATE_DIR/partial")

  local d
  for d in "${dirs[@]}"; do
    mkdir -p "$d" || die "$EX_CONFIG" "cannot create state directory: $d"
  done

  # ControlMaster sockets are credentials-adjacent; keep the dir private.
  chmod 700 "$STATE_DIR" 2>/dev/null || true

  touch "$LOG_PATH" 2>/dev/null || die "$EX_CONFIG" "cannot write log file: $LOG_PATH"
  touch "$DELETE_JOURNAL" 2>/dev/null || true

  rotate_log_if_needed
}

# True when this root has synced successfully at least once.
local_sentinel_exists() { [[ -f "$SENTINEL_PATH" ]]; }

write_local_sentinel() {
  {
    echo "# rsync-monitor sync root marker -- do not delete"
    echo "# Removing this file makes sync.sh refuse to run (REQUIRE_SENTINEL)."
    echo "created=$(date -Iseconds)"
    echo "host=$(hostname 2>/dev/null || echo unknown)"
    echo "local_dir=$LOCAL_DIR"
    echo "remote=${REMOTE:-<local>}"
    echo "remote_dir=$REMOTE_DIR"
  } >"$SENTINEL_PATH" 2>/dev/null || log_warn "could not write sentinel: $SENTINEL_PATH"
}

# Create the remote .sync/ and its sentinel. Uses ssh, or plain mkdir in
# local-to-local mode.
write_remote_sentinel() {
  local content
  content="# rsync-monitor sync root marker -- do not delete
created=$(date -Iseconds)
paired_local=$LOCAL_DIR"

  if [[ -z "$REMOTE" ]]; then
    mkdir -p "$REMOTE_DIR/$STATE_DIR_NAME" 2>/dev/null || return 1
    printf '%s\n' "$content" >"$REMOTE_DIR/$STATE_DIR_NAME/$SENTINEL_NAME" 2>/dev/null || return 1
    return 0
  fi

  # Single quotes around the remote path stop the remote shell from expanding
  # anything in it; embedded single quotes are escaped the standard way.
  local q_state
  q_state="$(shell_quote "$REMOTE_DIR/$STATE_DIR_NAME")"
  printf '%s\n' "$content" |
    ssh_cmd "mkdir -p $q_state && cat > $q_state/$SENTINEL_NAME" 2>/dev/null || return 1
  return 0
}

remote_sentinel_exists() {
  if [[ -z "$REMOTE" ]]; then
    [[ -f "$REMOTE_DIR/$STATE_DIR_NAME/$SENTINEL_NAME" ]]
    return $?
  fi
  local q
  q="$(shell_quote "$REMOTE_DIR/$STATE_DIR_NAME/$SENTINEL_NAME")"
  ssh_cmd "test -f $q" >/dev/null 2>&1
}

# Wrap a string in single quotes for safe use in a remote shell command.
shell_quote() {
  local s="$1"
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

# The gate itself: both sides must be marked, or the run is refused.
check_sentinels() {
  [[ "$REQUIRE_SENTINEL" == "true" ]] || { log_debug "sentinel check disabled"; return 0; }

  local local_ok="false" remote_ok="false"
  local_sentinel_exists && local_ok="true"
  remote_sentinel_exists && remote_ok="true"

  # Both present: normal steady state.
  if [[ "$local_ok" == "true" && "$remote_ok" == "true" ]]; then
    log_debug "sentinels present on both sides"
    return 0
  fi

  # Neither present: a genuine first run. Establish both markers.
  if [[ "$local_ok" == "false" && "$remote_ok" == "false" ]]; then
    log_warn "no sentinel on either side -- treating this as FIRST RUN"
    if [[ "$FORCE_FIRST_RUN" != "true" && "$DRY_RUN" != "true" ]]; then
      log_error "First run refused without an explicit go-ahead."
      log_error "Preview it first:   $SCRIPT_NAME --dir '$LOCAL_DIR' --once --dry-run"
      log_error "Then commit to it:  $SCRIPT_NAME --dir '$LOCAL_DIR' --force-first-run"
      exit "$EX_SAFETY"
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
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
  [[ "$local_ok" == "false" ]] && missing_side="LOCAL ($LOCAL_DIR)" || missing_side="REMOTE (${REMOTE:-local}:$REMOTE_DIR)"
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

# Delete trash/conflict snapshots older than TRASH_KEEP_DAYS.
prune_old_snapshots() {
  (( TRASH_KEEP_DAYS == 0 )) && return 0
  local base
  for base in "$STATE_DIR/trash" "$STATE_DIR/conflicts"; do
    [[ -d "$base" ]] || continue
    # -mindepth 1 -maxdepth 1: only the timestamped snapshot dirs themselves.
    find "$base" -mindepth 1 -maxdepth 1 -type d -mtime "+$TRASH_KEEP_DAYS" \
      -exec rm -rf {} + 2>/dev/null || true
  done
  log_debug "pruned snapshots older than ${TRASH_KEEP_DAYS}d"
}

# =============================================================================
#  SECTION 8 -- SSH TRANSPORT
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

  [[ -n "$REMOTE_PORT" ]] && opts+=( -p "$REMOTE_PORT" )
  [[ -n "$SSH_KEY" ]] && opts+=( -i "$SSH_KEY" -o "IdentitiesOnly=yes" )

  if [[ "$SSH_MULTIPLEXING" == "true" ]]; then
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
    -o "BatchMode=yes"          # never prompt; fail instead (unattended use)
    -o "Compression=no"         # rsync does lz4 itself; double-compressing wastes CPU
  )

  (( ${#SSH_EXTRA_OPTS[@]} )) && opts+=( "${SSH_EXTRA_OPTS[@]}" )

  printf '%s\n' "${opts[@]}"
}

# The -e value for rsync: a single shell word list, so it is space-joined.
build_rsync_ssh_transport() {
  local -a opts=()
  mapfile -t opts < <(build_ssh_opts)
  printf 'ssh %s' "${opts[*]}"
}

# Run a command on the remote (no-op wrapper in local-to-local mode).
ssh_cmd() {
  local remote_command="$1"
  if [[ -z "$REMOTE" ]]; then
    bash -c "$remote_command"
    return $?
  fi
  local -a opts=()
  mapfile -t opts < <(build_ssh_opts)
  ssh "${opts[@]}" "$REMOTE" "$remote_command"
}

# Verify we can reach the remote and that REMOTE_DIR is usable there.
check_connection() {
  if [[ -z "$REMOTE" ]]; then
    log_info "local-to-local mode: skipping the ssh check"
    [[ -d "$REMOTE_DIR" ]] || die "$EX_CONN" "target directory missing: $REMOTE_DIR"
    return 0
  fi

  log_info "testing ssh to $REMOTE ..."
  local -a opts=()
  mapfile -t opts < <(build_ssh_opts)

  # ConnectTimeout is added only here so a slow link cannot stall the check.
  if ! ssh "${opts[@]}" -o "ConnectTimeout=10" "$REMOTE" true 2>/dev/null; then
    log_error "cannot connect to '$REMOTE'."
    log_error "Checks: host reachable? key loaded (ssh-add -l)? BatchMode forbids prompts,"
    log_error "so password-only auth will fail -- set up key auth or an ssh-agent."
    log_error "Reproduce manually:  ssh ${opts[*]} $REMOTE true"
    exit "$EX_CONN"
  fi
  log_debug "ssh connection ok"

  # REMOTE_DIR must exist and be writable; pushes and remote deletes need both.
  local q
  q="$(shell_quote "$REMOTE_DIR")"
  if ! ssh_cmd "test -d $q" 2>/dev/null; then
    log_error "REMOTE_DIR does not exist on $REMOTE: $REMOTE_DIR"
    log_error "Create it first:  ssh $REMOTE 'mkdir -p $REMOTE_DIR'"
    exit "$EX_CONN"
  fi
  if ! ssh_cmd "test -w $q" 2>/dev/null; then
    die "$EX_CONN" "REMOTE_DIR is not writable by this ssh user: $REMOTE_DIR"
  fi

  # Warn (do not fail) if the remote rsync lacks the algorithms we request:
  # rsync negotiates, so a mismatch degrades rather than breaks.
  local remote_caps
  if remote_caps="$(ssh_cmd "${REMOTE_RSYNC:-rsync} --version 2>/dev/null | head -20" 2>/dev/null)"; then
    grep -qi 'xxh128' <<<"$remote_caps" || log_warn "remote rsync may not support xxh128; rsync will negotiate a fallback"
    grep -qi 'lz4' <<<"$remote_caps" || log_warn "remote rsync may not support lz4; rsync will negotiate a fallback"
  else
    log_warn "could not query the remote rsync version"
  fi

}

# =============================================================================
#  SECTION 9 -- RSYNC OPTION BUILDERS
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
  o+=( --recursive )          # descend the tree
  o+=( --times )              # preserve mtimes (required for --update to work)
  o+=( --perms )              # preserve the permission bits
  o+=( --devices --specials ) # device and fifo/socket nodes (needs privilege)
  o+=( --omit-link-times )    # do not try to set mtimes on symlinks; many
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
  o+=( --links )

  # Optional hardening: skip links pointing outside the tree (and all absolute
  # links). Off by default so ordinary symlinks replicate faithfully -- safe
  # because without --keep-dirlinks such a link is never traversed.
  [[ "$SAFE_LINKS" == "true" ]] && o+=( --safe-links )

  [[ "$PRESERVE_HARDLINKS" == "true" ]] && o+=( --hard-links )
  [[ "$PRESERVE_GROUP" == "true" ]] && o+=( --group )
  [[ "$PRESERVE_OWNER" == "true" ]] && o+=( --owner )

  # --- integrity: xxh128 ---
  # --checksum-choice selects the algorithm used for the whole-file comparison
  # (with --checksum) and for the delta-transfer block checks. xxh128 is far
  # faster than md5 at equal-or-better collision resistance for this purpose.
  o+=( --checksum-choice=xxh128 )

  # --- compression: lz4 ---
  # lz4 is chosen for latency: it compresses fast enough not to become the
  # bottleneck on a fast link, unlike zlib/zstd at higher levels.
  o+=( --compress --compress-choice=lz4 )

  # --- efficiency ---
  o+=( --sparse )              # store holes efficiently (VM images, DBs)
  o+=( --human-readable )

  # Resume interrupted large files instead of restarting them. The partial dir
  # sits in .sync/ so half-written files never appear in the live tree.
  if [[ "$PARTIAL_TRANSFERS" == "true" ]]; then
    o+=( --partial --partial-dir="$STATE_DIR_NAME/partial" )
  fi

  [[ -n "$BWLIMIT" ]] && o+=( --bwlimit="$BWLIMIT" )
  (( RSYNC_TIMEOUT > 0 )) && o+=( --timeout="$RSYNC_TIMEOUT" )

  # --- transport ---
  if [[ -n "$REMOTE" ]]; then
    o+=( -e "$(build_rsync_ssh_transport)" )
    [[ -n "$REMOTE_RSYNC" ]] && o+=( --rsync-path="$REMOTE_RSYNC" )
  fi

  # --- reporting ---
  # --itemize-changes gives one parseable line per change, which is what the
  # change counting and dry-run summaries read.
  o+=( --itemize-changes )
  [[ "$DRY_RUN" == "true" ]] && o+=( --dry-run )
  [[ "$LOG_LEVEL" == "debug" ]] && o+=( --verbose )

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
  o+=( --filter="protect /$STATE_DIR_NAME/" )
  o+=( --filter="exclude /$STATE_DIR_NAME/" )

  # 2. sync.conf itself stays local: it names this machine's remote, and each
  #    side legitimately has its own. Protected so it is never deleted either.
  o+=( --filter="protect /$CONF_NAME" )
  o+=( --filter="exclude /$CONF_NAME" )
  o+=( --filter="protect /sync.conf.example" )
  o+=( --filter="exclude /sync.conf.example" )

  # 3. User excludes. A "protect" rule is emitted alongside each one so an
  #    excluded file on the receiver is not deleted merely because the sender
  #    cannot see it.
  local pattern
  for pattern in "${EXCLUDES[@]}"; do
    [[ -z "$pattern" ]] && continue
    [[ "$pattern" == "#"* ]] && continue        # allow commented entries

    # A leading "!" means re-include (rsync's "include" rule).
    if [[ "$pattern" == "!"* ]]; then
      o+=( --filter="include ${pattern#!}" )
      continue
    fi

    o+=( --filter="protect $pattern" )
    o+=( --filter="exclude $pattern" )
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
  [[ "$PULL_COMPARE" == "checksum" ]] && o+=( --checksum )

  # Preserve the local copy that loses a conflict. --backup moves the existing
  # local file aside instead of overwriting it in place; combined with --delete
  # below it also captures files removed on the remote.
  if [[ "$CONFLICT_BACKUP" == "true" ]]; then
    o+=( --backup --backup-dir="$STATE_DIR/conflicts/$RUN_TS" )
    # Without --suffix rsync appends "~"; the timestamped dir already
    # disambiguates, so keep the original filenames.
    o+=( --suffix= )
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
  if [[ "$DELETE_MODE" == "both" || "$DELETE_MODE" == "pull" ]]; then
    (( MAX_DELETE >= 0 )) && o+=( --max-delete="$MAX_DELETE" )
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
  o+=( --update )

  # Remote-side permissions and ownership, push direction only.
  [[ -n "$REMOTE_CHMOD" ]] && o+=( --chmod="$REMOTE_CHMOD" )
  [[ -n "$REMOTE_CHOWN" ]] && o+=( --chown="$REMOTE_CHOWN" )

  # Keep a recycle bin on the remote so a push-side delete is recoverable.
  if [[ "$TRASH_ENABLED" == "true" && ( "$DELETE_MODE" == "both" || "$DELETE_MODE" == "push" ) ]]; then
    o+=( --backup --backup-dir="$STATE_DIR_NAME/trash/$RUN_TS" )
    o+=( --suffix= )
  fi

  printf '%s\n' "${o[@]}"
}

# ---------------------------------------------------------------------------
#  Snapshot-driven deletion for the PULL direction.
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
# ---------------------------------------------------------------------------

# List the remote tree as newline-separated relative paths, honouring the same
# excludes as the transfer. rsync's own --list-only is used so the filter rules
# and symlink handling match exactly what a real transfer would see.
list_remote_paths() {
  local -a filters=()
  mapfile -t filters < <(build_filter_opts)

  # A MINIMAL option set is used on purpose. build_common_opts() adds
  # --itemize-changes (and possibly --verbose), which changes the output format.
  # Only what is needed to enumerate the tree the same way a real transfer would
  # is passed: recursion, symlinks-as-symlinks, and the identical filter rules.
  #
  # --list-only is NOT used: it ignores --out-format and prints an ls-style
  # long listing ("perms size date time path -> target"), which is fragile to
  # parse for names containing spaces or " -> ". A --dry-run against an empty
  # scratch destination with --out-format='%n' prints one bare path per line.
  local -a opts=( --recursive --links --dry-run --out-format=%n )
  [[ "$SAFE_LINKS" == "true" ]] && opts+=( --safe-links )
  (( RSYNC_TIMEOUT > 0 )) && opts+=( --timeout="$RSYNC_TIMEOUT" )
  if [[ -n "$REMOTE" ]]; then
    opts+=( -e "$(build_rsync_ssh_transport)" )
    [[ -n "$REMOTE_RSYNC" ]] && opts+=( --rsync-path="$REMOTE_RSYNC" )
  fi

  # The scratch destination is only ever read as a name: --dry-run guarantees
  # nothing is created or written there.
  local scratch="$STATE_DIR/.listing-scratch"

  # Directories arrive with a trailing slash and the tree root as "./" -- both
  # are normalised away so the result is a plain sorted list of relative paths.
  rsync "${opts[@]}" "${filters[@]}" "$(remote_endpoint)" "$scratch/" 2>/dev/null |
    sed -e 's|/$||' -e '/^\.$/d' -e '/^$/d' |
    LC_ALL=C sort -u
}

# Compare the previous remote snapshot with the current listing and remove
# locally only what genuinely disappeared from the remote.
apply_remote_deletions() {
  [[ "$DELETE_MODE" == "both" || "$DELETE_MODE" == "pull" ]] || return 0

  local snapshot="$STATE_DIR/remote-snapshot"
  local current
  current="$(mktemp "$STATE_DIR/.remote-list.XXXXXX")" || return 0

  if ! list_remote_paths >"$current"; then
    log_warn "could not list the remote tree; skipping pull-side deletions"
    rm -f "$current"
    return 0
  fi

  # No snapshot yet (first run): record the baseline and delete nothing.
  if [[ ! -f "$snapshot" ]]; then
    [[ "$DRY_RUN" == "true" ]] || mv -f "$current" "$snapshot"
    rm -f "$current" 2>/dev/null || true
    log_debug "remote snapshot initialised; no pull-side deletions on a first run"
    return 0
  fi

  # Paths that were in the snapshot but are gone from the remote now.
  local -a vanished=()
  mapfile -t vanished < <(LC_ALL=C comm -23 "$snapshot" "$current")

  local -a to_delete=()
  local rel
  for rel in "${vanished[@]}"; do
    [[ -z "$rel" ]] && continue
    # Containment: never act on absolute paths, traversal, or our own state.
    [[ "$rel" == /* || "$rel" == *".."* ]] && continue
    [[ "$rel" == "$STATE_DIR_NAME"* || "$rel" == "$CONF_NAME" ]] && continue
    # Only delete if it still exists locally.
    [[ -e "$LOCAL_DIR/$rel" || -L "$LOCAL_DIR/$rel" ]] || continue
    to_delete+=("$rel")
  done

  if (( ${#to_delete[@]} == 0 )); then
    [[ "$DRY_RUN" == "true" ]] || mv -f "$current" "$snapshot"
    rm -f "$current" 2>/dev/null || true
    log_debug "no remote deletions to apply"
    return 0
  fi

  # Deletion cap applies here too.
  if (( MAX_DELETE >= 0 && ${#to_delete[@]} > MAX_DELETE )); then
    log_error "${#to_delete[@]} remote deletion(s) detected, over MAX_DELETE=$MAX_DELETE."
    log_error "Refusing to apply them. This often means the remote path is wrong or unmounted."
    rm -f "$current"
    return 1
  fi

  log_info "applying ${#to_delete[@]} remote deletion(s) locally"

  if [[ "$DRY_RUN" == "true" ]]; then
    printf '  would delete locally: %s\n' "${to_delete[@]}" >&2
    rm -f "$current"
    return 0
  fi

  local trash_dir="$STATE_DIR/trash/$RUN_TS"
  for rel in "${to_delete[@]}"; do
    if [[ "$TRASH_ENABLED" == "true" ]]; then
      mkdir -p "$trash_dir/$(dirname -- "$rel")" 2>/dev/null || true
      mv -f "$LOCAL_DIR/$rel" "$trash_dir/$rel" 2>/dev/null ||
        log_warn "could not move '$rel' to the trash"
    else
      # ${var:?} makes bash abort rather than expand to "/" if either variable
      # is somehow empty -- a last line of defence around a recursive delete.
      rm -rf -- "${LOCAL_DIR:?}/${rel:?}" 2>/dev/null || log_warn "could not delete '$rel'"
    fi
  done

  mv -f "$current" "$snapshot"
  log_ok "removed ${#to_delete[@]} path(s) locally (deleted on the remote)"
  return 0
}

# Refresh the snapshot at the end of a cycle, so the next cycle compares
# against the state the two sides actually converged on.
update_remote_snapshot() {
  [[ "$DELETE_MODE" == "both" || "$DELETE_MODE" == "pull" ]] || return 0
  [[ "$DRY_RUN" == "true" ]] && return 0
  local snapshot="$STATE_DIR/remote-snapshot"
  local tmp
  tmp="$(mktemp "$STATE_DIR/.remote-list.XXXXXX")" || return 0
  if list_remote_paths >"$tmp"; then
    mv -f "$tmp" "$snapshot"
    log_debug "remote snapshot updated ($(wc -l <"$snapshot") path(s))"
  else
    rm -f "$tmp"
  fi
  return 0
}

# ---------------------------------------------------------------------------
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
# ---------------------------------------------------------------------------
apply_journaled_deletes() {
  [[ "$DELETE_MODE" == "both" || "$DELETE_MODE" == "push" ]] || return 0
  [[ -s "$DELETE_JOURNAL" ]] || { log_debug "delete journal empty"; return 0; }

  # Read, then immediately truncate, so events arriving during this pass are
  # not lost and not double-applied.
  local -a paths=()
  mapfile -t paths <"$DELETE_JOURNAL"
  : >"$DELETE_JOURNAL"

  local -a valid=()
  local rel
  for rel in "${paths[@]}"; do
    [[ -z "$rel" ]] && continue

    # Containment re-check. The journal is a file on disk; treat it as
    # untrusted input. Reject absolute paths and any traversal attempt so a
    # corrupted or tampered journal cannot delete outside REMOTE_DIR.
    [[ "$rel" == /* ]] && { log_warn "journal: skipping absolute path '$rel'"; continue; }
    [[ "$rel" == *".."* ]] && { log_warn "journal: skipping traversal path '$rel'"; continue; }
    [[ "$rel" == "$STATE_DIR_NAME/"* ]] && continue     # never touch .sync/
    [[ "$rel" == "$CONF_NAME" ]] && continue            # never touch sync.conf

    # If the path exists locally again it was recreated (a "delete" that was
    # really an editor's atomic save), so it must not be deleted remotely.
    if [[ -e "$LOCAL_DIR/$rel" ]]; then
      log_debug "journal: '$rel' exists again locally; not deleting remotely"
      continue
    fi

    valid+=("$rel")
  done

  (( ${#valid[@]} )) || { log_debug "no valid journaled deletions"; return 0; }

  # Respect the deletion cap here too.
  if (( MAX_DELETE >= 0 && ${#valid[@]} > MAX_DELETE )); then
    log_error "journal holds ${#valid[@]} deletions, over MAX_DELETE=$MAX_DELETE."
    log_error "Refusing to apply them; this often means a bulk local delete was unintended."
    log_error "Review .sync/pending-deletes, then raise MAX_DELETE or clear the journal."
    printf '%s\n' "${valid[@]}" >>"$DELETE_JOURNAL"
    return 1
  fi

  log_info "applying ${#valid[@]} local deletion(s) to the remote"

  if [[ "$DRY_RUN" == "true" ]]; then
    printf '  would delete remotely: %s\n' "${valid[@]}" >&2
    # Put them back so a later real run still applies them.
    printf '%s\n' "${valid[@]}" >>"$DELETE_JOURNAL"
    return 0
  fi

  # Build one remote command: move each path into the remote trash when the
  # bin is enabled, otherwise remove it outright. Paths are single-quoted.
  local remote_script
  remote_script="set -e; cd $(shell_quote "$REMOTE_DIR") || exit 1;"
  if [[ "$TRASH_ENABLED" == "true" ]]; then
    remote_script+=" mkdir -p $(shell_quote "$STATE_DIR_NAME/trash/$RUN_TS");"
  fi

  for rel in "${valid[@]}"; do
    local q; q="$(shell_quote "$rel")"
    if [[ "$TRASH_ENABLED" == "true" ]]; then
      # --parents keeps the original directory layout inside the trash dir.
      remote_script+=" if [ -e $q ] || [ -L $q ]; then mkdir -p \"\$(dirname $(shell_quote "$STATE_DIR_NAME/trash/$RUN_TS/$rel"))\"; mv -f $q $(shell_quote "$STATE_DIR_NAME/trash/$RUN_TS/$rel") 2>/dev/null || true; fi;"
    else
      remote_script+=" rm -rf -- $q;"
    fi
  done

  if ssh_cmd "$remote_script" 2>/dev/null; then
    log_ok "removed ${#valid[@]} path(s) from the remote"
    return 0
  fi

  log_warn "some remote deletions failed; re-queueing them for the next cycle"

  printf '%s\n' "${valid[@]}" >>"$DELETE_JOURNAL"
  return 1
}

# =============================================================================
#  SECTION 10 -- RUNNING THE TRANSFERS
# =============================================================================

# Build the "[user@]host:path/" or "path/" endpoint string.
# The TRAILING SLASH is essential: "src/" copies the contents of src into the
# destination, whereas "src" would create "dest/src". Getting this wrong with
# --delete active would be destructive, so it is centralised here.
remote_endpoint() {
  if [[ -z "$REMOTE" ]]; then
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
  n="$(grep -cE '^([<>ch.*][fdLDS]|\*deleting)' <<<"$output" 2>/dev/null || true)"
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

  local -a cmd=( rsync )
  local -a common=() filters=()
  mapfile -t common < <(build_common_opts)
  mapfile -t filters < <(build_filter_opts)

  cmd+=( "${common[@]}" "${filters[@]}" "${extra[@]}" "$src" "$dst" )

  log_debug "$label: ${cmd[*]}"

  local output status
  # `set -e` must not abort on a non-zero rsync status, hence the || capture.
  output="$("${cmd[@]}" 2>&1)" && status=0 || status=$?

  # Surface rsync's own output at debug level, or whenever it actually changed
  # something (so the log records what moved).
  if [[ -n "$output" ]]; then
    if [[ "$LOG_LEVEL" == "debug" || "$DRY_RUN" == "true" ]]; then
      printf '%s\n' "$output" >&2
    fi
  fi

  local changes
  changes="$(count_itemized_changes "$output")"

  case "$status" in
    0)
      if (( changes > 0 )); then
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
      [[ -n "$output" ]] && printf '%s\n' "$output" >&2
      ;;
  esac

  # Record the change count so callers can read it after the fact.
  # shellcheck disable=SC2034  # consumed by callers/summaries, not here
  LAST_CHANGE_COUNT="$changes"
  return "$status"
}
# shellcheck disable=SC2034
LAST_CHANGE_COUNT=0

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
# pull purely to count, before anything is actually modified.
estimate_changes() {
  (( MAX_CHANGES_PER_CYCLE == 0 )) && return 0

  # Force --dry-run into the option set while counting.
  local saved_dry="$DRY_RUN"
  DRY_RUN="true"

  local -a common=() filters=() popts=()
  mapfile -t common  < <(build_common_opts)
  mapfile -t filters < <(build_filter_opts)
  mapfile -t popts   < <(build_pull_opts)

  local out total
  out="$(rsync "${common[@]}" "${filters[@]}" "${popts[@]}" \
         "$(remote_endpoint)" "$(local_endpoint)" 2>/dev/null)" || true
  total="$(count_itemized_changes "$out")"

  DRY_RUN="$saved_dry"

  if (( total > MAX_CHANGES_PER_CYCLE )); then
    log_error "this cycle would change $total files, over MAX_CHANGES_PER_CYCLE=$MAX_CHANGES_PER_CYCLE."
    log_error "Refusing to proceed. Inspect with: $SCRIPT_NAME --dir '$LOCAL_DIR' --once --dry-run"
    return 1
  fi
  log_debug "change estimate: $total"
  return 0
}

# =============================================================================
#  SECTION 11 -- THE SYNC CYCLE
# =============================================================================
#  Order is deliberate and load-bearing:
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

sync_cycle() {
  local reason="${1:-manual}"
  local rc=0

  # Fresh timestamp per cycle so trash/conflict snapshots stay distinguishable.
  RUN_TS="$(date '+%Y%m%d-%H%M%S')"

  log_info "--- sync cycle start (trigger: $reason) ---"
  [[ "$DRY_RUN" == "true" ]] && log_warn "DRY RUN: nothing will be modified"

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
  if [[ "$DIRECTION" == "both" || "$DIRECTION" == "push" ]]; then
    if [[ "$MODE" == "watch" || -s "$DELETE_JOURNAL" ]]; then
      apply_journaled_deletes || log_warn "journaled deletions incomplete"
    fi
  fi

  # --- 2. Remote deletions -> local (snapshot diff, not a blanket --delete) ---
  # Also before the pull, so a file deleted remotely is removed locally instead
  # of being re-uploaded by the push later in this same cycle.
  if [[ "$DIRECTION" == "both" || "$DIRECTION" == "pull" ]]; then
    apply_remote_deletions || log_warn "pull-side deletions incomplete"
  fi

  # --- 3. PULL (remote authoritative) ---
  if [[ "$DIRECTION" == "both" || "$DIRECTION" == "pull" ]]; then
    if ! do_pull; then
      rc=$?
      # 25 (max-delete) is reported but does not abort the push: the transfer
      # itself succeeded, only deletions were curtailed.
      if (( rc != 25 )); then
        log_error "pull failed (status $rc); skipping the push to avoid acting on a partial state"
        log_info "--- sync cycle end (failed) ---"
        return "$EX_RSYNC"
      fi
    fi
  fi

  # --- 3. PUSH (never clobbers a newer remote file) ---
  if [[ "$DIRECTION" == "both" || "$DIRECTION" == "push" ]]; then
    if ! do_push; then
      rc=$?
      (( rc != 25 )) && log_error "push failed (status $rc)"
    fi
  fi

  # --- 4. Opt-in blanket delete on push (one-shot mirror mode only) ---
  # The journal already ran as step 1. This is the explicitly-unsafe escape
  # hatch for "make the remote exactly match local", with no journal to consult:
  # it cannot distinguish a new remote file from a local deletion.
  if [[ "$DIRECTION" == "both" || "$DIRECTION" == "push" ]]; then
    if [[ "$MODE" != "watch" && "$DELETE_PUSH_UNSAFE" == "true" ]]; then
      log_warn "DELETE_PUSH_UNSAFE: applying a blanket --delete on push"
      local -a popts=()
      mapfile -t popts < <(build_push_opts)
      popts+=( --delete-after )
      (( MAX_DELETE >= 0 )) && popts+=( --max-delete="$MAX_DELETE" )
      run_rsync "push-delete" "$(local_endpoint)" "$(remote_endpoint)" "${popts[@]}" || true
    elif [[ "$MODE" != "watch" ]]; then
      log_debug "one-shot run: push-side deletion limited to the journal"
    fi
  fi

  # --- 5. Record the converged remote state for the next cycle's diff ---
  update_remote_snapshot

  prune_old_snapshots

  # First successful cycle registers the sentinels.
  if [[ "$DRY_RUN" != "true" ]] && ! local_sentinel_exists; then
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

  exec {lock_fd}>"$LOCK_FILE" || { log_error "cannot open lock file: $LOCK_FILE"; return 1; }

  # Non-blocking: if a cycle is already running, the trigger is dropped rather
  # than queued. The event that caused it will be covered by the running cycle
  # or by the next one, so no change is lost.
  if ! flock -n "$lock_fd"; then
    log_debug "a sync is already running; skipping this trigger ($reason)"
    exec {lock_fd}>&-
    return 0
  fi

  local rc=0
  sync_cycle "$reason" || rc=$?

  exec {lock_fd}>&-
  return "$rc"
}

# =============================================================================
#  SECTION 12 -- WATCHERS
# =============================================================================
#  Three producers can feed the event channel:
#    * local inotify   -- immediate, kernel-level
#    * remote watcher  -- inotifywait over ssh, or a periodic poll
#    * periodic timer  -- safety-net full sync
#  All of them write a single line to $EVENT_FIFO; the main loop debounces.
# =============================================================================

# Translate the rsync globs in EXCLUDES into one POSIX ERE for inotifywait, so
# the watcher ignores exactly what the transfer ignores. Without this, activity
# in node_modules/ or .git/ would trigger cycles that then transfer nothing.
build_inotify_exclude_regex() {
  local -a parts=()

  # Always ignore our own state dir; otherwise writing the log or the trash
  # would trigger a sync, which would write the log again -> feedback loop.
  parts+=( "/\\.sync(/|$)" )
  parts+=( "/${CONF_NAME//./\\.}$" )

  local pattern
  for pattern in "${EXCLUDES[@]}"; do
    [[ -z "$pattern" || "$pattern" == "#"* || "$pattern" == "!"* ]] && continue

    local p="$pattern"
    local anchored="false" dir_only="false"
    [[ "$p" == /* ]] && { anchored="true"; p="${p#/}"; }
    [[ "$p" == */ ]] && { dir_only="true";  p="${p%/}"; }

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
    re="${re//\?/.}"           # glob ? -> any single char
    re="${re//\*/[^/]*}"       # glob * -> anything but a slash

    if [[ "$anchored" == "true" ]]; then
      # Anchored at the sync root: match only just below LOCAL_DIR.
      local root_re="${LOCAL_DIR//./\\.}"
      if [[ "$dir_only" == "true" ]]; then
        parts+=( "^${root_re}/${re}(/|$)" )
      else
        parts+=( "^${root_re}/${re}$" )
      fi
    else
      # Unanchored: match at any depth.
      if [[ "$dir_only" == "true" ]]; then
        parts+=( "/${re}(/|$)" )
      else
        parts+=( "/${re}$" )
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
    "$LOCAL_DIR" >"$fifo_in" 2>/dev/null &

  local inotify_pid=$!
  WATCHER_PIDS+=("$inotify_pid")

  # Reader: translates raw inotify lines into event-channel messages and
  # journals deletions on the way through.
  (
    while IFS='|' read -r events path; do
      # Record deletions and move-outs for the push-side delete journal.
      # MOVED_FROM means the file left this path, which is a delete from the
      # remote's point of view.
      case "$events" in
        *DELETE*|*MOVED_FROM*)
          # Path relative to the sync root. No `local` here: this loop body
          # runs in a subshell, not inside a function.
          rel="${path#"$LOCAL_DIR"/}"
          if [[ -n "$rel" && "$rel" != "$path" ]]; then
            printf '%s\n' "$rel" >>"$DELETE_JOURNAL" 2>/dev/null || true
          fi
          ;;
      esac
      printf 'local|%s|%s\n' "$events" "$path" >"$EVENT_FIFO" 2>/dev/null || break
    done <"$fifo_in"
  ) &

  local reader_pid=$!
  WATCHER_PIDS+=("$reader_pid")
  log_info "local watcher started (inotify pid $inotify_pid) on $LOCAL_DIR"
}

# Does the remote have inotifywait? Determines whether REMOTE_WATCH="inotify"
# is actually usable, or must fall back to polling.
remote_has_inotifywait() {
  [[ -z "$REMOTE" ]] && { command -v inotifywait >/dev/null 2>&1; return $?; }
  ssh_cmd "command -v inotifywait >/dev/null 2>&1" >/dev/null 2>&1
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
    # If the ssh stream dies (network drop, remote reboot) retry with a delay
    # rather than silently losing remote change detection for good.
    while [[ "$SHUTTING_DOWN" != "true" ]]; do
      ssh_cmd "$remote_cmd" 2>/dev/null |
      while IFS='|' read -r events path; do
        printf 'remote|%s|%s\n' "$events" "$path" >"$EVENT_FIFO" 2>/dev/null || break
      done
      [[ "$SHUTTING_DOWN" == "true" ]] && break
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
    while [[ "$SHUTTING_DOWN" != "true" ]]; do
      sleep "$REMOTE_POLL_INTERVAL"
      [[ "$SHUTTING_DOWN" == "true" ]] && break
      printf 'poll|TIMER|remote\n' >"$EVENT_FIFO" 2>/dev/null || break
    done
  ) &

  local pid=$!
  WATCHER_PIDS+=("$pid")
  log_info "remote poll watcher started (pid $pid, every ${REMOTE_POLL_INTERVAL}s)"
}

start_remote_watcher() {
  if [[ "$REMOTE_WATCH" == "inotify" ]]; then
    if remote_has_inotifywait; then
      start_remote_inotify_watcher
      return 0
    fi
    log_warn "REMOTE_WATCH=inotify but inotifywait is not on the remote."
    log_warn "Install it there (e.g. sudo apt install inotify-tools), or set REMOTE_WATCH=\"poll\"."
    log_warn "Falling back to polling."
  fi
  start_remote_poll_watcher
}

# Safety-net timer: a periodic full sync catches anything the watchers missed
# (inotify queue overflow on a busy tree, events during a dropped connection).
start_periodic_watcher() {
  (( PERIODIC_FULL_SYNC == 0 )) && { log_debug "periodic full sync disabled"; return 0; }

  (
    while [[ "$SHUTTING_DOWN" != "true" ]]; do
      sleep "$PERIODIC_FULL_SYNC"
      [[ "$SHUTTING_DOWN" == "true" ]] && break
      printf 'periodic|TIMER|full\n' >"$EVENT_FIFO" 2>/dev/null || break
    done
  ) &

  local pid=$!

}

# =============================================================================
#  SECTION 13 -- MAIN WATCH LOOP (DEBOUNCED)
# =============================================================================
#  Saving one file in an editor typically produces several inotify events
#  (create temp, write, rename, attrib). Syncing per event would mean several
#  redundant rsync runs per keystroke-save.
#
#  So events are coalesced: after an event arrives, wait for DEBOUNCE_SECONDS
#  of quiet before syncing. Any event during that window restarts the timer, so
#  a burst becomes exactly one cycle. `read -t` provides the timeout.
# =============================================================================

watch_loop() {
  # A FIFO (not a plain file) is used so the watchers block on write and the
  # reader blocks on read -- no polling, no lost events, no growing spool file.
  EVENT_FIFO="$STATE_DIR/events.fifo"
  rm -f "$EVENT_FIFO"
  mkfifo -m 600 "$EVENT_FIFO" || die "$EX_CONFIG" "cannot create the event FIFO: $EVENT_FIFO"

  # Hold the FIFO open read-write for the whole run. Without this the reader
  # would see EOF every time the last writer closed, and the loop would spin.
  exec {fifo_fd}<>"$EVENT_FIFO"

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
    if [[ "$pending" == "true" ]]; then
      # In a burst: wait only DEBOUNCE_SECONDS for the next event. A timeout
      # means the burst has ended, so sync now.
      if read -r -t "$DEBOUNCE_SECONDS" -u "$fifo_fd" line; then
        log_debug "event during debounce: $line"
        continue                     # restart the quiet period
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
          poll|periodic)
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

# =============================================================================
#  SECTION 14 -- CLEANUP
# =============================================================================

cleanup() {
  local exit_code=$?
  [[ "$SHUTTING_DOWN" == "true" ]] && return
  SHUTTING_DOWN="true"

  # Terminate the watcher subshells and everything they spawned. The negative
  # PID targets the whole process group, which is what actually stops
  # inotifywait (a child of the subshell) rather than orphaning it.
  local pid
  for pid in "${WATCHER_PIDS[@]:-}"; do
    [[ -z "$pid" ]] && continue
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  done

  # Reap them briefly, then insist.
  local waited=0
  while (( waited < 3 )); do
    local alive="false"
    for pid in "${WATCHER_PIDS[@]:-}"; do
      [[ -z "$pid" ]] && continue
      kill -0 "$pid" 2>/dev/null && alive="true"
    done
    [[ "$alive" == "false" ]] && break
    sleep 1; (( waited++ ))
  done
  for pid in "${WATCHER_PIDS[@]:-}"; do
    [[ -z "$pid" ]] && continue
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  done

  # Close the shared ssh master so no socket is left behind.
  if [[ -n "$REMOTE" && "$SSH_MULTIPLEXING" == "true" ]]; then
    local -a opts=()
    mapfile -t opts < <(build_ssh_opts 2>/dev/null) || true
    ssh "${opts[@]}" -O exit "$REMOTE" 2>/dev/null || true
  fi

  [[ -n "$EVENT_FIFO" && -p "$EVENT_FIFO" ]] && rm -f "$EVENT_FIFO"
  [[ -n "$STATE_DIR" && -p "$STATE_DIR/inotify.raw" ]] && rm -f "$STATE_DIR/inotify.raw"

  # Deliberately NOT removed: .sync/pending-deletes (a journal that survives a
  # restart), the log, the trash and the conflict snapshots.

  if (( exit_code == 0 )); then
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

# =============================================================================
#  SECTION 15 -- --check REPORT
# =============================================================================

print_summary() {
  local delete_desc
  case "$DELETE_MODE" in
    both) delete_desc="both directions (push side is journal-driven)" ;;
    pull) delete_desc="remote -> local only" ;;
    push) delete_desc="local -> remote only (journal-driven)" ;;
    none) delete_desc="disabled" ;;
  esac

  cat >&2 <<EOF

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
  transport       $( [[ -n "$REMOTE" ]] && echo "ssh (multiplexing=${SSH_MULTIPLEXING})" || echo "local filesystem" )
  bandwidth cap   ${BWLIMIT:-unlimited}
  excludes        ${#EXCLUDES[@]} pattern(s)

${C_GREEN}=== watching ===${C_RESET}
  remote watch    ${REMOTE_WATCH}$( [[ "$REMOTE_WATCH" == "poll" ]] && echo " (every ${REMOTE_POLL_INTERVAL}s)" )
  debounce        ${DEBOUNCE_SECONDS}s
  periodic sync   $( (( PERIODIC_FULL_SYNC > 0 )) && echo "every ${PERIODIC_FULL_SYNC}s" || echo "disabled" )

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

  if [[ "$l" == "missing" && "$r" == "missing" ]]; then
    log_warn "neither side is registered yet; the first real run needs --force-first-run"
    log_warn "(preview it first with --once --dry-run)"
  elif [[ "$l" != "$r" ]]; then
    log_error "sentinels are ASYMMETRIC -- a normal run would refuse to start."
    log_error "Check both paths in $CONF_NAME and that every filesystem is mounted."
    return "$EX_SAFETY"
  fi

  # Show what a cycle would do, without touching anything.
  log_info "counting pending changes (dry run) ..."
  local saved="$DRY_RUN"
  DRY_RUN="true"
  local -a common=() filters=() popts=()
  mapfile -t common  < <(build_common_opts)
  mapfile -t filters < <(build_filter_opts)
  mapfile -t popts   < <(build_pull_opts)
  local out
  out="$(rsync "${common[@]}" "${filters[@]}" "${popts[@]}" \
         "$(remote_endpoint)" "$(local_endpoint)" 2>&1)" || true
  DRY_RUN="$saved"
  log_info "pull would apply $(count_itemized_changes "$out") change(s)"

  log_ok "configuration looks good"
  return 0
}

# =============================================================================
#  SECTION 16 -- ENTRY POINT
# =============================================================================

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
      if sync_cycle_locked "once"; then
        log_ok "single sync cycle complete"
        exit "$EX_OK"
      fi
      log_error "the sync cycle failed"
      exit "$EX_RSYNC"
      ;;
    watch)
      check_connection
      check_sentinels
      watch_loop      # never returns; exits via the signal handler
      ;;
    *)
      die "$EX_CONFIG" "unknown mode: $MODE"
      ;;
  esac
}

main "$@"
