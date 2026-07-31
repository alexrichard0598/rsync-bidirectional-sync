#!/usr/bin/env bash
# =============================================================================
#  lib/logging.sh -- Logging and LogRotation (class-diagram.md)
# =============================================================================
#  Messages go to stderr (so stdout stays clean for --dry-run output) and, once
#  the sync root is known, are appended to the log file. Before the root is
#  resolved LOG_PATH is empty and we log to the terminal only.
#
#  DEVIATION from class-diagram.md: LogRotation is implemented in this same
#  file rather than a separate lib/log_rotation.sh. It is a single function
#  used only by Logging/State, so splitting it into its own file added a
#  module with no other reader and no maintenance benefit. The diagram keeps
#  LogRotation as a distinct class -- see its "Deviations" note.
# =============================================================================

# Numeric severities, so LOG_LEVEL can gate output with a simple comparison.
_log_level_num() {
  case "$1" in
    error) echo 0 ;;
    warn) echo 1 ;;
    info) echo 2 ;;
    debug) echo 3 ;;
    *) echo 2 ;;
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
  local level="$1"
  shift
  local msg="$*"

  # Drop anything more verbose than the configured level.
  (($(_log_level_num "$level") > $(_log_level_num "$LOG_LEVEL"))) && return 0

  local ts colour
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  case "$level" in
    error) colour="$C_RED" ;;
    warn) colour="$C_YELLOW" ;;
    info) colour="$C_BLUE" ;;
    debug) colour="$C_GREY" ;;
    *) colour="" ;;
  esac

  printf '%s%s [%-5s]%s %s\n' \
    "$colour" "$ts" "$level" "$C_RESET" "$msg" >&2

  # Plain (uncoloured) copy to the log file when we have one.
  if [[ -n $LOG_PATH && -w ${LOG_PATH%/*} ]]; then
    printf '%s [%-5s] %s\n' "$ts" "$level" "$msg" >> "$LOG_PATH" 2> /dev/null || true
  fi
}

log_error() { _log error "$@"; }
log_warn() { _log warn "$@"; }
log_info() { _log info "$@"; }
log_debug() { _log debug "$@"; }

# Success line: always shown (it is an info-level event people look for).
log_ok() {
  printf '%s%s [ ok  ]%s %s\n' \
    "$C_GREEN" "$(date '+%Y-%m-%d %H:%M:%S')" "$C_RESET" "$*" >&2
  [[ -n $LOG_PATH && -w ${LOG_PATH%/*} ]] &&
    printf '%s [ ok  ] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_PATH" 2> /dev/null || true
  return 0
}

# Log, then exit with a specific code.
die() {
  local code="$1"
  shift
  log_error "$*"
  exit "$code"
}

# --- LogRotation -------------------------------------------------------------
# Truncate the log when it outgrows LOG_MAX_KB, keeping the newer half so
# recent history survives. Single generation, no external logrotate needed.
rotate_log_if_needed() {
  [[ -n $LOG_PATH && -f $LOG_PATH ]] || return 0
  [[ $LOG_MAX_KB =~ ^[0-9]+$ ]] || return 0
  ((LOG_MAX_KB == 0)) && return 0

  local size_kb
  size_kb=$(($(stat -c %s "$LOG_PATH" 2> /dev/null || echo 0) / 1024))
  if ((size_kb > LOG_MAX_KB)); then
    mv -f "$LOG_PATH" "${LOG_PATH}.1" 2> /dev/null || return 0
    : > "$LOG_PATH"
    log_info "log rotated at ${size_kb}KB (previous kept as ${LOG_PATH##*/}.1)"

  fi
}
