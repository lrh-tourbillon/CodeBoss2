#!/usr/bin/env bash
# dispatch.sh - CodeBoss2 entry point (macOS). Launches Claude Code via run-phase.sh.
#
# ASYNC (default): backgrounds the runner with nohup and returns at once with a security code. When
# the run ends, the runner reports to the supervising Cowork session with
# `claude -p "[code]: ..." --cloud <supervisor-session>`. No UI automation.
# SYNC (--sync): blocks until CC exits and prints its output. No code, no supervisor needed.
#
# macOS equivalent of dispatch.ps1. Normally invoked by the codeboss-host connector.

set -euo pipefail

PROJECT_DIR=""; PROMPT=""; SUPERVISOR_SESSION=""; MAX_TURNS=50
CONTINUE=false; RESUME=""; EXTRA_SYSTEM_PROMPT=""; MODEL=""; EFFORT=""
SYNC=false; SKIP_AUTH_CHECK=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir)          PROJECT_DIR="$2"; shift 2 ;;
        --prompt)               PROMPT="$2"; shift 2 ;;
        --supervisor-session)   SUPERVISOR_SESSION="$2"; shift 2 ;;
        --max-turns)            MAX_TURNS="$2"; shift 2 ;;
        --continue)             CONTINUE=true; shift ;;
        --resume)               RESUME="$2"; shift 2 ;;
        --extra-system-prompt)  EXTRA_SYSTEM_PROMPT="$2"; shift 2 ;;
        --model)                MODEL="$2"; shift 2 ;;
        --effort)               EFFORT="$2"; shift 2 ;;
        --sync)                 SYNC=true; shift ;;
        --skip-auth-check)      SKIP_AUTH_CHECK=true; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

[[ -n "$PROJECT_DIR" ]] || { echo "ERROR: --project-dir is required" >&2; exit 1; }
[[ -n "$PROMPT" ]]      || { echo "ERROR: --prompt is required" >&2; exit 1; }
[[ -d "$PROJECT_DIR" ]] || { echo "ERROR: project dir does not exist: $PROJECT_DIR" >&2; exit 1; }

SCRIPTS_DIR="$HOME/Library/Application Support/codeboss"
RUNNER="$SCRIPTS_DIR/run-phase.sh"
[[ -f "$RUNNER" ]] || { echo "ERROR: CodeBoss2 scripts not found at $SCRIPTS_DIR. Run: python3 <plugin>/skills/codeboss/scripts/macos/codeboss-host.py --install" >&2; exit 1; }

PROJECT_NAME=$(basename "$PROJECT_DIR")

# --- Locate claude for the auth preflight (same lookup order as run-phase.sh) ---
for extra_bin in "/opt/homebrew/bin" "/usr/local/bin" "$HOME/.local/bin" "$HOME/.npm-global/bin"; do
    case ":$PATH:" in *":$extra_bin:"*) : ;; *) [[ -d "$extra_bin" ]] && PATH="$extra_bin:$PATH" ;; esac
done
export PATH
CLAUDE_PATH=$(command -v claude 2>/dev/null || true)
if [[ -z "$CLAUDE_PATH" ]]; then
    for c in "/opt/homebrew/bin/claude" "/usr/local/bin/claude" "$HOME/.local/bin/claude" "$HOME/.npm-global/bin/claude"; do
        [[ -x "$c" ]] && { CLAUDE_PATH="$c"; break; }
    done
fi
[[ -n "$CLAUDE_PATH" ]] || { echo "ERROR: cannot find the claude CLI on this Mac." >&2; exit 1; }

# --- Auth preflight: the report-back channel is this Mac's claude.ai login. Fail loudly now. ---
AUTH_NOTE="Auth=skipped"
if [[ "$SKIP_AUTH_CHECK" != "true" ]]; then
    AUTH_JSON=$("$CLAUDE_PATH" auth status 2>/dev/null || true)
    read -r LOGGED_IN AUTH_METHOD EXPIRES < <(printf '%s' "$AUTH_JSON" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(str(bool(d.get("loggedIn"))).lower(), d.get("authMethod") or "none", d.get("loginExpiresAt") or "-")
except Exception:
    print("false none -")' 2>/dev/null || echo "false none -")
    if [[ "$LOGGED_IN" != "true" ]]; then
        echo "ERROR: the claude CLI on this Mac is not logged in to claude.ai, so Claude Code could not report back. Run: claude auth login" >&2
        exit 2
    fi
    if [[ "$AUTH_METHOD" != "claude.ai" ]]; then
        echo "ERROR: claude CLI authMethod is '$AUTH_METHOD'; session messaging needs a claude.ai login (claude auth login)." >&2
        exit 2
    fi
    AUTH_NOTE="Auth=ok"
    if [[ "$EXPIRES" != "-" ]]; then
        AUTH_NOTE="Auth=ok(expires $EXPIRES)"
        EXP_EPOCH=$(python3 -c 'import sys,datetime
s=sys.argv[1].replace("Z","+00:00")
try:
    print(int(datetime.datetime.fromisoformat(s).timestamp()))
except Exception:
    print(0)' "$EXPIRES" 2>/dev/null || echo 0)
        if [[ "$EXP_EPOCH" -gt 0 ]]; then
            HOURS_LEFT=$(( (EXP_EPOCH - $(date +%s)) / 3600 ))
            [[ $HOURS_LEFT -lt 48 ]] && AUTH_NOTE="$AUTH_NOTE WARNING: login expires in ${HOURS_LEFT} h - run 'claude auth login' soon"
        fi
    fi
fi

if [[ "$SYNC" == "true" ]]; then
    RUN_ARGS=(--project-dir "$PROJECT_DIR" --prompt "$PROMPT" --max-turns "$MAX_TURNS" --sync)
    [[ "$CONTINUE" == "true" ]]    && RUN_ARGS+=(--continue)
    [[ -n "$RESUME" ]]             && RUN_ARGS+=(--resume "$RESUME")
    [[ -n "$EXTRA_SYSTEM_PROMPT" ]] && RUN_ARGS+=(--extra-system-prompt "$EXTRA_SYSTEM_PROMPT")
    [[ -n "$MODEL" ]]              && RUN_ARGS+=(--model "$MODEL")
    [[ -n "$EFFORT" ]]             && RUN_ARGS+=(--effort "$EFFORT")
    exec bash "$RUNNER" "${RUN_ARGS[@]}"
fi

# --- Async ---
[[ "$SUPERVISOR_SESSION" =~ ^session_[A-Za-z0-9]+$ ]] || {
    echo "ERROR: async dispatch needs --supervisor-session session_... : the session_ segment of the supervising chat's URL (claude.ai/code/session_...)" >&2; exit 1; }

CODE=$(openssl rand -hex 3)
OPS_DIR="$PROJECT_DIR/.codeboss/ops"
mkdir -p "$OPS_DIR"

TS="$(date '+%Y%m%d-%H%M%S')-$$"
PROMPT_FILE="$OPS_DIR/.prompt-temp-$TS.txt"
printf '%s' "$PROMPT" > "$PROMPT_FILE"

RUN_ARGS=(--project-dir "$PROJECT_DIR" --prompt-file "$PROMPT_FILE" --max-turns "$MAX_TURNS" --code "$CODE" --supervisor-session "$SUPERVISOR_SESSION")
[[ "$CONTINUE" == "true" ]] && RUN_ARGS+=(--continue)
[[ -n "$RESUME" ]]          && RUN_ARGS+=(--resume "$RESUME")
[[ -n "$MODEL" ]]           && RUN_ARGS+=(--model "$MODEL")
[[ -n "$EFFORT" ]]          && RUN_ARGS+=(--effort "$EFFORT")
if [[ -n "$EXTRA_SYSTEM_PROMPT" ]]; then
    SYS_FILE="$OPS_DIR/.sysprompt-temp-$TS.txt"
    printf '%s' "$EXTRA_SYSTEM_PROMPT" > "$SYS_FILE"
    RUN_ARGS+=(--extra-system-prompt-file "$SYS_FILE")
fi

nohup bash "$RUNNER" "${RUN_ARGS[@]}" > /dev/null 2>&1 &
LAUNCHER="nohup:$!"

MODE="NEW"; [[ "$CONTINUE" == "true" ]] && MODE="CONTINUE"; [[ -n "$RESUME" ]] && MODE="RESUME"
MODEL_NOTE=""; [[ -n "$MODEL$EFFORT" ]] && MODEL_NOTE=" | Model=$MODEL Effort=$EFFORT"
echo "Dispatched [$MODE]: Project=$PROJECT_NAME, MaxTurns=$MAX_TURNS, Code=$CODE, Supervisor=$SUPERVISOR_SESSION | $AUTH_NOTE | Launcher=$LAUNCHER$MODEL_NOTE"
