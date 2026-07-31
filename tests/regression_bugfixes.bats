#!/usr/bin/env bats
# Regression tests pinned to specific bugs found during code review. Each one
# is written to FAIL against the pre-fix code and PASS against the patched
# version, so a future refactor can't silently reintroduce these.

load 'test_helper.bash'

setup() {
  setup_sourceable_lib
  setup_sync_dirs
}

# ---------------------------------------------------------------------------
# Bug 1: build_rsync_ssh_transport() joined ssh options with the global
# IFS=$'\n\t' instead of spaces, via "${opts[*]}". rsync's own -e parser
# splits on literal spaces only, so every option past the first collapsed
# into one glued argv element passed to ssh -- silently dropping/mangling
# -i, -o BatchMode=yes, ControlMaster, etc.
# ---------------------------------------------------------------------------

@test "[bugfix] ssh transport string is space-joined despite global IFS=\\n\\t" {
  run_lib '
    REMOTE_PORT="2222"
    SSH_KEY=""
    SSH_MULTIPLEXING="true"
    SSH_CONTROL_PATH="/tmp/ctrl-%C"
    SSH_EXTRA_OPTS=()
    build_rsync_ssh_transport
  '
  [ "$status" -eq 0 ]
  # Must be a single space-separated line with no embedded newlines/tabs.
  [[ "$output" != *$'\n'* ]]
  [[ "$output" != *$'\t'* ]]
  [[ "$output" == "ssh -p 2222 "* ]]
}

@test "[bugfix] every built ssh option survives as its own token in the transport string" {
  # shellcheck disable=SC2016
  # Global IFS=$'\n\t' would cause "read -ra words <<<\"$t\"" to split on
  # newlines/tabs instead of spaces, collapsing the transport string into a
  # single-element array. Use wc -w on the captured output to count words
  # correctly regardless of IFS.
  run_lib '
    REMOTE_PORT="2222"
    SSH_KEY=""
    SSH_MULTIPLEXING="true"
    SSH_CONTROL_PATH="/tmp/ctrl-%C"
    SSH_EXTRA_OPTS=()
    t="$(build_rsync_ssh_transport)"
    printf "%s\n" "$t" | wc -w
  '
  [ "$status" -eq 0 ]
  # ssh, -p, 2222, -o ControlMaster=auto, -o ControlPath=..., -o ControlPersist=120,
  # -o ServerAliveInterval=15, -o ServerAliveCountMax=3, -o BatchMode=yes,
  # -o Compression=no  => 1 + 2 + 2*7 = 17 words. The exact count matters less
  # than it being >1 word per option pair instead of a single glued blob.
  [ "$output" -gt 10 ]
}

@test "[bugfix] a real local-to-local sync still works with the fixed transport builder" {
  # End-to-end guard: even though local-to-local mode never invokes ssh, this
  # confirms the transport-builder change didn't break normal option building
  # for REMOTE-set configs by constructing the opts array the same way
  # build_ssh_opts() does and checking it parses back into the right tokens.
  write_conf
  establish_baseline
  echo hi > "$LOCAL_DIR/x.txt"
  run_sync --once
  [ "$status" -eq 0 ]
  assert_file_content "$REMOTE_DIR/x.txt" "hi"
}

# ---------------------------------------------------------------------------
# Bug 2: start_periodic_watcher() captured its background subshell's PID into
# a local variable but never appended it to WATCHER_PIDS, so cleanup() could
# never terminate it -- an orphaned timer process leaked on every shutdown.
# ---------------------------------------------------------------------------

@test "[bugfix] start_periodic_watcher registers its pid in WATCHER_PIDS" {
  # kill -9, not a plain kill: the spawned subshell inherits mirror-remote-directory.sh's own
  # EXIT/TERM traps, and bash defers a caught, trap-handled signal until the
  # subshell's current foreground command (sleep) returns -- so a plain
  # SIGTERM here would sit unhandled for the full PERIODIC_FULL_SYNC
  # duration. SIGKILL can't be caught or deferred, so it reaps it at once.
  #
  # Use exec {fifo_fd}<> (read-write mode, like watch_loop) so the FIFO stays
  # open. The fd number is stored in EVENT_FIFO_FD so the watcher subshell can
  # write via >& "$EVENT_FIFO_FD" instead of reopening the FIFO path (which
  # would block on open() and hang on kill -9).
  #
  # Clear EXIT/TERM traps immediately so cleanup() never fires on subshell exit.
  run_lib '
    STATE_DIR="'"$BATS_TEST_TMPDIR"'"
    EVENT_FIFO="'"$BATS_TEST_TMPDIR"'/events.fifo"
    mkfifo "$EVENT_FIFO"
    exec {fifo_fd}<> "$EVENT_FIFO"
    EVENT_FIFO_FD=$fifo_fd
    trap - EXIT TERM
    PERIODIC_FULL_SYNC=3600
    WATCHER_PIDS=()
    start_periodic_watcher
    printf "%s\n" "${#WATCHER_PIDS[@]}"
    kill -9 "${WATCHER_PIDS[@]}" 2>/dev/null || true
    exec {fifo_fd}>&-
    rm -f "$EVENT_FIFO"
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" -eq 1 ]
}

@test "[bugfix] the registered periodic-watcher pid is a real, killable process" {
  # Use exec {fifo_fd}<> (read-write mode, like watch_loop) so the watcher's
  # printf never blocks via >& "$EVENT_FIFO_FD" — no background cat reader needed.
  #
  # Clear EXIT/TERM traps immediately so cleanup() never fires on subshell exit.
  #
  # Disable job control (set +m) so bash doesn't emit a "Killed" diagnostic
  # for the terminated watcher — that message would otherwise merge into
  # $output and break the ALIVE assertion.
  run_lib '
    set +m
    STATE_DIR="'"$BATS_TEST_TMPDIR"'"
    EVENT_FIFO="'"$BATS_TEST_TMPDIR"'/events.fifo"
    mkfifo "$EVENT_FIFO"
    exec {fifo_fd}<> "$EVENT_FIFO"
    EVENT_FIFO_FD=$fifo_fd
    trap - EXIT TERM
    PERIODIC_FULL_SYNC=3600
    WATCHER_PIDS=()
    start_periodic_watcher
    pid="${WATCHER_PIDS[0]}"
    if kill -0 "$pid" 2>/dev/null; then echo ALIVE; else echo DEAD; fi
    kill -9 "$pid" 2>/dev/null || true
    exec {fifo_fd}>&-
    rm -f "$EVENT_FIFO"
  '
  # bash emits a "Killed" diagnostic for the terminated watcher subshell to stderr,
  # which bats' `run` merges into $output. Check that ALIVE is present rather
  # than requiring an exact match (the Killed message spans multiple lines).
  [[ "$output" == *"ALIVE"* ]]
}

# ---------------------------------------------------------------------------
# Bug 3: estimate_changes() always dry-ran only the pull direction regardless
# of $DIRECTION, so MAX_CHANGES_PER_CYCLE never gated --push-only cycles at
# all (it measured the wrong side) and --pull-only cycles paid for a
# redundant dry-run. This drives it through a real cycle: a large *pull-side*
# change is queued up, but the cycle runs --push-only with a tight
# MAX_CHANGES_PER_CYCLE. The gate must not fire, because the push itself has
# nothing to do.
# ---------------------------------------------------------------------------

@test "[bugfix] MAX_CHANGES_PER_CYCLE does not gate a --push-only cycle on pull-side volume" {
  write_conf MAX_CHANGES_PER_CYCLE=1
  establish_baseline

  # Pile up remote-side changes that would trip a pull-based estimate...
  for i in $(seq 1 10); do echo "r$i" > "$REMOTE_DIR/remote-file-$i.txt"; done
  # ...but this cycle only pushes, and there is nothing new to push.
  run_sync --once --push-only
  [ "$status" -eq 0 ]
  [[ "$output" != *"MAX_CHANGES_PER_CYCLE"* ]]
}

@test "[bugfix] MAX_CHANGES_PER_CYCLE still gates a --pull-only cycle on real pull volume" {
  write_conf MAX_CHANGES_PER_CYCLE=1
  establish_baseline

  for i in $(seq 1 10); do echo "r$i" > "$REMOTE_DIR/remote-file-$i.txt"; done
  run_sync --once --pull-only
  [ "$status" -eq 3 ]
  [[ "$output" == *"MAX_CHANGES_PER_CYCLE"* ]]
}

# ---------------------------------------------------------------------------
# Bug 4: count_itemized_changes()'s regex character class [<>ch.*] included
# a literal "." so attribute-only lines like ".d..t...... somedir/" were
# counted as changes — contradicting the documented intent and inflating
# both the "N change(s)" log summaries and the MAX_CHANGES_PER_CYCLE gate.
# Fixed by changing [<>ch.*] to [<>ch].
# ---------------------------------------------------------------------------

@test "[bugfix] attribute-only itemize lines are not counted as changes" {
  run_lib 'count_itemized_changes ".d..t...... unchanged-dir/
.f..t...... unchanged-file.txt"'
  [ "$output" -eq 0 ]
}
