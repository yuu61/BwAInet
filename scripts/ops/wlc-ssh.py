#!/usr/bin/env python3
"""Run commands on the Cisco 3504 WLC (AireOS 8.10) via SSH.

Usage:
    python scripts/wlc-ssh.py "show sysinfo"
    python scripts/wlc-ssh.py "show ap summary" "show client summary"
    python scripts/wlc-ssh.py "config 802.11a disable network"   # y/n auto-confirmed

    # Wrap commands in WLAN disable/enable (AireOS requires many configs on disabled WLAN).
    # Enable runs in finally so WLAN is restored even on timeout/error.
    python scripts/wlc-ssh.py \
        --cycle-wlan 1 "config wlan max-associated-clients 50 1" \
        --cycle-wlan 2 "config wlan max-associated-clients 600 2" \
        --save

    python scripts/wlc-ssh.py --save                              # save running config only

Behaviour:
    * Confirmation prompts ("y/n", "Are you sure", "confirm") → auto-answered "y".
    * ReadTimeout on any command → warning printed, remaining commands continue.
    * --cycle-wlan ID sequences: each cycle emits `config wlan disable ID` immediately;
      the matching `enable ID` runs at end-of-batch (and via finally on exceptions).

Password resolution order:
    1. $WLC_PASS environment variable
    2. `password:` line in the Claude memory file
       (%USERPROFILE%/.claude/projects/C--repository-BwAInet/memory/reference_wlc.md)

Requires: pip install netmiko
"""

import os
import re
import sys
import time
from pathlib import Path

from netmiko import ConnectHandler
from netmiko.exceptions import ReadTimeout

HOST = "192.168.11.10"
USERNAME = "BwAI"
PROJECT_MEMORY_RELATIVE = (
    Path(".claude")
    / "projects"
    / "C--repository-BwAInet"
    / "memory"
    / "reference_wlc.md"
)

CONFIRM_PATTERNS = re.compile(r"\(y/n\)|are you sure|confirm", re.IGNORECASE)
DEFAULT_TIMEOUT = 120


def resolve_password() -> str:
    pw = os.environ.get("WLC_PASS")
    if pw:
        return pw

    memory_candidates = [
        Path.home() / PROJECT_MEMORY_RELATIVE,
    ]
    # WSL usage often keeps the Claude memory under the Windows user profile.
    memory_candidates.extend(
        Path("/mnt/c/Users").glob(
            "*/.claude/projects/C--repository-BwAInet/memory/reference_wlc.md"
        )
    )

    for memory_file in memory_candidates:
        if not memory_file.exists():
            continue
        for line in memory_file.read_text(encoding="utf-8").splitlines():
            m = re.match(r"^\s*-\s*\*\*パスワード\*\*\s*:\s*`([^`]+)`", line)
            if m:
                return m.group(1)
    sys.exit("ERROR: WLC password not found (set $WLC_PASS or update memory file)")


def run(conn, cmd: str, timeout: int = DEFAULT_TIMEOUT) -> bool:
    """Send a command, auto-answer y/n. Returns False on ReadTimeout."""
    print(f"===== {cmd} =====")
    try:
        out = conn.send_command_timing(cmd, read_timeout=timeout)
    except ReadTimeout as e:
        print(f"[WARN] timeout on '{cmd}': {e.__class__.__name__}", file=sys.stderr)
        # Drain whatever is currently in the buffer so the session stays usable.
        try:
            residual = conn.read_channel()
            if residual:
                print(residual, end="")
        except Exception:
            pass
        print()
        return False
    print(out, end="")
    while CONFIRM_PATTERNS.search(out):
        try:
            out = conn.send_command_timing("y", read_timeout=timeout)
        except ReadTimeout:
            print("[WARN] timeout on confirmation reply", file=sys.stderr)
            return False
        print(out, end="")
    print()
    return True


def save_config(conn) -> None:
    """Persist running config. Uses write_channel because save emits output
    after the y answer that send_command_timing may miss."""
    print("===== save config =====")
    conn.write_channel("save config\n")
    time.sleep(2)
    conn.write_channel("y\n")
    time.sleep(5)
    print(conn.read_channel())


def parse_args(argv: list[str]) -> tuple[list[str], list[str], bool]:
    """Expand --cycle-wlan markers.

    Returns (commands, cleanup_cmds, save_flag):
      commands      — run in order
      cleanup_cmds  — always run at end (reversed), even if commands raise
      save_flag     — run save_config after commands (not after cleanup)

    Semantics of --cycle-wlan ID:
      * emit `config wlan disable ID` into commands immediately
      * register `config wlan enable ID` for the cleanup phase
      * a subsequent --cycle-wlan ID' closes the previous cycle by moving
        the enable from cleanup into commands (so WLANs re-enable in sequence)
    """
    commands: list[str] = []
    cleanup_cmds: list[str] = []
    save_flag = False
    current_cycle: str | None = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--save":
            save_flag = True
        elif a == "--cycle-wlan":
            if i + 1 >= len(argv):
                sys.exit("ERROR: --cycle-wlan requires a WLAN id argument")
            wlan_id = argv[i + 1]
            i += 1
            if current_cycle is not None:
                # Close previous cycle inline; drop its pending cleanup.
                commands.append(f"config wlan enable {current_cycle}")
                cleanup_cmds.pop()
            commands.append(f"config wlan disable {wlan_id}")
            cleanup_cmds.append(f"config wlan enable {wlan_id}")
            current_cycle = wlan_id
        else:
            commands.append(a)
        i += 1
    return commands, cleanup_cmds, save_flag


def main(argv: list[str]) -> None:
    if not argv:
        sys.exit(__doc__)

    commands, cleanup_cmds, save_flag = parse_args(argv)
    if not commands and not save_flag and not cleanup_cmds:
        sys.exit("ERROR: no commands provided")

    conn = ConnectHandler(
        device_type="cisco_wlc_ssh",
        host=HOST,
        username=USERNAME,
        password=resolve_password(),
        fast_cli=False,
    )
    try:
        try:
            for cmd in commands:
                run(conn, cmd)
            if save_flag:
                save_config(conn)
        finally:
            # Always restore WLANs even on exception.
            for cmd in reversed(cleanup_cmds):
                try:
                    run(conn, cmd)
                except Exception as e:
                    print(f"[ERROR] cleanup '{cmd}' failed: {e}", file=sys.stderr)
    finally:
        conn.disconnect()


if __name__ == "__main__":
    main(sys.argv[1:])
