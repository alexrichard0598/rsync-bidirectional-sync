# AGENT.md — How to work in this project

Every time you work on this project, start be reading `qwen-log.md` if it exists.
You must maintain a step-by step log at `qwen-log.md`.
This log is your only persistent memory across context resets — design it so you can resume mid-task just by reading it.

---

## Logging rule

After **every atomic step**, append a log entry to `qwen-log.md` **before** proceeding to the next step.

An "atomic step" is any of:

- Reading a file and discovering something relevant to the current task
- Running a command (shell, build, test, search, etc.)
- Making a code change (editing or writing a file)
- Forming a conclusion or decision based on evidence gathered
- Starting or completing a sub-task

You **must** write a log at least once every 100 lines read.

## Log format

Each entry is a single block separated by a blank line:

```
### <timestamp> | <step N> | <action type>
**Why:** <one-line reason>
**What:** <what you did or observed>
```

- **timestamp** — `YYYY-MM-DD HH:MM:SS` (use `date` or equivalent)
- **step N** — monotonic counter starting at 1, never reset
- **action type** — one of: `read`, `command`, `edit`, `write`, `decision`, `result`
- **Why** — the reason you took this step (context for future-you)
- **What** — concise summary of what happened (key findings, output excerpts, diffs)

## Critical rules

1. **Log before you proceed.** If you read file A and it reveals you need to read file B, log the finding from A first. Do not batch observations — write them down as you discover them.

2. **Log after saving files.** When you edit a file, save it to disk, then log the change. This way the log always reflects what is actually on disk.

3. **Include enough to resume.** A future session reading `qwen-log.md` must be able to understand: what the goal is, what has been done, what remains, and where to pick up. The last entry should indicate the next step.

4. **Keep entries concise.** Log the signal, not the noise. Summarize command output — don't paste full traces. Include only the parts that affect decisions.

5. **The step counter never resets.** This lets you track total effort across sessions and know exactly where you left off.

6. **End each session with a "next step" entry.** Your final log entry should be a `decision` type stating what needs to happen next, so a resumed session can continue immediately.

## Example

```
### 2025-07-30 10:00:01 | step 1 | read
**Why:** Need to understand current script structure before adding feature X
**What:** Read sync.sh lines 1-200. Found main loop at line 450, config loader at line 120.

### 2025-07-30 10:00:05 | step 2 | read
**Why:** Step 1 showed config uses variables section — need to see variable names
**What:** Read sync.conf.example. Key variables: REMOTE_HOST, REMOTE_PORT, EXCLUDES pattern at lines 30-60.

### 2025-07-30 10:01:00 | step 3 | edit
**Why:** Adding new config option REMOTE_TIMEOUT after EXCLUDES section
**What:** Added REMOTE_TIMEOUT=300 at line 65 of sync.conf.example. Saved file.

### 2025-07-30 10:01:30 | step 4 | command
**Why:** Verify script still runs after config change
**What:** Ran `bash -n sync.sh` — syntax OK, no errors.

### 2025-07-30 10:02:00 | step 5 | decision
**Why:** Completed config change. Remaining: add variable handling in script body.
**What:** Next step: add REMOTE_TIMEOUT logic to rsync options builder function around line 800.
```
