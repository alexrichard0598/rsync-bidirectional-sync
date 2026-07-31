#!/usr/bin/env bash
# shellcheck disable=SC2034
# =============================================================================
#  lib/config.sh -- Configuration (class-diagram.md)
# =============================================================================
#  Argument parsing and config file loading. sync.conf lives inside the folder
#  being synced, so the root must be found before the config can be read. The
#  root is then defined as the directory containing that file -- which is why
#  there is no LOCAL_DIR setting.
# =============================================================================

usage() {
  cat << EOF
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
  while (($#)); do
    case "$1" in
      -d | --dir)
        [[ -n ${2:-} ]] || die "$EX_CONFIG" "--dir requires a path"
        CLI_DIR="$2"
        shift 2
        ;;
      -c | --config)
        [[ -n ${2:-} ]] || die "$EX_CONFIG" "--config requires a path"
        CONF_FILE="$2"
        shift 2
        ;;
      -1 | --once)
        MODE="once"
        shift
        ;;
      --check)
        MODE="check"
        shift
        ;;
      -n | --dry-run)
        CLI_DRY_RUN="true"
        shift
        ;;
      --pull-only)
        DIRECTION="pull"
        shift
        ;;
      --push-only)
        DIRECTION="push"
        shift
        ;;
      --force-first-run)
        FORCE_FIRST_RUN="true"
        shift
        ;;
      -v | --verbose)
        VERBOSE="true"
        LOG_LEVEL="debug"
        shift
        ;;
      -q | --quiet)
        LOG_LEVEL="error"
        shift
        ;;
      -h | --help)
        usage
        exit "$EX_OK"
        ;;
      -V | --version)
        printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
        exit "$EX_OK"
        ;;
      --)
        shift
        break
        ;;
      -*)
        usage >&2
        die "$EX_CONFIG" "unknown option: $1"
        ;;
      *)
        usage >&2
        die "$EX_CONFIG" "unexpected argument: $1"
        ;;
    esac
  done

}

# Walk up from a starting directory looking for sync.conf. Stops at / so a
# stray config in $HOME cannot be picked up from an unrelated deep path.
find_config_upward() {
  local dir="$1"
  dir="$(cd "$dir" 2> /dev/null && pwd -P)" || return 1
  while [[ -n $dir && $dir != "/" ]]; do
    if [[ -f "$dir/$CONF_NAME" ]]; then
      printf '%s\n' "$dir/$CONF_NAME"
      return 0
    fi
    dir="${dir%/*}"
  done
  [[ -f "/$CONF_NAME" ]] && {
    printf '%s\n' "/$CONF_NAME"
    return 0
  }
  return 1
}

resolve_config() {
  # 1. --config PATH wins outright; the root is that file's directory.
  if [[ -n $CONF_FILE ]]; then
    [[ -f $CONF_FILE ]] || die "$EX_CONFIG" "config not found: $CONF_FILE"
    CONF_FILE="$(realpath -- "$CONF_FILE")"
    LOCAL_DIR="${CONF_FILE%/*}"
    return 0
  fi

  # 2. --dir PATH, or 3. $RSYNC_SYNC_DIR: config must sit directly inside.
  local candidate=""
  [[ -n $CLI_DIR ]] && candidate="$CLI_DIR"
  [[ -z $candidate && -n ${RSYNC_SYNC_DIR:-} ]] && candidate="${RSYNC_SYNC_DIR}"

  if [[ -n $candidate ]]; then
    # Expand a leading ~ that arrived quoted from a shell or unit file.
    [[ $candidate == "~"* ]] && candidate="${HOME}${candidate#\~}"
    [[ -d $candidate ]] || die "$EX_CONFIG" "sync root is not a directory: $candidate"
    LOCAL_DIR="$(realpath -- "$candidate")"
    CONF_FILE="$LOCAL_DIR/$CONF_NAME"
    [[ -f $CONF_FILE ]] || die "$EX_CONFIG" \
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

  bash -n "$CONF_FILE" 2> /dev/null ||
    die "$EX_CONFIG" "syntax error in $CONF_FILE (check with: bash -n '$CONF_FILE')"

  # Refuse a world-writable config: it is sourced as code, so anyone who can
  # write it can run arbitrary commands as this user.
  local perms
  perms="$(stat -c %a "$CONF_FILE" 2> /dev/null || echo 000)"
  if [[ ${perms: -1} =~ [2367] ]]; then
    die "$EX_CONFIG" "$CONF_FILE is world-writable (mode $perms); refusing to source it.
Fix with: chmod o-w '$CONF_FILE'"
  fi

  # shellcheck source=/dev/null
  source "$CONF_FILE"

  # CLI flags outrank the file.
  [[ -n $CLI_DRY_RUN ]] && DRY_RUN="$CLI_DRY_RUN"
  [[ $VERBOSE == "true" ]] && LOG_LEVEL="debug"

  # Derive all state paths now that the root is known.
  STATE_DIR="$LOCAL_DIR/$STATE_DIR_NAME"
  SENTINEL_PATH="$STATE_DIR/$SENTINEL_NAME"
  LOCK_FILE="$STATE_DIR/sync.lock"
  DELETE_JOURNAL="$STATE_DIR/pending-deletes"

  # Keep the SSH control socket under a short base directory to avoid
  # "unix_listener: path too long for Unix domain socket" errors when
  # $STATE_DIR is deeply nested.
  SSH_CONTROL_PATH="${XDG_RUNTIME_DIR:-/tmp}/rsync-monitor-ssh-%C"

  # LOG_FILE is relative to the root unless given as an absolute path.
  if [[ $LOG_FILE == /* ]]; then
    LOG_PATH="$LOG_FILE"
  else
    LOG_PATH="$LOCAL_DIR/$LOG_FILE"
  fi

  RUN_TS="$(date '+%Y%m%d-%H%M%S')"
}
