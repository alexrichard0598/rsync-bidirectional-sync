#!/usr/bin/env bash
# =============================================================================
#  lib/globals.sh -- shared constants, config defaults, and runtime state
# =============================================================================
#  Not one of the classes in class-diagram.md -- see the "Deviations from the
#  diagram" note there. Bash has no per-object storage, so every "class" in
#  this codebase reads and writes plain global variables. Centralising their
#  declaration here (instead of splitting them across the modules that most
#  use them) avoids `set -u` load-order failures: every module below is free
#  to reference any of these regardless of which lib/*.sh files have been
#  sourced so far, as long as this file is sourced first.
#
#  Every setting gets a default here so that (a) `set -u` can never trip on a
#  key the user's sync.conf omits, and (b) an old config keeps working when
#  new options are added. sync.conf overrides these; CLI flags override
#  sync.conf.
# =============================================================================

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

# --- connection ---
REMOTE=""
REMOTE_DIR=""
REMOTE_PORT=""
SSH_KEY=""
SSH_EXTRA_OPTS=()

# --- excludes ---
EXCLUDES=()

# --- remote permissions ---
REMOTE_CHMOD=""
REMOTE_CHOWN=""
PRESERVE_OWNER="false"
PRESERVE_GROUP="true"
REMOTE_RSYNC=""

# --- conflicts ---
CONFLICT_BACKUP="true"
PULL_COMPARE="checksum"

# --- deletion ---
DELETE_MODE="both"
DELETE_PUSH_UNSAFE="false"
MAX_DELETE="100"
TRASH_ENABLED="true"
TRASH_KEEP_DAYS="14"

# --- symlinks ---
SAFE_LINKS="false"
PRESERVE_HARDLINKS="true"

# --- change detection ---
REMOTE_WATCH="poll"
REMOTE_POLL_INTERVAL="30"
DEBOUNCE_SECONDS="2"
PERIODIC_FULL_SYNC="300"

# --- safety ---
REQUIRE_SENTINEL="true"
MAX_CHANGES_PER_CYCLE="0"

# --- performance ---
BWLIMIT=""
SSH_MULTIPLEXING="true"
PARTIAL_TRANSFERS="true"
RSYNC_TIMEOUT="300"

# --- logging ---
LOG_FILE=".sync/sync.log"
LOG_LEVEL="info"
LOG_MAX_KB="5120"
DRY_RUN="false"

# --- runtime state (not user-configurable) ---------------------------------
LOCAL_DIR=""        # resolved sync root (dir containing sync.conf)
CONF_FILE=""        # resolved path to sync.conf
STATE_DIR=""        # $LOCAL_DIR/.sync
LOG_PATH=""         # absolute log path
LOCK_FILE=""        # flock target
SENTINEL_PATH=""    # local sentinel
DELETE_JOURNAL=""   # observed local deletions
SSH_CONTROL_PATH="" # ControlMaster socket template

MODE="watch"     # watch | once | check
DIRECTION="both" # both | pull | push
FORCE_FIRST_RUN="false"
VERBOSE="false"
CLI_DRY_RUN="" # set by --dry-run, overrides config
CLI_DIR=""     # set by --dir

RUN_TS=""       # timestamp for this run's trash/conflict dirs
WATCHER_PIDS=() # background inotify/poll pids, killed on exit
EVENT_FIFO=""   # watcher -> main loop event channel
SHUTTING_DOWN="false"

# shellcheck disable=SC2034  # consumed by Sync callers/summaries
LAST_CHANGE_COUNT=0
