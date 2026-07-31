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
#
#  CODE LAYOUT
#    This file is now a thin entry point. The implementation is split across
#    lib/*.sh, one file per class in class-diagram.md:
#      lib/globals.sh         shared constants, config defaults, runtime state
#      lib/logging.sh         Logging, LogRotation
#      lib/config.sh          Configuration
#      lib/validation.sh      Validation
#      lib/state.sh           State
#      lib/connection.sh      Connection
#      lib/rsync_options.sh   RsyncOptions
#      lib/snapshot.sh        Snapshot
#      lib/sync.sh            Sync
#      lib/watcher.sh         Watcher
#      lib/controller.sh      Controller
#    See class-diagram.md for responsibilities and relationships, including
#    the "Deviations from the diagram" section documenting where this split
#    departs from the class list (Globals is new; LogRotation is merged into
#    lib/logging.sh).
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

# Resolve the directory this script lives in (not $PWD), so lib/*.sh is found
# regardless of where the script is invoked from or symlinked via.
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -h $SCRIPT_SOURCE ]]; do
  SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
  SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
  [[ $SCRIPT_SOURCE != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
readonly LIB_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)/lib"

# Sourced in dependency order: globals first (every module reads its
# variables and constants), Logging next (everything after it logs), then the
# rest in roughly the order class-diagram.md lists them.
# shellcheck source=lib/globals.sh
source "$LIB_DIR/globals.sh"
# shellcheck source=lib/logging.sh
source "$LIB_DIR/logging.sh"
# shellcheck source=lib/config.sh
source "$LIB_DIR/config.sh"
# shellcheck source=lib/validation.sh
source "$LIB_DIR/validation.sh"
# shellcheck source=lib/state.sh
source "$LIB_DIR/state.sh"
# shellcheck source=lib/connection.sh
source "$LIB_DIR/connection.sh"
# shellcheck source=lib/rsync_options.sh
source "$LIB_DIR/rsync_options.sh"
# shellcheck source=lib/snapshot.sh
source "$LIB_DIR/snapshot.sh"
# shellcheck source=lib/sync.sh
source "$LIB_DIR/sync.sh"
# shellcheck source=lib/watcher.sh
source "$LIB_DIR/watcher.sh"
# shellcheck source=lib/controller.sh
source "$LIB_DIR/controller.sh"

main "$@"
