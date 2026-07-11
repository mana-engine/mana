#!/usr/bin/env python3
"""PreToolUse hook: protect golden fixtures under tests/fixtures/.

Golden files are checked-in, known-good outputs. They must only change as a
deliberate, reviewed step. This hook blocks Edit/Write to tests/fixtures/** unless
the environment variable MANA_UPDATE_GOLDENS=1 is set (the "update goldens"
escape hatch).

Exit code 2 blocks the tool call and shows stderr to Claude.
"""
import json
import os
import sys


def main() -> int:
    if os.environ.get("MANA_UPDATE_GOLDENS") == "1":
        return 0
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    path = (data.get("tool_input") or {}).get("file_path") or ""
    norm = path.replace("\\", "/")
    if "tests/fixtures/" in norm:
        sys.stderr.write(
            "Blocked: tests/fixtures/ holds golden files. Update them only as a "
            "deliberate, reviewed step by setting MANA_UPDATE_GOLDENS=1.\n"
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
