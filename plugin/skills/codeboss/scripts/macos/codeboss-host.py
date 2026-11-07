#!/usr/bin/env python3
"""codeboss-host.py - macOS host connector for CodeBoss2 (MCP server).

Cowork runs in a sandboxed VM and cannot launch programs on the host Mac. This is the macOS
analog of the Windows MCP connector: a small MCP server that Claude Desktop launches ON THE HOST,
giving the Cowork supervisor a controlled bridge to the CodeBoss scripts.

It is deliberately SCOPED. It exposes only CodeBoss operations -- never a general shell:
  - codeboss_dispatch : run dispatch.sh (async with a supervisor session, or sync)
  - codeboss_status   : health check (scripts installed? claude found? claude.ai login?)
  - codeboss_read_ops : tail the latest runner log and show the last terminal message(s)

CodeBoss2 report-back: the runner (and optionally Claude Code itself) posts into the supervising
Cowork session with `claude -p "[code]: ..." --cloud <session_id>`, using this Mac's claude.ai
login. No UI automation, no Accessibility permission.

Trust boundary: codeboss_dispatch runs Claude Code with --dangerously-skip-permissions in the given
project_dir, so within a dispatch CC can read/write broadly, bounded only by its system prompt.
"Scoped" means the connector's own tool surface (no arbitrary shell), NOT a filesystem sandbox
around CC. Only dispatch to directories you trust.

Transport: MCP over stdio, newline-delimited JSON-RPC 2.0. stdlib only. Runs on /usr/bin/python3 (3.9+).
stdout carries ONLY JSON-RPC messages. All logging goes to stderr.
"""

import glob
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

SERVER_NAME = "codeboss-host"
SERVER_VERSION = "2.0.0"
DEFAULT_PROTOCOL = "2025-06-18"

SUPPORT_DIR = os.path.expanduser("~/Library/Application Support/codeboss")
SCRIPTS = {
    "dispatch.sh": os.path.join(SUPPORT_DIR, "dispatch.sh"),
    "run-phase.sh": os.path.join(SUPPORT_DIR, "run-phase.sh"),
}
DISPATCH = SCRIPTS["dispatch.sh"]

CLAUDE_CANDIDATES = [
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
    os.path.expanduser("~/.local/bin/claude"),
    os.path.expanduser("~/.npm-global/bin/claude"),
]

# A sane host PATH prepended for child scripts: Claude Desktop launches this server with a minimal
# GUI environment.
HOST_PATH = ":".join([
    "/opt/homebrew/bin", "/usr/local/bin", os.path.expanduser("~/.local/bin"),
    "/usr/bin", "/bin", "/usr/sbin", "/sbin",
])

SESSION_RE = re.compile(r"^session_[A-Za-z0-9]+$")


def log(*args):
    print("[%s]" % SERVER_NAME, *args, file=sys.stderr, flush=True)


_LOGIN_ENV = None


def _parse_env_json(text):
    try:
        return json.loads(text)
    except ValueError:
        pass
    for line in reversed((text or "").splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                return json.loads(line)
            except ValueError:
                continue
    return None


def login_env():
    """Return the user's real login-shell environment (cached).

    Claude Desktop launches this server with a minimal GUI environment. Recover the user's PATH
    additions (Homebrew, nvm, ...) and any shell-exported variables by running their login shell
    interactively and dumping its environment. Falls back to the bare environment.
    """
    global _LOGIN_ENV
    if _LOGIN_ENV is not None:
        return _LOGIN_ENV
    shell = os.environ.get("SHELL") or "/bin/zsh"
    dump = ('/usr/bin/python3 -c '
            '"import os,json,sys;sys.stdout.write(json.dumps(dict(os.environ)))"')
    for flags in (["-i", "-l", "-c"], ["-l", "-c"], ["-c"]):
        try:
            proc = subprocess.run(
                [shell] + flags + [dump],
                capture_output=True, text=True, timeout=12, stdin=subprocess.DEVNULL,
            )
        except Exception as exc:  # noqa: BLE001
            log("login env capture (%s) failed: %s" % (" ".join(flags), exc))
            continue
        parsed = _parse_env_json((proc.stdout or "").strip())
        if parsed:
            log("recovered login-shell env via '%s %s' (%d vars)" % (shell, " ".join(flags), len(parsed)))
            _LOGIN_ENV = parsed
            return _LOGIN_ENV
    log("could not capture login-shell env; using bare environment")
    _LOGIN_ENV = dict(os.environ)
    return _LOGIN_ENV


def _dedupe_path(path):
    seen = set()
    parts = []
    for p in path.split(":"):
        if p and p not in seen:
            seen.add(p)
            parts.append(p)
    return ":".join(parts)


def _kill_group(proc):
    """Terminate the whole process group (bash -> claude), escalating to SIGKILL."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(proc.pid, sig)
        except Exception:  # noqa: BLE001
            pass
        try:
            proc.communicate(timeout=5)
            return
        except subprocess.TimeoutExpired:
            continue


def _child_env():
    env = dict(login_env())
    env["PATH"] = _dedupe_path(HOST_PATH + ":" + env.get("PATH", ""))
    return env


def _run(cmd_args, timeout):
    """Run a fixed argument list (never a shell string) in its own process group."""
    try:
        proc = subprocess.Popen(
            cmd_args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env=_child_env(), stdin=subprocess.DEVNULL, start_new_session=True,
        )
    except Exception as exc:  # noqa: BLE001
        return 1, "", "failed to run: %s" % exc
    try:
        out, err = proc.communicate(timeout=timeout)
        return proc.returncode, out or "", err or ""
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        return 124, "", "timed out after %ss (process group terminated)" % timeout


def _find_claude(env):
    search_path = HOST_PATH + ":" + env.get("PATH", "")
    claude = shutil.which("claude", path=search_path)
    if claude:
        return claude
    for c in CLAUDE_CANDIDATES:
        if os.access(c, os.X_OK):
            return c
    try:
        npm_env = {"PATH": search_path, "HOME": env.get("HOME", os.path.expanduser("~"))}
        for k, v in env.items():
            if k.lower().startswith("npm_config"):
                npm_env[k] = v
        prefix = subprocess.run(
            ["npm", "config", "get", "prefix"], capture_output=True, text=True,
            timeout=10, env=npm_env, stdin=subprocess.DEVNULL,
        ).stdout.strip()
        cand = os.path.join(prefix, "bin", "claude") if prefix else ""
        if cand and os.access(cand, os.X_OK):
            return cand
    except Exception:  # noqa: BLE001
        pass
    return None


def _auth_status(claude):
    """Return (loggedIn: bool, authMethod: str, expires: str) from `claude auth status`."""
    if not claude:
        return False, "none", ""
    rc, out, _err = _run([claude, "auth", "status"], 20)
    d = _parse_env_json(out.strip()) or {}
    return bool(d.get("loggedIn")), str(d.get("authMethod") or "none"), str(d.get("loginExpiresAt") or "")


# --- Tool definitions ---

TOOLS = [
    {
        "name": "codeboss_dispatch",
        "description": (
            "Dispatch a task to Claude Code (headless) on the host Mac via CodeBoss2. "
            "mode=async (default) fires and returns a 'Code=' line at once; Claude Code then reports "
            "PROGRESS/QUESTION/DONE/ERROR into the Cowork session named by supervisor_session as user "
            "turns prefixed with [Code]:. mode=sync blocks until Claude Code exits and returns its "
            "output directly (keep it short). This is the only way to run Claude Code; it does not "
            "expose a general shell."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string", "description": "Absolute path to the project directory Claude Code works in."},
                "prompt": {"type": "string", "description": "The task description for Claude Code."},
                "supervisor_session": {
                    "type": "string",
                    "description": "Required for async: the session_... id of the supervising Cowork chat (the session_ segment of its URL).",
                },
                "max_turns": {"type": "integer", "description": "Max agentic turns before CC exits (default 50).", "default": 50},
                "mode": {"type": "string", "enum": ["async", "sync"], "description": "async (default) or sync.", "default": "async"},
                "continue_session": {"type": "boolean", "description": "Resume the most recent CC session for this project.", "default": False},
                "resume": {"type": "string", "description": "Resume a specific CC session by id."},
                "extra_system_prompt": {"type": "string", "description": "Extra task-specific system prompt appended for CC."},
                "model": {"type": "string", "description": "Passed to claude as --model (e.g. claude-fable-5-1)."},
                "effort": {"type": "string", "description": "Passed to claude as --effort (low|medium|high|xhigh)."},
            },
            "required": ["project_dir", "prompt"],
        },
    },
    {
        "name": "codeboss_status",
        "description": (
            "Health check for the CodeBoss2 host install: scripts present and executable, claude CLI "
            "located, and whether it is logged in to claude.ai (the report-back channel)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "refresh": {"type": "boolean", "description": "Re-capture the login-shell environment first.", "default": False},
            },
        },
    },
    {
        "name": "codeboss_read_ops",
        "description": (
            "Tail the latest CodeBoss runner log for a project and show any last-message-*.txt / "
            "UNDELIVERED-*.txt, to troubleshoot a dispatch or recover a result that never arrived."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string", "description": "Absolute project path."},
                "lines": {"type": "integer", "description": "Log lines to tail (default 40).", "default": 40},
            },
            "required": ["project_dir"],
        },
    },
]


# --- Tool implementations. Each returns (is_error, text). ---

def tool_dispatch(args):
    project_dir = args.get("project_dir")
    prompt = args.get("prompt")
    if not project_dir or not prompt:
        return True, "project_dir and prompt are both required."
    if not os.path.isabs(project_dir):
        return True, "project_dir must be an absolute path (got %r)." % project_dir
    if not os.path.isdir(project_dir):
        return True, "project_dir does not exist or is not a directory: %r" % project_dir
    if not os.path.isfile(DISPATCH):
        return True, "dispatch.sh not found at %s. Run codeboss-host.py --install first." % DISPATCH

    mode = args.get("mode", "async")
    if not isinstance(mode, str) or mode.lower() not in ("async", "sync"):
        return True, "mode must be 'async' or 'sync' (got %r)." % mode
    mode = mode.lower()
    try:
        max_turns = int(args.get("max_turns", 50) or 50)
    except (TypeError, ValueError):
        max_turns = 50

    supervisor = str(args.get("supervisor_session") or "").strip()
    if mode == "async":
        if not SESSION_RE.match(supervisor):
            return True, ("async dispatch needs supervisor_session = the session_... id of the "
                          "supervising Cowork chat (the session_ segment of its URL); got %r." % supervisor)

    cmd = ["/bin/bash", DISPATCH,
           "--project-dir", str(project_dir),
           "--prompt", str(prompt),
           "--max-turns", str(max_turns)]
    if mode == "sync":
        cmd.append("--sync")
    else:
        cmd += ["--supervisor-session", supervisor]
    if args.get("continue_session"):
        cmd.append("--continue")
    if args.get("resume"):
        cmd += ["--resume", str(args["resume"])]
    if args.get("extra_system_prompt"):
        cmd += ["--extra-system-prompt", str(args["extra_system_prompt"])]
    if args.get("model"):
        cmd += ["--model", str(args["model"])]
    if args.get("effort"):
        cmd += ["--effort", str(args["effort"])]

    timeout = 55 if mode == "sync" else 40
    rc, out, err = _run(cmd, timeout)
    text = out.strip()
    if err.strip():
        text = (text + "\n[stderr] " + err.strip()).strip()
    if rc != 0:
        return True, "dispatch.sh exited %s.\n%s" % (rc, text or "(no output)")
    return False, text or "(dispatch produced no output)"


def tool_status(args):
    if args.get("refresh"):
        global _LOGIN_ENV
        _LOGIN_ENV = None
    lines = []
    all_ok = True
    for name, path in SCRIPTS.items():
        present = os.path.isfile(path)
        execable = present and os.access(path, os.X_OK)
        all_ok = all_ok and execable
        state = "present" if present else "MISSING"
        if present and not execable:
            state += " (NOT executable)"
        lines.append("  %-18s %s" % (name + ":", state))
    stale = [n for n in ("send-claude-message.sh",) if os.path.isfile(os.path.join(SUPPORT_DIR, n))]
    if stale:
        lines.append("  %-18s %s" % ("v1 leftovers:", ", ".join(stale) + " (unused; safe to delete)"))

    env = login_env()
    claude = _find_claude(env)
    logged_in, method, expires = _auth_status(claude)
    lines.append("  %-18s %s" % ("claude CLI:", claude or "not found in common locations"))
    if logged_in and method == "claude.ai":
        lines.append("  %-18s claude.ai%s" % ("claude auth:", (" (expires %s)" % expires) if expires else ""))
    else:
        lines.append("  %-18s NOT logged in to claude.ai (loggedIn=%s, authMethod=%s) - run: claude auth login"
                     % ("claude auth:", logged_in, method))
    lines.append("  %-18s %s" % ("support_dir:", SUPPORT_DIR))
    ok = all_ok and claude is not None and logged_in and method == "claude.ai"
    header = "CodeBoss2 host connector OK" if ok else "CodeBoss2 host connector: NEEDS ATTENTION"
    return (not ok), header + "\n" + "\n".join(lines)


def _safe_files(ops_dir, pattern):
    out = []
    for p in glob.glob(os.path.join(ops_dir, pattern)):
        try:
            if os.path.islink(p):
                continue
            real = os.path.realpath(p)
            if real.startswith(ops_dir + os.sep) and os.path.isfile(real):
                out.append((os.path.getmtime(real), real))
        except OSError:
            continue
    out.sort()
    return [p for _, p in out]


def tool_read_ops(args):
    project_dir = args.get("project_dir")
    if not project_dir:
        return True, "project_dir is required."
    if not os.path.isabs(project_dir):
        return True, "project_dir must be an absolute path (got %r)." % project_dir
    ops_dir = os.path.join(os.path.realpath(project_dir), ".codeboss", "ops")
    logs = _safe_files(ops_dir, "runner-*.log")
    if not logs:
        return True, "No readable runner logs found under %s" % ops_dir
    latest = logs[-1]
    try:
        n = int(args.get("lines", 40) or 40)
    except (TypeError, ValueError):
        n = 40
    try:
        with open(latest, "r", errors="replace") as fh:
            tail = "".join(fh.readlines()[-n:])
    except OSError as exc:
        return True, "Could not read %s: %s" % (latest, exc)
    parts = ["== %s ==\n%s" % (latest, tail)]
    for pattern in ("UNDELIVERED-*.txt", "last-message-*.txt"):
        for p in _safe_files(ops_dir, pattern)[-3:]:
            try:
                with open(p, "r", errors="replace") as fh:
                    parts.append("== %s ==\n%s" % (p, fh.read().strip()))
            except OSError:
                continue
    return False, "\n\n".join(parts)


TOOL_FUNCS = {
    "codeboss_dispatch": tool_dispatch,
    "codeboss_status": tool_status,
    "codeboss_read_ops": tool_read_ops,
}


# --- JSON-RPC / MCP plumbing ---

def _send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def _result(msg_id, result):
    _send({"jsonrpc": "2.0", "id": msg_id, "result": result})


def _error(msg_id, code, message):
    _send({"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}})


def handle(req):
    if not isinstance(req, dict):
        _error(None, -32600, "Invalid Request: expected a JSON object")
        return
    method = req.get("method")
    msg_id = req.get("id")
    if not isinstance(method, str):
        _error(msg_id, -32600, "Invalid Request: missing or non-string 'method'")
        return
    params = req.get("params")
    if params is not None and not isinstance(params, dict):
        _error(msg_id, -32602, "Invalid params: expected an object")
        return
    if msg_id is None:
        return  # notifications never get a response

    if method == "initialize":
        params = req.get("params") or {}
        proto = params.get("protocolVersion") or DEFAULT_PROTOCOL
        _result(msg_id, {
            "protocolVersion": proto,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        })
    elif method == "ping":
        _result(msg_id, {})
    elif method == "tools/list":
        _result(msg_id, {"tools": TOOLS})
    elif method == "tools/call":
        params = req.get("params") or {}
        name = params.get("name")
        args = params.get("arguments") or {}
        func = TOOL_FUNCS.get(name)
        if func is None:
            _error(msg_id, -32602, "Unknown tool: %s" % name)
            return
        try:
            is_error, text = func(args)
        except Exception as exc:  # noqa: BLE001
            is_error, text = True, "tool error: %s" % exc
        _result(msg_id, {"content": [{"type": "text", "text": text}], "isError": bool(is_error)})
    elif method == "resources/list":
        _result(msg_id, {"resources": []})
    elif method == "prompts/list":
        _result(msg_id, {"prompts": []})
    else:
        _error(msg_id, -32601, "Method not found: %s" % method)


def serve():
    log("starting", SERVER_VERSION, "support_dir=%s" % SUPPORT_DIR)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError as exc:
            log("parse error:", exc)
            _error(None, -32700, "Parse error")
            continue
        try:
            if isinstance(req, list):
                if not req:
                    _error(None, -32600, "Invalid Request: empty batch")
                else:
                    for item in req:
                        handle(item)
            else:
                handle(req)
        except Exception as exc:  # noqa: BLE001
            log("handler error:", exc)
    log("stdin closed; exiting")


# --- Installer: python3 codeboss-host.py --install ---

BUNDLE = ["dispatch.sh", "run-phase.sh", "codeboss-host.py"]
V1_LEFTOVERS = ["send-claude-message.sh"]


def _chmod_x(path):
    os.chmod(path, os.stat(path).st_mode | 0o111)


def discover_config_dirs():
    """Claude Desktop config dir(s): CODEBOSS_CLAUDE_CONFIG_DIR, else ~/Library/Application Support/Claude*
    that already contain claude_desktop_config.json."""
    override = os.environ.get("CODEBOSS_CLAUDE_CONFIG_DIR")
    if override:
        d = os.path.expanduser(override)
        return [d] if os.path.isdir(d) else []
    base = os.path.expanduser("~/Library/Application Support")
    dirs = []
    try:
        for name in sorted(os.listdir(base)):
            if not re.match(r"^Claude(-[A-Za-z0-9._-]+)?$", name):
                continue
            d = os.path.join(base, name)
            if os.path.isdir(d) and os.path.isfile(os.path.join(d, "claude_desktop_config.json")):
                dirs.append(d)
    except OSError:
        pass
    return dirs


def _deploy_bundle():
    src_dir = os.path.dirname(os.path.abspath(__file__))
    os.makedirs(SUPPORT_DIR, exist_ok=True)
    deployed, problems = [], []
    for fn in BUNDLE:
        src = os.path.join(src_dir, fn)
        dst = os.path.join(SUPPORT_DIR, fn)
        if os.path.abspath(src) != os.path.abspath(dst):
            if os.path.isfile(src):
                shutil.copy2(src, dst)
            elif os.path.isfile(dst):
                problems.append("%s (source missing; kept existing copy)" % fn)
            else:
                problems.append("%s (source missing; NOT deployed)" % fn)
                continue
        if os.path.isfile(dst):
            _chmod_x(dst)
            deployed.append(fn)
    for fn in V1_LEFTOVERS:
        p = os.path.join(SUPPORT_DIR, fn)
        if os.path.isfile(p):
            try:
                os.remove(p)
                deployed.append("(removed v1 %s)" % fn)
            except OSError:
                problems.append("%s (v1 leftover; could not remove)" % fn)
    return deployed, problems


def _register(cfg_dir):
    cfg_path = os.path.join(cfg_dir, "claude_desktop_config.json")
    cfg = {}
    if os.path.isfile(cfg_path):
        with open(cfg_path) as f:
            raw = f.read()
        if raw.strip():
            try:
                cfg = json.loads(raw)
            except ValueError as exc:
                raise RuntimeError("%s is not valid JSON (%s). Left untouched." % (cfg_path, exc))
            if not isinstance(cfg, dict):
                raise RuntimeError("%s does not contain a JSON object; left untouched." % cfg_path)
        existing = cfg.get("mcpServers")
        if existing is not None and not isinstance(existing, dict):
            raise RuntimeError("%s has a non-object 'mcpServers'; left untouched." % cfg_path)
        shutil.copy2(cfg_path, "%s.codeboss-bak-%d" % (cfg_path, int(time.time())))
    cfg.setdefault("mcpServers", {})["codeboss-host"] = {
        "command": "/usr/bin/python3",
        "args": [os.path.join(SUPPORT_DIR, "codeboss-host.py")],
    }
    with open(cfg_path, "w") as f:
        json.dump(cfg, f, indent=2)
    return cfg_path


def _unregister(cfg_dir):
    cfg_path = os.path.join(cfg_dir, "claude_desktop_config.json")
    if not os.path.isfile(cfg_path):
        return None
    try:
        with open(cfg_path) as f:
            cfg = json.load(f)
    except ValueError:
        return None
    if not isinstance(cfg, dict):
        return None
    servers = cfg.get("mcpServers")
    if not isinstance(servers, dict) or "codeboss-host" not in servers:
        return None
    shutil.copy2(cfg_path, "%s.codeboss-bak-%d" % (cfg_path, int(time.time())))
    del servers["codeboss-host"]
    if not servers:
        cfg.pop("mcpServers", None)
    with open(cfg_path, "w") as f:
        json.dump(cfg, f, indent=2)
    return cfg_path


def cli(mode):
    if mode in ("--help", "-h"):
        print("Usage: codeboss-host.py [--install | --uninstall | --status]")
        print("  (no args)   run as the MCP server (how Claude Desktop launches it)")
        return 0
    if mode == "--status":
        is_error, text = tool_status({})
        print(text)
        return 1 if is_error else 0

    dirs = discover_config_dirs()
    if not dirs:
        override = os.environ.get("CODEBOSS_CLAUDE_CONFIG_DIR")
        if override:
            print("CODEBOSS_CLAUDE_CONFIG_DIR is set to %r but that directory does not exist."
                  % os.path.expanduser(override))
        else:
            print("No Claude Desktop config directory found under ~/Library/Application Support/Claude*.")
            print("If yours is elsewhere, set CODEBOSS_CLAUDE_CONFIG_DIR and re-run.")
        return 1

    if mode == "--install":
        if len(dirs) > 1 and not os.environ.get("CODEBOSS_CLAUDE_CONFIG_DIR"):
            print("Multiple Claude Desktop config directories were found:")
            for d in dirs:
                print("  " + d)
            print("Set CODEBOSS_CLAUDE_CONFIG_DIR to the one your Claude Desktop uses, then re-run --install.")
            return 1
        deployed, problems = _deploy_bundle()
        print("Deployed to %s:\n  %s" % (SUPPORT_DIR, ", ".join(deployed)))
        for p in problems:
            print("  WARNING: %s" % p)
        failed = False
        for d in dirs:
            try:
                print("Registered codeboss-host in %s" % _register(d))
            except RuntimeError as exc:
                print("SKIPPED %s: %s" % (d, exc))
                failed = True
        print("\nNext steps:")
        print("  1. Open Claude Desktop (it reads this config at launch). If it was running during")
        print("     install, fully quit (Cmd+Q) and reopen.")
        print("  2. Make sure the claude CLI is logged in: `claude auth status` -> loggedIn true,")
        print("     authMethod claude.ai. If not: `claude auth login`.")
        print("  3. In Cowork, run the codeboss_status tool (expect 'claude auth: claude.ai').")
        print("  No Accessibility permission is needed: CodeBoss2 does not type into any window.")
        return 1 if failed else 0

    if mode == "--uninstall":
        for d in dirs:
            path = _unregister(d)
            print("Removed codeboss-host from %s" % path if path else
                  "codeboss-host not present in %s" % os.path.join(d, "claude_desktop_config.json"))
        print("Deployed scripts left in %s (remove manually if desired). Restart Claude Desktop." % SUPPORT_DIR)
        return 0

    print("Unknown option: %s (try --help)" % mode)
    return 2


def main():
    if len(sys.argv) > 1 and sys.argv[1].startswith("-"):
        return cli(sys.argv[1])
    serve()
    return 0


if __name__ == "__main__":
    sys.exit(main())
