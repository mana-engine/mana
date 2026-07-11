#!/usr/bin/env python3
"""PostToolUse hook: run `zig fmt` on the file just edited (Zig or ZON).

Keeps every write formatted per the "zig fmt is law" rule without waiting for the
pre-commit hook. Best-effort and silent: never blocks the tool call.
"""
import json
import os
import subprocess
import sys


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    path = (data.get("tool_input") or {}).get("file_path") or ""
    if not path.endswith((".zig", ".zon")) or not os.path.isfile(path):
        return 0
    # Prefer the mise-resolved zig on PATH; fall back to `mise x`.
    for cmd in (["zig", "fmt", path], ["mise", "x", "--", "zig", "fmt", path]):
        try:
            subprocess.run(
                cmd, check=False,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            break
        except FileNotFoundError:
            continue
    return 0


if __name__ == "__main__":
    sys.exit(main())
