#!/usr/bin/env python3
"""Wisp launcher — starts Claude Code with PTY and channel plugin.

Runs as a Sprites managed service. Handles:
- Pre-configuring Claude to skip interactive onboarding
- Starting Claude with PTY for interactive mode
- Auto-accepting any remaining interactive prompts
- Restarting Claude if it exits unexpectedly
"""

from __future__ import annotations

import json
import os
import pty
import re
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

PLUGIN_DIR = Path.home() / ".wisp" / "plugin"
ANSI_CSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
ANSI_OSC_RE = re.compile(r"\x1b\].*?(?:\x07|\x1b\\)")
ANSI_SINGLE_RE = re.compile(r"\x1b[@-Z\\-_]")


def log(message: str) -> None:
    print(f"[wisp-launcher] {message}", file=sys.stderr, flush=True)


def strip_terminal_control(value: str) -> str:
    value = ANSI_OSC_RE.sub("", value)
    value = ANSI_CSI_RE.sub("", value)
    value = ANSI_SINGLE_RE.sub("", value)
    return value.replace("\r", "")


def ensure_claude_config() -> None:
    """Pre-configure Claude to skip interactive onboarding prompts."""
    global_config_path = Path.home() / ".claude.json"
    try:
        config = json.loads(global_config_path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        config = {}

    changed = False
    if not config.get("hasCompletedOnboarding"):
        config["hasCompletedOnboarding"] = True
        changed = True
    if config.get("numStartups") is None:
        config["numStartups"] = 1
        changed = True
    if changed:
        global_config_path.write_text(json.dumps(config, sort_keys=True), encoding="utf-8")
        log("Pre-configured Claude global config")

    settings_dir = Path.home() / ".claude"
    settings_dir.mkdir(parents=True, exist_ok=True)
    settings_path = settings_dir / "settings.json"
    try:
        settings = json.loads(settings_path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        settings = {}

    changed_settings = False
    if not settings.get("skipDangerousModePermissionPrompt"):
        settings["skipDangerousModePermissionPrompt"] = True
        changed_settings = True
    permissions = settings.setdefault("permissions", {})
    if permissions.get("defaultMode") != "bypassPermissions":
        permissions["defaultMode"] = "bypassPermissions"
        changed_settings = True
    if changed_settings:
        settings_path.write_text(json.dumps(settings, sort_keys=True), encoding="utf-8")
        log("Configured Claude permissions")


def ensure_mcp_config(working_directory: str) -> None:
    """Register the wisp MCP server in Claude's project settings."""
    settings_path = Path.home() / ".claude.json"
    try:
        config = json.loads(settings_path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        config = {}

    projects = config.setdefault("projects", {})
    project = projects.setdefault(working_directory, {})
    project["hasTrustDialogAccepted"] = True
    mcp_servers = project.setdefault("mcpServers", {})
    mcp_servers["wisp"] = {
        "command": "bun",
        "args": ["run", str(PLUGIN_DIR / "server.ts")],
    }
    settings_path.write_text(json.dumps(config, sort_keys=True), encoding="utf-8")


def pump_pty_output(master_fd: int, stdout_handle) -> None:
    """Read PTY output and auto-accept interactive prompts."""
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
            compact = re.sub(r"\s+", "", prompt_buffer)

            if not accepted_theme and "Choosethetextstyle" in compact and "Darkmode" in compact:
                os.write(master_fd, b"\r")
                accepted_theme = True
                log("Accepted theme prompt")

            if not accepted_trust and "Quicksafetycheck" in compact and "Yes,Itrustthisfolder" in compact:
                os.write(master_fd, b"\r")
                accepted_trust = True
                log("Accepted workspace trust prompt")

            if (
                not accepted_dev_channels
                and "Loadingdevelopmentchannels" in compact
                and "Iamusingthisforlocaldevelopment" in compact
            ):
                os.write(master_fd, b"\r")
                accepted_dev_channels = True
                log("Accepted development channels prompt")

            if (
                not accepted_bypass
                and "BypassPermissionsmode" in compact
                and "Yes,Iaccept" in compact
            ):
                os.write(master_fd, b"\x1b[B")
                time.sleep(0.1)
                os.write(master_fd, b"\r")
                accepted_bypass = True
                log("Accepted bypass permissions prompt")
    finally:
        try:
            os.close(master_fd)
        except OSError:
            pass
        stdout_handle.close()


def start_claude(working_directory: str) -> subprocess.Popen:
    """Start Claude with PTY and channel plugin."""
    Path(working_directory).mkdir(parents=True, exist_ok=True)
    ensure_mcp_config(working_directory)

    command = [
        "claude",
        "--dangerously-skip-permissions",
        "--dangerously-load-development-channels",
        "server:wisp",
        "--add-dir",
        working_directory,
    ]

    env = os.environ.copy()
    env["NO_DNA"] = "1"

    # Pass the uploaded Claude OAuth token if available and no local credentials exist
    token_path = Path.home() / ".wisp" / "channel-bridge" / "claude_oauth_token"
    creds_path = Path.home() / ".claude" / ".credentials.json"
    if not creds_path.exists():
        try:
            token = token_path.read_text(encoding="utf-8").strip()
            if token:
                env["CLAUDE_CODE_OAUTH_TOKEN"] = token
                log("Using uploaded Claude OAuth token")
        except FileNotFoundError:
            log("No Claude token available — Claude may fail to authenticate")

    log_dir = PLUGIN_DIR / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    stdout_handle = (log_dir / "claude.stdout.log").open("ab")

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
        args=(master_fd, stdout_handle),
        daemon=True,
    ).start()

    log(f"Started Claude pid={process.pid}")
    return process


def main() -> None:
    working_directory = os.environ.get("WISP_WORKING_DIRECTORY", "/home/sprite/project")
    ensure_claude_config()

    while True:
        process = start_claude(working_directory)
        exit_code = process.wait()
        log(f"Claude exited with code {exit_code}")

        # Brief pause before restart to avoid tight loops
        time.sleep(2)
        log("Restarting Claude...")


if __name__ == "__main__":
    main()
