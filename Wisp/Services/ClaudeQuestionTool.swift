import Foundation

enum ClaudeQuestionTool {
    static let version = "7"

    // Full Python MCP server source — human-readable
    static let serverScript = """
    #!/usr/bin/env python3
    \"\"\"Wisp MCP server providing WispAsk for Claude Code headless sessions.\"\"\"

    import json
    import os
    import sys
    import time

    SESSION_ID = os.environ.get("WISP_SESSION_ID", "default")
    QUESTION_FILE = f"/tmp/.wisp_ask_pending_{SESSION_ID}.json"
    RESPONSE_FILE = f"/tmp/.wisp_ask_response_{SESSION_ID}.json"

    TIMEOUT = 300  # 5 minutes


    def read_message():
        line = sys.stdin.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            return None
        return json.loads(line)


    def send_message(obj):
        data = json.dumps(obj)
        sys.stdout.write(data + chr(10))
        sys.stdout.flush()


    TOOL_DEF = {
        "name": "WispAsk",
        "description": (
            "Ask the Wisp app user a clarifying question and wait for their response before "
            "proceeding. Use when you need a decision or preference from the user. "
            "Prefer this over making assumptions."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "question": {
                    "type": "string",
                    "description": "The question to ask the user",
                },
                "options": {
                    "type": "array",
                    "description": "Optional list of choices for the user to select from",
                    "items": {
                        "type": "object",
                        "properties": {
                            "label": {"type": "string"},
                            "description": {"type": "string"},
                        },
                        "required": ["label"],
                    },
                },
            },
            "required": ["question"],
        },
    }


    def handle_ask_user_question(args, msg_id):
        # Clean up stale response file
        try:
            os.remove(RESPONSE_FILE)
        except OSError:
            pass

        # Write question for the app to pick up
        with open(QUESTION_FILE, "w") as f:
            json.dump(args, f)

        # Poll for response
        deadline = time.time() + TIMEOUT
        answer = "User did not respond. Use your best judgment and proceed."
        while time.time() < deadline:
            if os.path.exists(RESPONSE_FILE):
                try:
                    with open(RESPONSE_FILE) as f:
                        resp = json.load(f)
                    answer = resp.get("answer", answer)
                    os.remove(RESPONSE_FILE)
                    break  # only break on successful parse; retry if file is still being written
                except (OSError, json.JSONDecodeError):
                    pass
            time.sleep(0.2)

        # Clean up question file
        try:
            os.remove(QUESTION_FILE)
        except OSError:
            pass

        send_message({
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {"content": [{"type": "text", "text": answer}]},
        })


    def main():
        while True:
            msg = read_message()
            if msg is None:
                break

            method = msg.get("method", "")
            msg_id = msg.get("id")

            if method == "initialize":
                send_message({
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "result": {
                        "protocolVersion": "2025-11-25",
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "wisp-ask-user", "version": "1.0.0"},
                    },
                })
            elif method == "notifications/initialized":
                pass  # No response needed
            elif method == "tools/list":
                send_message({
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "result": {"tools": [TOOL_DEF]},
                })
            elif method == "tools/call":
                params = msg.get("params", {})
                if params.get("name") == "WispAsk":
                    handle_ask_user_question(params.get("arguments", {}), msg_id)
            # Ignore notifications (no id) and unknown methods


    if __name__ == "__main__":
        main()
    """

    // Shell command to read current installed version (empty string if not installed)
    static let checkVersionCommand = "cat ~/.wisp/claude-question/version 2>/dev/null || echo ''"

    // Shell command to make server.py executable after upload
    static let chmodCommand = "chmod +x ~/.wisp/claude-question/server.py"

    // File paths on the Sprite (absolute)
    static let serverPyPath = "/home/sprite/.wisp/claude-question/server.py"
    static let versionPath = "/home/sprite/.wisp/claude-question/version"

    // Per-session helpers — each chat uses its own files so concurrent sessions don't conflict
    static func sanitizedSessionId(_ sessionId: String) -> String {
        // Only allow alphanumeric, hyphens, and underscores
        sessionId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    static func mcpConfigJSON(for sessionId: String) -> String {
        let safe = sanitizedSessionId(sessionId)
        return #"{"mcpServers":{"askUser":{"command":"python3","args":["/home/sprite/.wisp/claude-question/server.py"],"env":{"WISP_SESSION_ID":""# + safe + #""}}}}"#
    }

    static func mcpConfigFilePath(for sessionId: String) -> String {
        "/tmp/.wisp_mcp_\(sanitizedSessionId(sessionId)).json"
    }

    static func responseFilePath(for sessionId: String) -> String {
        "/tmp/.wisp_ask_response_\(sanitizedSessionId(sessionId)).json"
    }
}

enum WispChannelBridge {
    static let version = "9"
    static let serviceName = "wisp-channel-bridge"
    static let httpPort = 39281

    static let basePath = "/home/sprite/.wisp/channel-bridge"
    static let bridgePyPath = "\(basePath)/bridge.py"
    static let channelPyPath = "\(basePath)/channel.py"
    static let versionPath = "\(basePath)/version"
    static let secretPath = "\(basePath)/bridge_secret"
    static let claudeTokenPath = "\(basePath)/claude_oauth_token"

    static let checkVersionCommand = "cat ~/.wisp/channel-bridge/version 2>/dev/null || echo ''"
    static let chmodCommand = "chmod +x ~/.wisp/channel-bridge/bridge.py ~/.wisp/channel-bridge/channel.py"
    static let minimumClaudeVersion = "2.1.81"
    static let checkClaudeVersionCommand = "claude --version 2>/dev/null | head -1 || echo ''"
    static let updateClaudeCommand = "claude update 2>&1 || npm update -g @anthropic-ai/claude-code 2>&1"

    static let serviceRequest = ServiceRequest(
        cmd: "python3",
        args: [bridgePyPath],
        needs: nil,
        httpPort: httpPort
    )

    static let bridgeScript = #"""
    #!/usr/bin/env python3
    """Wisp channel bridge.

    Runs as a single sprite service. Each Wisp chat gets its own persistent Claude
    process and helper channel server. HTTP is the app-facing API; Claude session
    JSONL files are the source of truth for outbound events.
    """

    from __future__ import annotations

    import hashlib
    import json
    import os
    import pty
    import re
    import signal
    import subprocess
    import sys
    import threading
    import time
    import uuid
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from pathlib import Path
    from urllib.parse import parse_qs, urlparse

    PORT = 39281
    BASE_DIR = Path.home() / ".wisp" / "channel-bridge"
    CHATS_DIR = BASE_DIR / "chats"
    ROUTES_PATH = BASE_DIR / "routes.json"
    SECRET_PATH = BASE_DIR / "bridge_secret"
    CLAUDE_TOKEN_PATH = BASE_DIR / "claude_oauth_token"
    HELPER_PATH = BASE_DIR / "channel.py"
    SSE_POLL_INTERVAL = 0.25
    SSE_HEARTBEAT_SECONDS = 10
    BRIDGE_PATHS = {"/message", "/interrupt", "/status", "/events", "/routes"}
    ANSI_CSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
    ANSI_OSC_RE = re.compile(r"\x1b\].*?(?:\x07|\x1b\\)")
    ANSI_SINGLE_RE = re.compile(r"\x1b[@-Z\\-_]")

    STATE_LOCK = threading.Lock()


    class BridgeError(Exception):
        def __init__(self, status: int, message: str):
            super().__init__(message)
            self.status = status
            self.message = message


    def log(message: str) -> None:
        print(f"[wisp-channel-bridge] {message}", file=sys.stderr, flush=True)


    def ensure_base_dirs() -> None:
        CHATS_DIR.mkdir(parents=True, exist_ok=True)


    def safe_chat_dir(chat_id: str) -> Path:
        digest = hashlib.sha1(chat_id.encode("utf-8")).hexdigest()
        return CHATS_DIR / digest


    def channel_server_name(chat_id: str) -> str:
        digest = hashlib.sha1(chat_id.encode("utf-8")).hexdigest()[:16]
        return f"wisp-{digest}"


    def state_path(chat_dir: Path) -> Path:
        return chat_dir / "state.json"


    def events_path(chat_dir: Path) -> Path:
        return chat_dir / "events.jsonl"


    def inbox_dir(chat_dir: Path) -> Path:
        return chat_dir / "inbox"


    def claude_settings_path() -> Path:
        return Path.home() / ".claude.json"


    def stdout_log_path(chat_dir: Path) -> Path:
        return chat_dir / "claude.stdout.log"


    def stderr_log_path(chat_dir: Path) -> Path:
        return chat_dir / "claude.stderr.log"


    def ensure_chat_dirs(chat_dir: Path) -> None:
        chat_dir.mkdir(parents=True, exist_ok=True)
        inbox_dir(chat_dir).mkdir(parents=True, exist_ok=True)


    def atomic_write_text(path: Path, value: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(value, encoding="utf-8")
        tmp.replace(path)


    def atomic_write_json(path: Path, value: dict) -> None:
        atomic_write_text(path, json.dumps(value, sort_keys=True))


    def read_json(path: Path, default: dict | None = None) -> dict:
        if not path.exists():
            return dict(default or {})
        try:
            with path.open("r", encoding="utf-8") as handle:
                return json.load(handle)
        except Exception:
            return dict(default or {})


    # --- Route store -----------------------------------------------------------

    ROUTES: list[dict] = []


    def load_routes() -> None:
        global ROUTES
        if ROUTES_PATH.exists():
            try:
                with ROUTES_PATH.open("r", encoding="utf-8") as f:
                    ROUTES = json.load(f)
            except Exception:
                ROUTES = []
        else:
            ROUTES = []


    def save_routes() -> None:
        atomic_write_text(ROUTES_PATH, json.dumps(ROUTES, sort_keys=True))


    def match_route(path: str) -> tuple[dict, str] | None:
        """Return (route, stripped_path) for the longest matching prefix, or None."""
        best: dict | None = None
        best_prefix = ""
        for route in ROUTES:
            prefix = route.get("prefix", "")
            if prefix == "/":
                if best is None:
                    best = route
                    best_prefix = prefix
            elif path == prefix or path.startswith(prefix + "/"):
                if len(prefix) > len(best_prefix):
                    best = route
                    best_prefix = prefix
        if best is None:
            return None
        if best_prefix == "/":
            stripped = path
        else:
            stripped = path[len(best_prefix):]
            if not stripped:
                stripped = "/"
        return best, stripped


    # --- CLAUDE.md injection --------------------------------------------------

    CLAUDE_MD_START = "<!-- wisp-bridge-start -->"
    CLAUDE_MD_END = "<!-- wisp-bridge-end -->"

    CLAUDE_MD_SECTION = "\n".join([
        "<!-- wisp-bridge-start -->",
        "## HTTP Services (Wisp Bridge)",
        "",
        "This sprite's public URL routes through the Wisp channel bridge. To expose an HTTP service:",
        "",
        "1. Start your server on any port (e.g. `python3 -m http.server 3000`)",
        "2. Register the route with the bridge:",
        "   ```bash",
        "   SECRET=$(cat ~/.wisp/channel-bridge/bridge_secret)",
        "   curl -X POST http://localhost:39281/routes \\\\",
        "     -H \"X-Wisp-Bridge-Key: $SECRET\" \\\\",
        "     -H \"Content-Type: application/json\" \\\\",
        "     -d '{\"prefix\": \"/\", \"port\": 3000}'",
        "   ```",
        "3. Your service is now accessible at the sprite's public URL.",
        "",
        "Multiple routes are supported. Longest prefix wins:",
        "```bash",
        "curl -X POST http://localhost:39281/routes \\\\",
        "  -H \"X-Wisp-Bridge-Key: $SECRET\" \\\\",
        "  -H \"Content-Type: application/json\" \\\\",
        "  -d '{\"prefix\": \"/api\", \"port\": 4000}'",
        "```",
        "",
        "Prefixes are stripped: a request to `/api/users` with prefix `/api` proxies to `localhost:4000/users`.",
        "",
        "To list routes: `GET /routes`",
        "To remove a route: `DELETE /routes` with `{\"prefix\": \"/api\"}`",
        "",
        "Reserved paths (cannot be registered): /message, /interrupt, /status, /events, /routes",
        "<!-- wisp-bridge-end -->",
    ])


    def ensure_claude_md(working_directory: str) -> None:
        claude_md = Path(working_directory) / "CLAUDE.md"
        if claude_md.exists():
            content = claude_md.read_text(encoding="utf-8")
            if CLAUDE_MD_START in content and CLAUDE_MD_END in content:
                before = content[: content.index(CLAUDE_MD_START)]
                after = content[content.index(CLAUDE_MD_END) + len(CLAUDE_MD_END) :]
                content = before + CLAUDE_MD_SECTION + after
            else:
                content = content.rstrip() + "\n\n" + CLAUDE_MD_SECTION + "\n"
        else:
            content = CLAUDE_MD_SECTION + "\n"
        atomic_write_text(claude_md, content)


    # --- Reverse proxy --------------------------------------------------------

    def proxy_request(handler: BaseHTTPRequestHandler, method: str) -> None:
        parsed = urlparse(handler.path)
        result = match_route(parsed.path)
        if result is None:
            raise BridgeError(404, "Not found")
        route, stripped = result
        port = route["port"]
        target_path = stripped
        if parsed.query:
            target_path += "?" + parsed.query
        content_length = int(handler.headers.get("Content-Length", "0"))
        body = handler.rfile.read(content_length) if content_length > 0 else None
        try:
            import http.client
            conn = http.client.HTTPConnection("localhost", port, timeout=30)
            fwd_headers = {}
            for key in handler.headers:
                lower = key.lower()
                if lower in ("host", "x-wisp-bridge-key"):
                    continue
                fwd_headers[key] = handler.headers[key]
            conn.request(method, target_path, body=body, headers=fwd_headers)
            resp = conn.getresponse()
            handler.send_response(resp.status)
            hop_by_hop = {"connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade"}
            for key, value in resp.getheaders():
                if key.lower() not in hop_by_hop:
                    handler.send_header(key, value)
            handler.end_headers()
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                handler.wfile.write(chunk)
            conn.close()
        except (ConnectionRefusedError, OSError) as exc:
            raise BridgeError(502, f"Bad gateway: upstream on port {port} unreachable") from exc


    def ensure_claude_project_config(
        working_directory: str,
        chat_dir: Path,
        chat_id: str,
        server_name: str,
        ask_user_enabled: bool,
    ) -> None:
        settings_path = claude_settings_path()
        settings = read_json(settings_path, default={})
        projects = settings.setdefault("projects", {})
        project_state = projects.setdefault(working_directory, {})
        project_state["hasTrustDialogAccepted"] = True
        mcp_servers = project_state.setdefault("mcpServers", {})
        mcp_servers[server_name] = {
            "command": "python3",
            "args": [str(HELPER_PATH)],
            "env": {
                "WISP_CHAT_DIR": str(chat_dir),
                "WISP_CHAT_ID": chat_id,
            },
        }
        if ask_user_enabled:
            mcp_servers["askUser"] = {
                "command": "python3",
                "args": ["/home/sprite/.wisp/claude-question/server.py"],
                "env": {
                    "WISP_SESSION_ID": chat_id,
                },
            }
        else:
            mcp_servers.pop("askUser", None)
        atomic_write_text(settings_path, json.dumps(settings, sort_keys=True))
        ensure_claude_md(working_directory)


    def strip_terminal_control(value: str) -> str:
        value = ANSI_OSC_RE.sub("", value)
        value = ANSI_CSI_RE.sub("", value)
        value = ANSI_SINGLE_RE.sub("", value)
        return value.replace("\r", "")


    def pump_pty_output(master_fd: int, chat_id: str, stdout_handle) -> None:
        accepted_theme = False
        accepted_trust = False
        accepted_dev_channels = False
        accepted_bypass = False
        prompt_buffer = ""

        try:
            while True:
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError:
                    break

                if not chunk:
                    break

                stdout_handle.write(chunk)
                stdout_handle.flush()

                prompt_buffer = strip_terminal_control(
                    (prompt_buffer + chunk.decode("utf-8", errors="ignore"))[-8000:]
                )
                compact_buffer = re.sub(r"\s+", "", prompt_buffer)

                if (
                    not accepted_theme
                    and "Choosethetextstyle" in compact_buffer
                    and "Darkmode" in compact_buffer
                ):
                    os.write(master_fd, b"\r")
                    accepted_theme = True
                    log(f"Accepted theme prompt for chat {chat_id}")

                if (
                    not accepted_trust
                    and "Quicksafetycheck" in compact_buffer
                    and "Yes,Itrustthisfolder" in compact_buffer
                ):
                    os.write(master_fd, b"\r")
                    accepted_trust = True
                    log(f"Accepted workspace trust prompt for chat {chat_id}")

                if (
                    not accepted_dev_channels
                    and "Loadingdevelopmentchannels" in compact_buffer
                    and "Iamusingthisforlocaldevelopment" in compact_buffer
                ):
                    os.write(master_fd, b"\r")
                    accepted_dev_channels = True
                    log(f"Accepted development channels prompt for chat {chat_id}")

                if (
                    not accepted_bypass
                    and "BypassPermissionsmode" in compact_buffer
                    and "Yes,Iaccept" in compact_buffer
                ):
                    # Default is "No, exit" — press down arrow to select "Yes, I accept"
                    os.write(master_fd, b"\x1b[B")
                    time.sleep(0.1)
                    os.write(master_fd, b"\r")
                    accepted_bypass = True
                    log(f"Accepted bypass permissions prompt for chat {chat_id}")
        finally:
            try:
                os.close(master_fd)
            except OSError:
                pass
            stdout_handle.close()


    def load_state(chat_dir: Path, chat_id: str) -> dict:
        return {
            "chat_id": chat_id,
            "session_id": None,
            "pid": None,
            "working_directory": None,
            "model": None,
            "max_turns": None,
            "claude_question_tool_enabled": False,
            "custom_instructions": None,
            "busy": False,
            "activity": None,
            "next_event_number": 1,
            "session_offset": 0,
            "last_synced_at": 0,
            **read_json(state_path(chat_dir)),
        }


    def save_state(chat_dir: Path, state: dict) -> None:
        atomic_write_json(state_path(chat_dir), state)


    def read_secret() -> str:
        try:
            return SECRET_PATH.read_text(encoding="utf-8").strip()
        except FileNotFoundError as exc:
            raise BridgeError(503, "Bridge secret not installed") from exc


    def parse_json_body(handler: BaseHTTPRequestHandler) -> dict:
        content_length = int(handler.headers.get("Content-Length", "0"))
        raw = handler.rfile.read(content_length) if content_length > 0 else b"{}"
        try:
            return json.loads(raw.decode("utf-8"))
        except Exception as exc:
            raise BridgeError(400, "Invalid JSON body") from exc


    def require_secret(handler: BaseHTTPRequestHandler) -> None:
        expected = read_secret()
        actual = handler.headers.get("X-Wisp-Bridge-Key", "")
        if not expected or actual != expected:
            raise BridgeError(401, "Unauthorized")


    def send_json(handler: BaseHTTPRequestHandler, status: int, body: dict) -> None:
        data = json.dumps(body).encode("utf-8")
        handler.send_response(status)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(data)))
        handler.end_headers()
        handler.wfile.write(data)


    def parse_last_event_id(value: str | None) -> int:
        if not value:
            return 0
        raw = value.strip()
        if raw.startswith("evt-"):
            raw = raw[4:]
        try:
            return int(raw)
        except ValueError:
            return 0


    def pid_is_alive(pid: int | None) -> bool:
        if not pid:
            return False
        try:
            os.kill(pid, 0)
        except OSError:
            return False
        return True


    def event_record(event_id: str, event_name: str, payload: dict) -> dict:
        return {"id": event_id, "event": event_name, "data": payload}


    def append_event(chat_dir: Path, state: dict, event_name: str, payload: dict) -> dict:
        event_number = int(state.get("next_event_number", 1))
        state["next_event_number"] = event_number + 1
        record = event_record(f"evt-{event_number}", event_name, payload)
        with events_path(chat_dir).open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
        return record


    def list_events_after(chat_dir: Path, after_event_number: int) -> list[dict]:
        path = events_path(chat_dir)
        if not path.exists():
            return []
        records: list[dict] = []
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if parse_last_event_id(record.get("id")) > after_event_number:
                    records.append(record)
        return records


    def encoded_project_dir(working_directory: str) -> str:
        return working_directory.replace("/", "-")


    def session_file_path(state: dict) -> Path | None:
        working_directory = state.get("working_directory")
        session_id = state.get("session_id")
        if not working_directory or not session_id:
            return None
        return Path.home() / ".claude" / "projects" / encoded_project_dir(working_directory) / f"{session_id}.jsonl"


    def ensure_session_id(state: dict, requested_chat_id: str) -> str:
        existing = state.get("session_id")
        if isinstance(existing, str) and existing:
            return existing
        try:
            uuid.UUID(requested_chat_id)
            session_id = requested_chat_id
        except ValueError:
            session_id = str(uuid.uuid4())
        state["session_id"] = session_id
        return session_id


    def start_claude_process(chat_dir: Path, state: dict, request: dict) -> None:
        working_directory = (
            request.get("working_directory")
            or state.get("working_directory")
            or "/home/sprite/project"
        )
        Path(working_directory).mkdir(parents=True, exist_ok=True)
        state["working_directory"] = working_directory

        session_id = state.get("session_id")
        parent_session_id = request.get("session_id")

        resume_args: list[str]
        if session_id:
            resume_args = ["--resume", session_id]
        elif parent_session_id:
            session_id = str(uuid.uuid4())
            state["session_id"] = session_id
            resume_args = ["--resume", parent_session_id, "--fork-session", "--session-id", session_id]
        else:
            session_id = ensure_session_id(state, request["chat_id"])
            resume_args = ["--session-id", session_id]

        model = request.get("model") or state.get("model")
        max_turns = (
            request["max_turns"]
            if "max_turns" in request
            else state.get("max_turns")
        )
        ask_user_enabled = (
            bool(request["claude_question_tool_enabled"])
            if "claude_question_tool_enabled" in request
            else bool(state.get("claude_question_tool_enabled"))
        )
        custom_instructions = request.get("custom_instructions") or state.get("custom_instructions")

        env = os.environ.copy()
        env["NO_DNA"] = "1"
        try:
            claude_token = CLAUDE_TOKEN_PATH.read_text(encoding="utf-8").strip()
        except FileNotFoundError:
            claude_token = ""

        if claude_token:
            env["CLAUDE_CODE_OAUTH_TOKEN"] = claude_token
        else:
            log(f"No uploaded Claude token for chat {request['chat_id']}; using sprite-local Claude auth")

        server_name = channel_server_name(request["chat_id"])
        ensure_claude_project_config(
            working_directory,
            chat_dir,
            request["chat_id"],
            server_name,
            ask_user_enabled,
        )

        command = [
            "claude",
            "--dangerously-skip-permissions",
            "--dangerously-load-development-channels",
            f"server:{server_name}",
            "--add-dir",
            working_directory,
            *resume_args,
        ]

        if model:
            command.extend(["--model", model])
        if max_turns is not None:
            command.extend(["--max-turns", str(max_turns)])
        if ask_user_enabled:
            command.extend(["--disallowedTools", "AskUserQuestion"])
        if custom_instructions:
            command.extend(["--append-system-prompt", custom_instructions])

        stdout_handle = stdout_log_path(chat_dir).open("ab")
        stderr_log_path(chat_dir).touch(exist_ok=True)

        master_fd, slave_fd = pty.openpty()
        try:
            process = subprocess.Popen(
                command,
                cwd=working_directory,
                env=env,
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                preexec_fn=os.setsid,
                close_fds=True,
            )
        finally:
            os.close(slave_fd)

        threading.Thread(
            target=pump_pty_output,
            args=(master_fd, request["chat_id"], stdout_handle),
            daemon=True,
        ).start()

        state["pid"] = process.pid
        state["model"] = model
        state["max_turns"] = max_turns
        state["claude_question_tool_enabled"] = ask_user_enabled
        state["custom_instructions"] = custom_instructions
        state["last_synced_at"] = time.time()
        log(f"Started Claude for chat {request['chat_id']} pid={process.pid}")


    def sync_session_events(chat_dir: Path, state: dict) -> dict:
        path = session_file_path(state)
        if path is None or not path.exists():
            if state.get("busy") and not pid_is_alive(state.get("pid")) and state.get("session_id"):
                append_event(
                    chat_dir,
                    state,
                    "result",
                    {
                        "type": "result",
                        "subtype": "error",
                        "session_id": state["session_id"],
                        "is_error": True,
                        "result": "Claude process exited before finishing the turn",
                        "uuid": str(uuid.uuid4()),
                    },
                )
                state["busy"] = False
                state["activity"] = None
            save_state(chat_dir, state)
            return state

        offset = int(state.get("session_offset", 0))
        with path.open("rb") as handle:
            handle.seek(offset)
            chunk = handle.read()
            state["session_offset"] = handle.tell()

        if not chunk:
            save_state(chat_dir, state)
            return state

        for raw_line in chunk.decode("utf-8", errors="ignore").splitlines():
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            try:
                payload = json.loads(raw_line)
            except json.JSONDecodeError:
                continue

            line_type = payload.get("type")

            if line_type == "system":
                session_id = payload.get("sessionId") or state.get("session_id")
                if session_id:
                    state["session_id"] = session_id
                if payload.get("cwd"):
                    state["working_directory"] = payload.get("cwd")
                append_event(
                    chat_dir,
                    state,
                    "system",
                    {
                        "type": "system",
                        "session_id": state.get("session_id") or "",
                        "model": payload.get("model"),
                        "tools": payload.get("tools"),
                        "cwd": payload.get("cwd"),
                        "uuid": payload.get("uuid"),
                    },
                )
                continue

            if line_type == "assistant":
                append_event(
                    chat_dir,
                    state,
                    "assistant",
                    {
                        "type": "assistant",
                        "message": payload.get("message"),
                        "uuid": payload.get("uuid"),
                    },
                )
                message = payload.get("message") or {}
                stop_reason = message.get("stop_reason") if isinstance(message, dict) else None
                if stop_reason and stop_reason != "tool_use" and state.get("session_id"):
                    append_event(
                        chat_dir,
                        state,
                        "result",
                        {
                            "type": "result",
                            "subtype": "success",
                            "session_id": state["session_id"],
                            "is_error": False,
                            "uuid": str(uuid.uuid4()),
                        },
                    )
                    state["busy"] = False
                    state["activity"] = None
                continue

            if line_type == "user":
                message = payload.get("message") or {}
                content = message.get("content") if isinstance(message, dict) else None
                if isinstance(content, list) and any(
                    isinstance(block, dict) and block.get("type") == "tool_result"
                    for block in content
                ):
                    append_event(
                        chat_dir,
                        state,
                        "user",
                        {
                            "type": "user",
                            "message": {
                                "role": "user",
                                "content": content,
                            },
                            "uuid": payload.get("uuid"),
                        },
                    )

        save_state(chat_dir, state)
        return state


    def enqueue_message(request: dict) -> dict:
        chat_id = request["chat_id"]
        chat_dir = safe_chat_dir(chat_id)
        ensure_chat_dirs(chat_dir)
        state = load_state(chat_dir, chat_id)
        state = sync_session_events(chat_dir, state)

        if state.get("busy"):
            raise BridgeError(409, "Chat is already busy")

        inbox_message = {
            "id": f"msg-{int(time.time() * 1000)}-{uuid.uuid4().hex[:8]}",
            "chat_id": chat_id,
            "text": request["text"],
            "working_directory": request.get("working_directory"),
            "attachments": request.get("attachments") or [],
            "timestamp": time.time(),
        }

        state["model"] = request.get("model")
        state["max_turns"] = request.get("max_turns")
        state["claude_question_tool_enabled"] = bool(
            request.get("claude_question_tool_enabled", False)
        )
        state["custom_instructions"] = request.get("custom_instructions")

        message_path = inbox_dir(chat_dir) / f"{int(time.time() * 1000)}-{uuid.uuid4().hex}.json"
        atomic_write_json(message_path, inbox_message)

        if not pid_is_alive(state.get("pid")):
            start_claude_process(chat_dir, state, request)

        preview = request["text"].strip().replace("\n", " ")
        if len(preview) > 120:
            preview = preview[:117] + "..."
        state["busy"] = True
        state["activity"] = preview or "Waiting for Claude"
        save_state(chat_dir, state)
        return state


    def interrupt_chat(chat_id: str) -> dict:
        chat_dir = safe_chat_dir(chat_id)
        ensure_chat_dirs(chat_dir)
        state = load_state(chat_dir, chat_id)
        state = sync_session_events(chat_dir, state)

        pid = state.get("pid")
        if pid_is_alive(pid):
            try:
                os.killpg(os.getpgid(pid), signal.SIGINT)
            except OSError:
                pass

        if state.get("session_id"):
            append_event(
                chat_dir,
                state,
                "result",
                {
                    "type": "result",
                    "subtype": "interrupted",
                    "session_id": state["session_id"],
                    "is_error": False,
                    "uuid": str(uuid.uuid4()),
                },
            )

        state["busy"] = False
        state["activity"] = None
        save_state(chat_dir, state)
        return state


    def chat_status(chat_id: str | None) -> dict:
        if not chat_id:
            return {
                "is_running": True,
                "is_busy": False,
                "activity": "ready",
                "session_id": None,
            }

        chat_dir = safe_chat_dir(chat_id)
        ensure_chat_dirs(chat_dir)
        state = load_state(chat_dir, chat_id)
        state = sync_session_events(chat_dir, state)
        return {
            "is_running": pid_is_alive(state.get("pid")),
            "is_busy": bool(state.get("busy")),
            "activity": state.get("activity"),
            "session_id": state.get("session_id"),
        }


    class Handler(BaseHTTPRequestHandler):
        server_version = "WispChannelBridge/1.0"

        def log_message(self, format: str, *args) -> None:  # noqa: A003
            log(format % args)

        def _is_bridge_path(self, path: str) -> bool:
            return path in BRIDGE_PATHS

        def do_POST(self) -> None:  # noqa: N802
            try:
                parsed = urlparse(self.path)
                if not self._is_bridge_path(parsed.path):
                    proxy_request(self, "POST")
                    return
                require_secret(self)
                if parsed.path == "/message":
                    body = parse_json_body(self)
                    if not body.get("chat_id") or not body.get("text"):
                        raise BridgeError(400, "chat_id and text are required")
                    request = {
                        "chat_id": str(body["chat_id"]),
                        "text": str(body["text"]),
                        "working_directory": body.get("working_directory"),
                        "session_id": body.get("session_id"),
                        "model": body.get("model"),
                        "max_turns": body.get("max_turns"),
                        "claude_question_tool_enabled": bool(
                            body.get("claude_question_tool_enabled", False)
                        ),
                        "custom_instructions": body.get("custom_instructions"),
                        "attachments": body.get("attachments") or [],
                    }
                    with STATE_LOCK:
                        state = enqueue_message(request)
                    send_json(
                        self,
                        202,
                        {
                            "ok": True,
                            "session_id": state.get("session_id"),
                            "is_busy": state.get("busy"),
                        },
                    )
                    return

                if parsed.path == "/interrupt":
                    body = parse_json_body(self)
                    chat_id = body.get("chat_id")
                    if not chat_id:
                        raise BridgeError(400, "chat_id is required")
                    with STATE_LOCK:
                        state = interrupt_chat(str(chat_id))
                    send_json(
                        self,
                        200,
                        {
                            "ok": True,
                            "session_id": state.get("session_id"),
                            "is_busy": state.get("busy"),
                        },
                    )
                    return

                if parsed.path == "/routes":
                    body = parse_json_body(self)
                    prefix = body.get("prefix", "").rstrip("/") or "/"
                    port = body.get("port")
                    if not port or not isinstance(port, int):
                        raise BridgeError(400, "port (integer) is required")
                    if prefix in BRIDGE_PATHS:
                        raise BridgeError(
                            400, f"prefix {prefix} conflicts with a reserved bridge path"
                        )
                    with STATE_LOCK:
                        ROUTES[:] = [r for r in ROUTES if r["prefix"] != prefix]
                        ROUTES.append({"prefix": prefix, "port": port})
                        save_routes()
                    send_json(self, 201, {"ok": True, "prefix": prefix, "port": port})
                    return

                raise BridgeError(404, "Not found")
            except BridgeError as exc:
                send_json(self, exc.status, {"error": exc.message})
            except Exception as exc:  # pragma: no cover - defensive server guard
                log(f"Unhandled POST error: {exc}")
                send_json(self, 500, {"error": "Internal server error"})

        def do_GET(self) -> None:  # noqa: N802
            try:
                parsed = urlparse(self.path)
                if not self._is_bridge_path(parsed.path):
                    proxy_request(self, "GET")
                    return
                require_secret(self)
                query = parse_qs(parsed.query)

                if parsed.path == "/status":
                    chat_id = query.get("chat_id", [None])[0]
                    with STATE_LOCK:
                        status = chat_status(chat_id)
                    send_json(self, 200, status)
                    return

                if parsed.path == "/events":
                    chat_id = query.get("chat_id", [None])[0]
                    if not chat_id:
                        raise BridgeError(400, "chat_id is required")
                    self.stream_events(str(chat_id))
                    return

                if parsed.path == "/routes":
                    send_json(self, 200, {"routes": list(ROUTES)})
                    return

                raise BridgeError(404, "Not found")
            except BridgeError as exc:
                send_json(self, exc.status, {"error": exc.message})
            except BrokenPipeError:
                return
            except Exception as exc:  # pragma: no cover - defensive server guard
                log(f"Unhandled GET error: {exc}")
                send_json(self, 500, {"error": "Internal server error"})

        def do_DELETE(self) -> None:  # noqa: N802
            try:
                parsed = urlparse(self.path)
                if not self._is_bridge_path(parsed.path):
                    proxy_request(self, "DELETE")
                    return
                require_secret(self)
                if parsed.path == "/routes":
                    body = parse_json_body(self)
                    prefix = body.get("prefix", "").rstrip("/") or "/"
                    with STATE_LOCK:
                        ROUTES[:] = [r for r in ROUTES if r["prefix"] != prefix]
                        save_routes()
                    send_json(self, 200, {"ok": True})
                    return
                raise BridgeError(404, "Not found")
            except BridgeError as exc:
                send_json(self, exc.status, {"error": exc.message})
            except Exception as exc:  # pragma: no cover - defensive server guard
                log(f"Unhandled DELETE error: {exc}")
                send_json(self, 500, {"error": "Internal server error"})

        def do_PUT(self) -> None:  # noqa: N802
            try:
                parsed = urlparse(self.path)
                if not self._is_bridge_path(parsed.path):
                    proxy_request(self, "PUT")
                    return
                raise BridgeError(404, "Not found")
            except BridgeError as exc:
                send_json(self, exc.status, {"error": exc.message})
            except Exception as exc:  # pragma: no cover - defensive server guard
                log(f"Unhandled PUT error: {exc}")
                send_json(self, 500, {"error": "Internal server error"})

        def do_PATCH(self) -> None:  # noqa: N802
            try:
                parsed = urlparse(self.path)
                if not self._is_bridge_path(parsed.path):
                    proxy_request(self, "PATCH")
                    return
                raise BridgeError(404, "Not found")
            except BridgeError as exc:
                send_json(self, exc.status, {"error": exc.message})
            except Exception as exc:  # pragma: no cover - defensive server guard
                log(f"Unhandled PATCH error: {exc}")
                send_json(self, 500, {"error": "Internal server error"})

        def do_HEAD(self) -> None:  # noqa: N802
            try:
                parsed = urlparse(self.path)
                if not self._is_bridge_path(parsed.path):
                    proxy_request(self, "HEAD")
                    return
                raise BridgeError(404, "Not found")
            except BridgeError as exc:
                send_json(self, exc.status, {"error": exc.message})
            except Exception as exc:  # pragma: no cover - defensive server guard
                log(f"Unhandled HEAD error: {exc}")
                send_json(self, 500, {"error": "Internal server error"})

        def stream_events(self, chat_id: str) -> None:
            last_seen = parse_last_event_id(self.headers.get("Last-Event-ID"))
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()

            last_heartbeat = time.time()

            while True:
                with STATE_LOCK:
                    chat_dir = safe_chat_dir(chat_id)
                    ensure_chat_dirs(chat_dir)
                    state = load_state(chat_dir, chat_id)
                    state = sync_session_events(chat_dir, state)
                    events = list_events_after(chat_dir, last_seen)

                for record in events:
                    payload = json.dumps(record["data"], separators=(",", ":"))
                    self.wfile.write(f"id: {record['id']}\n".encode("utf-8"))
                    self.wfile.write(f"event: {record['event']}\n".encode("utf-8"))
                    self.wfile.write(f"data: {payload}\n\n".encode("utf-8"))
                    self.wfile.flush()
                    last_seen = parse_last_event_id(record["id"])
                    if record["event"] == "result":
                        return

                if not state.get("busy") and not events:
                    return

                now = time.time()
                if now - last_heartbeat >= SSE_HEARTBEAT_SECONDS:
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
                    last_heartbeat = now

                time.sleep(SSE_POLL_INTERVAL)


    def ensure_claude_global_config() -> None:
        """Pre-configure Claude to skip interactive onboarding prompts."""
        global_config_path = Path.home() / ".claude.json"
        config = read_json(global_config_path, default={})
        changed = False
        if not config.get("hasCompletedOnboarding"):
            config["hasCompletedOnboarding"] = True
            changed = True
        if config.get("numStartups") is None:
            config["numStartups"] = 1
            changed = True
        if changed:
            atomic_write_text(global_config_path, json.dumps(config, sort_keys=True))
            log("Pre-configured Claude global config to skip onboarding")

        settings_path = claude_settings_path()
        settings = read_json(settings_path, default={})
        changed_settings = False
        if not settings.get("skipDangerousModePermissionPrompt"):
            settings["skipDangerousModePermissionPrompt"] = True
            changed_settings = True
        permissions = settings.setdefault("permissions", {})
        if permissions.get("defaultMode") != "bypassPermissions":
            permissions["defaultMode"] = "bypassPermissions"
            changed_settings = True
        if changed_settings:
            atomic_write_text(settings_path, json.dumps(settings, sort_keys=True))
            log("Configured Claude permissions and bypass settings")


    def main() -> None:
        ensure_base_dirs()
        ensure_claude_global_config()
        load_routes()
        log(f"Loaded {len(ROUTES)} route(s)")
        server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
        log(f"Listening on :{PORT}")
        server.serve_forever()


    if __name__ == "__main__":
        main()
    """#

    static let channelScript = #"""
    #!/usr/bin/env python3
    """Per-chat MCP channel helper for Wisp.

    Claude Code spawns this process from the chat-specific MCP config. The helper
    polls a shared inbox directory and forwards those messages into the Claude
    session as channel notifications.
    """

    from __future__ import annotations

    import json
    import os
    import sys
    import threading
    import time
    from pathlib import Path

    CHAT_DIR = Path(os.environ["WISP_CHAT_DIR"])
    CHAT_ID = os.environ.get("WISP_CHAT_ID", "unknown")
    INBOX_DIR = CHAT_DIR / "inbox"
    PROTOCOL_VERSION = "2025-11-25"

    send_lock = threading.Lock()
    running = True
    initialized = False


    def log(message: str) -> None:
        print(f"[wisp-channel-helper] {message}", file=sys.stderr, flush=True)


    def send_message(payload: dict) -> None:
        line = json.dumps(payload, separators=(",", ":"))
        with send_lock:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()


    def inbox_loop() -> None:
        global running
        while running:
            if not initialized:
                time.sleep(0.1)
                continue

            for path in sorted(INBOX_DIR.glob("*.json")):
                try:
                    with path.open("r", encoding="utf-8") as handle:
                        payload = json.load(handle)
                    send_message(
                        {
                            "jsonrpc": "2.0",
                            "method": "notifications/claude/channel",
                            "params": {
                                "content": payload.get("text", ""),
                                "meta": {
                                    "chat_id": payload.get("chat_id", CHAT_ID),
                                    "message_id": payload.get("id"),
                                    "working_directory": payload.get("working_directory"),
                                },
                            },
                        }
                    )
                    path.unlink(missing_ok=True)
                except Exception as exc:
                    log(f"Failed to forward inbox message {path.name}: {exc}")
            time.sleep(0.2)


    def main() -> None:
        global running
        global initialized

        INBOX_DIR.mkdir(parents=True, exist_ok=True)
        worker = threading.Thread(target=inbox_loop, daemon=True)
        worker.start()

        while True:
            line = sys.stdin.readline()
            if not line:
                break

            line = line.strip()
            if not line:
                continue

            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue

            method = message.get("method")
            message_id = message.get("id")

            if method == "initialize":
                send_message(
                    {
                        "jsonrpc": "2.0",
                        "id": message_id,
                        "result": {
                            "protocolVersion": PROTOCOL_VERSION,
                            "capabilities": {
                                "experimental": {"claude/channel": {}},
                                "tools": {},
                            },
                            "serverInfo": {
                                "name": "wisp-channel-helper",
                                "version": "1.0.0",
                            },
                            "instructions": (
                                "Messages arrive as <channel source=\"wisp\" chat_id=\"...\" "
                                "message_id=\"...\" working_directory=\"...\">. Treat each "
                                "channel event as a normal user message from the Wisp iOS app. "
                                "Respond normally in this Claude session; Wisp mirrors the "
                                "session transcript back to the user."
                            ),
                        },
                    }
                )
            elif method == "notifications/initialized":
                initialized = True
            elif method == "tools/list":
                send_message({"jsonrpc": "2.0", "id": message_id, "result": {"tools": []}})

        running = False


    if __name__ == "__main__":
        main()
    """#
}
