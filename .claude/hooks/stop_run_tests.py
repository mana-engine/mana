#!/usr/bin/env python3
"""Stop hook: run the test suite and surface failures.

Enforces "never declare a task done without green tests". On failure it blocks
the stop (exit 2) and feeds the tail of the output back to Claude. A loop guard
(`stop_hook_active`) ensures it fires at most once per stop so it can never trap
the session.
"""
import json
import subprocess
import sys


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}
    if data.get("stop_hook_active"):
        return 0  # already fired this stop; let it through
    proc = subprocess.run(
        ["mise", "run", "test"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write("`mise run test` failed — do not stop with red tests:\n")
        sys.stderr.write((proc.stdout or "")[-4000:])
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
