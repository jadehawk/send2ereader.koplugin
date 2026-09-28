#!/usr/bin/env python3
"""Check all plugin Lua syntax and run the complete isolated Lua test suite."""
import argparse
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plugin", type=Path, default=ROOT / "send2ereader.koplugin")
    args = parser.parse_args()
    plugin = args.plugin.resolve()
    files = sorted(plugin.rglob("*.lua"))
    tests = sorted((plugin / "spec").rglob("*_test.lua"))
    if not files or not tests:
        raise SystemExit("Missing plugin Lua files or test suite")
    for path in files:
        subprocess.run([os.environ.get("LUAC", "luac5.1"), "-p", str(path)], check=True)
    print(f"Syntax passed: {len(files)} Lua files", flush=True)
    for path in tests:
        print(f"Running {path.name}", flush=True)
        subprocess.run([os.environ.get("LUA", "lua5.1"), path.as_posix()],
                       cwd=plugin.parent, check=True)
    print(f"PASS: all {len(tests)} Lua test files", flush=True)


if __name__ == "__main__":
    main()
