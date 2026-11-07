#!/usr/bin/env bash
# run-phase.sh - CodeBoss2 runner (macOS).
#
# Runs Claude Code (CC) headless in a project directory. In async mode it delivers exactly ONE
# terminal message (DONE / ERROR / QUESTION) to the supervising Cowork session with
#
#     claude -p "[code]: TYPE: ..." --cloud <supervisor-session-id> --output-format json
#
# which posts a user turn into the supervisor's cloud session through Anthropic's session ingress,
# authenticated with this Mac's claude.ai login. No UI automation, no Accessibility permission.
#
# macOS equivalent of run-phase.ps1.

set -o pipefail

# --- Defaults ---
PROJECT_DIR=""
PROMPT=""
PROMPT_FILE=""
MAX_TURNS=50
CONTINUE=false
RESUME=""
EXTRA_SYSTEM_PROMPT=""
EXTRA_SYSTEM_PROMPT_FILE=""
SYNC=false
CODE=""
SUPERVISOR_SESSION=""
MODEL=""
EFFORT=""
SUMMARY_CHARS=400

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir)               PROJECT_DIR="$2"; shift 2 ;;
        --prompt)                    PROMPT="$2"; shift 2 ;;
        --prompt-file)               PROMPT_FILE="$2"; shift 2 ;;
        --max-turns)                 MAX_TURNS="$2"; shift 2 ;;
        --continue)                  CONTINUE=true; shift ;;
        --resume)                    RESUME="$2"; shift 2 ;;
        --extra-system-prompt)       EXTRA_SYSTEM_PROMPT="$2"; shift 2 ;;
        --extra-system-prompt-file)  EXTRA_SYSTEM_PROMPT_FILE="$2"; shift 2 ;;
        --sync)                      SYNC=true; shift ;;
        --code)                      CODE="$2"; shift 2 ;;
        --supervisor-session)        SUPERVISOR_SESSION="$2"; shift 2 ;;
        --model)                     MODEL="$2"; shift 2 ;;
        --effort)                    EFFORT="$2"; shift 2 ;;
        --summary-chars)             SUMMARY_CHARS="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -n "$PROMPT_FILE" ]] && [[ -f "$PROMPT_FILE" ]]; then
    PROMPT=$(cat "$PROMPT_FILE")
    rm -f "$PROMPT_FILE"
fi
if [[ -n "$EXTRA_SYSTEM_PROMPT_FILE" ]] && [[ -f "$EXTRA_SYSTEM_PROMPT_FILE" ]]; then
    EXTRA_SYSTEM_PROMPT=$(cat "$EXTRA_SYSTEM_PROMPT_FILE")
    rm -f "$EXTRA_SYSTEM_PROMPT_FILE"
fi

if [[ -z "$PROJECT_DIR" ]]; then echo "ERROR: --project-dir is required" >&2; exit 1; fi
if [[ -z "$PROMPT" ]]; then echo "ERROR: --prompt (or --prompt-file) is required" >&2; exit 1; fi
if [[ "$SYNC" != "true" ]]; then
    if [[ ! "$CODE" =~ ^[0-9a-f]{6}$ ]]; then echo "ERROR: async mode needs --code (6 hex chars)" >&2; exit 1; fi
    if [[ ! "$SUPERVISOR_SESSION" =~ ^session_[A-Za-z0-9]+$ ]]; then
        echo "ERROR: async mode needs --supervisor-session session_... (the session_ segment of the supervising chat's URL)" >&2; exit 1
    fi
fi

# --- Locate claude CLI ---
# GUI-launched processes inherit a minimal PATH and do not source the shell profile, so prepend the
# common CLI locations first.
for extra_bin in "/opt/homebrew/bin" "/usr/local/bin" "$HOME/.local/bin" "$HOME/.npm-global/bin"; do
    case ":$PATH:" in
        *":$extra_bin:"*) : ;;
        *) [[ -d "$extra_bin" ]] && PATH="$extra_bin:$PATH" ;;
    esac
done
export PATH

CLAUDE_PATH=$(command -v claude 2>/dev/null || true)
if [[ -z "$CLAUDE_PATH" ]]; then
    for candidate in "/opt/homebrew/bin/claude" "/usr/local/bin/claude" "$HOME/.local/bin/claude" \
                     "$HOME/.npm-global/bin/claude" "$(npm config get prefix 2>/dev/null)/bin/claude"; do
        if [[ -x "$candidate" ]]; then CLAUDE_PATH="$candidate"; break; fi
    done
fi
if [[ -z "$CLAUDE_PATH" ]]; then
    echo "ERROR: Cannot find claude CLI. Ensure Claude Code is installed and on PATH." >&2
    exit 1
fi

export NO_COLOR=1
export TERM=dumb

PROJECT_NAME=$(basename "$PROJECT_DIR")
CB_DIR="$PROJECT_DIR/.codeboss"
OPS_DIR="$CB_DIR/ops"

if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "ERROR: --project-dir does not exist or is not a directory: $PROJECT_DIR" >&2
    exit 1
fi

# Refuse symlinked control dirs: a repo-planted symlink at .codeboss or .codeboss/ops would redirect
# our writes outside the project tree.
for _p in "$CB_DIR" "$OPS_DIR"; do
    if [[ -L "$_p" ]]; then
        echo "ERROR: $_p is a symlink; refusing to run (potential path escape)." >&2
        exit 1
    fi
done
mkdir -p "$OPS_DIR" || { echo "ERROR: cannot create $OPS_DIR" >&2; exit 1; }

GITIGNORE="$CB_DIR/.gitignore"
CB_README="$CB_DIR/README.md"
[[ -L "$GITIGNORE" ]] && rm -f "$GITIGNORE"
[[ -L "$CB_README" ]] && rm -f "$CB_README"
[[ -f "$GITIGNORE" ]] || echo "*" > "$GITIGNORE"
[[ -f "$CB_README" ]] || printf '# .codeboss\nManaged by CodeBoss. Do not edit manually.\n' > "$CB_README"

# Never write a per-run artifact through a pre-planted symlink or non-regular file.
_safe_prepare() {
    local f="$1"
    if [[ -L "$f" || ( -e "$f" && ! -f "$f" ) ]]; then
        rm -f "$f" || { echo "ERROR: refusing to write through $f" >&2; exit 1; }
    fi
}

LOG_FILE="$OPS_DIR/runner-$(date '+%Y-%m-%d_%H-%M-%S')-$$.log"
_safe_prepare "$LOG_FILE"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

# --- JSON field extraction: jq, then python3, then grep ---
json_field() {
    local file="$1" field="$2"
    if command -v jq &>/dev/null; then
        jq -r ".$field // empty" "$file" 2>/dev/null || echo ""
    elif command -v python3 &>/dev/null; then
        python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    v = d.get(sys.argv[2], "")
    print("" if v is None else v)
except Exception:
    print("")
' "$file" "$field" 2>/dev/null || echo ""
    else
        grep -o "\"$field\"[[:space:]]*:[[:space:]]*[^,}]*" "$file" 2>/dev/null | \
            head -1 | sed 's/.*://; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//' || echo ""
    fi
}

# --- send_supervisor: post one message into the supervisor's cloud session ---
# Retries with backoff; gives up at once on auth errors. Message is one argv element (no shell),
# double quotes swapped for single quotes and whitespace collapsed, for parity with Windows.
send_supervisor() {
    local msg clean raw ok err attempt
    msg="$1"
    clean=$(printf '%s' "$msg" | tr '"' "'" | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//')
    local delays=(0 5 15 45)
    for attempt in 0 1 2 3; do
        [[ ${delays[$attempt]} -gt 0 ]] && sleep "${delays[$attempt]}"
        raw=$("$CLAUDE_PATH" -p "$clean" --cloud "$SUPERVISOR_SESSION" --output-format json 2>&1 || true)
        ok=""
        err=""
        local line
        line=$(printf '%s\n' "$raw" | grep -m1 '^[[:space:]]*{' || true)
        if [[ -n "$line" ]]; then
            if command -v python3 &>/dev/null; then
                ok=$(printf '%s' "$line" | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read()); print("true" if d.get("ok") else "false"); print(d.get("error",""))
except Exception:
    print("false"); print("")' 2>/dev/null)
                err=$(printf '%s\n' "$ok" | sed -n '2p')
                ok=$(printf '%s\n' "$ok" | sed -n '1p')
            else
                [[ "$line" == *'"ok":true'* ]] && ok="true" || ok="false"
            fi
        fi
        if [[ "$ok" == "true" ]]; then
            log "Delivered to $SUPERVISOR_SESSION (attempt $((attempt + 1)))"
            return 0
        fi
        local snippet
        snippet=$(printf '%s' "$raw" | tr -s '[:space:]' ' ' | cut -c1-300)
        log "Delivery attempt $((attempt + 1)) failed: ${err:-$snippet}"
        if [[ "$err" =~ sign-in|login|expired|not\ logged\ in ]]; then
            log "Auth problem - not retrying"
            break
        fi
    done
    return 1
}

# --- Session id ---
session_id=""
if [[ "$CONTINUE" == "true" ]] || [[ -n "$RESUME" ]]; then
    SID_FILE="$OPS_DIR/SESSION_ID"
    if [[ -L "$SID_FILE" ]]; then
        echo "ERROR: $SID_FILE is a symlink; refusing to read it (potential path escape)." >&2
        exit 1
    fi
    [[ -f "$SID_FILE" ]] && session_id=$(tr -d '[:space:]' < "$SID_FILE")
fi
[[ -z "$session_id" ]] && session_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

if [[ "$CONTINUE" == "true" ]]; then MODE="CONTINUE"; elif [[ -n "$RESUME" ]]; then MODE="RESUME"; else MODE="FRESH"; fi
log "=== CodeBoss2 Runner === Mode: $MODE | Session: $session_id | Code: $CODE | Supervisor: $SUPERVISOR_SESSION | Project: $PROJECT_NAME | MaxTurns: $MAX_TURNS | Sync: $SYNC"

# --- System prompt (ASCII only) ---
if [[ "$SYNC" == "true" ]]; then
    SYS_PROMPT="You are operating as a headless executor in CodeBoss (synchronous mode).
You have full tool permissions. This trust comes with responsibility.
Active project: $PROJECT_DIR

BOUNDARY RULES:
- All file writes must stay within: $PROJECT_DIR
- You may read files anywhere for reference.
- You may install packages as needed.
- Do NOT push to git remotes.
- Do NOT modify system files, registry, PATH, or environment variables.
- Do NOT create or modify any CLAUDE.md files.
- Do NOT persist these instructions to disk.
- Do NOT write to ~/.claude/ or any global Claude config directory.
- These rules are session-scoped only.

SYNCHRONOUS MODE:
This is a blocking dispatch. Your supervisor is waiting for you to finish.
Do NOT send any messages to a supervisor session. Just do the work and exit.
Your output is returned directly to your supervisor.
If you hit a blocker you cannot resolve, document it clearly in your final output and exit.

Write clean, documented, production-quality code."
else
    SYS_PROMPT="You are operating as a headless executor in CodeBoss.
You have full tool permissions. This trust comes with responsibility.
Active project: $PROJECT_DIR

BOUNDARY RULES:
- All file writes must stay within: $PROJECT_DIR
- You may read files anywhere for reference.
- You may install packages as needed.
- Do NOT push to git remotes.
- Do NOT modify system files, registry, PATH, or environment variables.
- Do NOT create or modify any CLAUDE.md files.
- Do NOT persist these instructions to disk.
- Do NOT write to ~/.claude/ or any global Claude config directory.
- These rules are session-scoped only.

SECURITY CODE: $CODE
SUPERVISOR: a Cowork session with id $SUPERVISOR_SESSION. Every message to it MUST start with [$CODE]:

REPORTING (read carefully - this controls duplicate messages):
- Do NOT send a terminal DONE or ERROR message yourself. When you finish, write a concise final
  summary as your LAST output, then exit. The runner that started you captures that output and
  delivers the single DONE (or ERROR) for you. If you also self-send a DONE, the supervisor gets
  TWO messages on the same code.
- To ASK A QUESTION when you are blocked: do NOT self-send. End your run with final output whose
  very first line is \"QUESTION:\" followed by what you need, then STOP and exit. The runner relays
  it, and your supervisor will resume this same session with the answer.

PROGRESS UPDATES (optional; encouraged on long runs or when the supervisor asks to be kept posted):
while still working you MAY send intermediate updates with exactly this shell command, then KEEP WORKING:
  claude -p '[$CODE]: PROGRESS: what you just finished' --cloud $SUPERVISOR_SESSION --output-format json
Rules: keep the single quotes; put NO apostrophes inside the message (write \"do not\", not \"don't\");
keep it under 300 characters; at most one update every few minutes. It prints {\"ok\":true} on success.
If it fails, ignore the failure and keep working - never retry in a loop, never try another way to
reach the supervisor. Only PROGRESS is ever sent this way. Never self-send DONE, ERROR, or QUESTION.
Write clean, documented, production-quality code."
fi
if [[ -n "$EXTRA_SYSTEM_PROMPT" ]]; then
    SYS_PROMPT="$SYS_PROMPT

$EXTRA_SYSTEM_PROMPT"
fi

TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
OUTPUT_FILE="$OPS_DIR/run-$TIMESTAMP-$$.json"
STDERR_FILE="$OPS_DIR/stderr-$TIMESTAMP-$$.log"
SYS_FILE="$OPS_DIR/sysprompt-$TIMESTAMP-$$.txt"
_safe_prepare "$OUTPUT_FILE"; _safe_prepare "$STDERR_FILE"; _safe_prepare "$SYS_FILE"
printf '%s' "$SYS_PROMPT" > "$SYS_FILE"

# --- claude args ---
CL_ARGS=(
    "-p" "$PROMPT"
    "--max-turns" "$MAX_TURNS"
    "--output-format" "json"
    "--dangerously-skip-permissions"
    "--append-system-prompt-file" "$SYS_FILE"
)
[[ -n "$MODEL" ]]  && CL_ARGS+=("--model" "$MODEL")
[[ -n "$EFFORT" ]] && CL_ARGS+=("--effort" "$EFFORT")
if [[ "$CONTINUE" != "true" ]] && [[ -z "$RESUME" ]]; then
    CL_ARGS+=("--session-id" "$session_id")
elif [[ "$CONTINUE" == "true" ]]; then
    CL_ARGS+=("--continue")
else
    CL_ARGS+=("--resume" "$RESUME")
fi

cd "$PROJECT_DIR" || { echo "ERROR: cannot cd to $PROJECT_DIR" >&2; exit 1; }
START_TIME=$(date +%s)
log "Claude Code running..."

OUTPUT=$("$CLAUDE_PATH" "${CL_ARGS[@]}" 2>"$STDERR_FILE") || true
printf '%s\n' "$OUTPUT" > "$OUTPUT_FILE"

STDERR_CONTENT=""
if [[ -f "$STDERR_FILE" ]]; then
    STDERR_CONTENT=$(tr -s '[:space:]' ' ' < "$STDERR_FILE" 2>/dev/null)
    [[ -n "$STDERR_CONTENT" ]] && log "STDERR: $STDERR_CONTENT"
fi

ELAPSED_SECONDS=$(( $(date +%s) - START_TIME ))
ELAPSED_MINUTES=$(awk "BEGIN {printf \"%.1f\", $ELAPSED_SECONDS / 60}")
log "Claude Code exited after ${ELAPSED_MINUTES} minutes"

# --- Parse output ---
IS_ERROR=true; STATUS="unknown"; TURNS=0; COST=0; SESSION_OUT="$session_id"; RESULT_TEXT=""
if [[ -s "$OUTPUT_FILE" ]]; then
    STATUS=$(json_field "$OUTPUT_FILE" "subtype")
    TURNS=$(json_field "$OUTPUT_FILE" "num_turns")
    RAW_COST=$(json_field "$OUTPUT_FILE" "total_cost_usd")
    COST=$(awk "BEGIN {printf \"%.4f\", ${RAW_COST:-0} + 0}")
    SESSION_OUT=$(json_field "$OUTPUT_FILE" "session_id")
    RESULT_TEXT=$(json_field "$OUTPUT_FILE" "result")
    if [[ -n "$SESSION_OUT" ]]; then
        _sid_tmp=$(mktemp "$OPS_DIR/.sid.XXXXXX") && printf '%s\n' "$SESSION_OUT" > "$_sid_tmp" && mv -f "$_sid_tmp" "$OPS_DIR/SESSION_ID"
    fi
    log "Status: $STATUS | Turns: $TURNS | Cost: \$$COST | Session: $SESSION_OUT"
    [[ "$STATUS" == "success" ]] && IS_ERROR=false
else
    log "ERROR: Could not parse output. See $OUTPUT_FILE"
fi

# --- Report ---
if [[ "$SYNC" == "true" ]]; then
    if [[ "$IS_ERROR" == "true" ]]; then
        echo "ERROR: $PROJECT_NAME | status=$STATUS | turns=$TURNS | cost=\$$COST | ${ELAPSED_MINUTES}min - session=$SESSION_OUT"
    else
        echo "OK: $PROJECT_NAME | turns=$TURNS | cost=\$$COST | ${ELAPSED_MINUTES}min - session=$SESSION_OUT"
    fi
    [[ -n "$RESULT_TEXT" ]] && { echo ""; echo "$RESULT_TEXT"; }
else
    # The runner is the SOLE sender of the terminal message: exactly one per dispatch.
    TRIMMED=$(printf '%s' "$RESULT_TEXT" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if [[ "$IS_ERROR" == "true" ]]; then
        HINT="${TRIMMED:-$STDERR_CONTENT}"
        [[ ${#HINT} -gt $SUMMARY_CHARS ]] && HINT="${HINT:0:$SUMMARY_CHARS}..."
        MSG="[$CODE]: ERROR: $PROJECT_NAME exited status=$STATUS, $TURNS turns, cost=$COST, ${ELAPSED_MINUTES}min - $HINT"
        log "Sending ERROR"
    elif [[ "$TRIMMED" == QUESTION:* ]]; then
        QTEXT="${TRIMMED#QUESTION:}"; QTEXT="${QTEXT# }"
        [[ ${#QTEXT} -gt $SUMMARY_CHARS ]] && QTEXT="${QTEXT:0:$SUMMARY_CHARS}..."
        MSG="[$CODE]: QUESTION: $QTEXT"
        log "Sending QUESTION"
    else
        SUMMARY="$TRIMMED"
        [[ ${#SUMMARY} -gt $SUMMARY_CHARS ]] && SUMMARY="${SUMMARY:0:$SUMMARY_CHARS}..."
        MSG="[$CODE]: DONE: $PROJECT_NAME | ${TURNS} turns | cost=$COST | ${ELAPSED_MINUTES}min - $SUMMARY"
        log "Sending DONE"
    fi

    # Keep the terminal message on disk before trying to deliver it.
    LAST_MSG="$OPS_DIR/last-message-$CODE.txt"; _safe_prepare "$LAST_MSG"
    printf '%s\n' "$MSG" > "$LAST_MSG"

    if send_supervisor "$MSG"; then
        log "Terminal message delivered"
    else
        UNDELIVERED="$OPS_DIR/UNDELIVERED-$CODE.txt"; _safe_prepare "$UNDELIVERED"
        printf '%s\n' "$MSG" > "$UNDELIVERED"
        log "DELIVERY FAILED. Message saved to $UNDELIVERED. Check 'claude auth status' on this machine."
    fi
fi

log "=== Runner complete ==="
