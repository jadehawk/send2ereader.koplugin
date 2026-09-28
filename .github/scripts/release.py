#!/usr/bin/env python3
"""Build and verify the installable ZIP using the established plugin layout."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "send2ereader.koplugin"
REQUIRED = {
    "_meta.lua", "main.lua", "diagnostic_log.lua",
    "send2ereader/client.lua", "send2ereader/session_browser.lua",
    "send2ereader/settings_dialog.lua",
    "dependencies/icons/close.svg", "dependencies/icons/placeholder-cover.svg",
    "dependencies/icons/refresh.svg", "dependencies/icons/send2ereader-eink.png",
    "dependencies/icons/settings.svg", "dependencies/icons/view-grid.svg",
    "dependencies/icons/view-list.svg",
    "spec/client_test.lua", "spec/diagnostic_log_test.lua",
    "spec/plugin_state_test.lua", "spec/settings_dialog_test.lua",
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", help="Require this tag to match the plugin version")
    args = parser.parse_args()
    meta = (PLUGIN / "_meta.lua").read_text(encoding="utf-8")
    match = re.search(r'^\s*version\s*=\s*"(\d+\.\d+\.\d+(?:\.\d+)?)"\s*,?\s*$',
                      meta, re.MULTILINE)
    if not match:
        raise SystemExit("Invalid plugin version in _meta.lua")
    version = match.group(1)
    tag = "v" + version
    if args.tag and args.tag != tag:
        raise SystemExit(f"Tag mismatch: {args.tag}; expected {tag}")
    main_lua = (PLUGIN / "main.lua").read_text(encoding="utf-8")
    if not re.search(r'^local VERSION = "' + re.escape(version) + r'"$',
                     main_lua, re.MULTILINE):
        raise SystemExit("main.lua version must match _meta.lua")

    readme_path = ROOT / "README.md"
    readme = readme_path.read_text(encoding="utf-8")
    pattern = r"^Current plugin version: \*\*[^*]+\*\*$"
    if len(re.findall(pattern, readme, re.MULTILINE)) != 1:
        raise SystemExit("Expected exactly one README version line")
    updated = re.sub(pattern, f"Current plugin version: **{version}**",
                     readme, flags=re.MULTILINE)
    if updated != readme:
        readme_path.write_text(updated, encoding="utf-8", newline="\n")

    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    notes = re.search(r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## \[|\Z)",
                      changelog, re.MULTILINE | re.DOTALL)
    if not notes or not notes.group(1).strip():
        raise SystemExit(f"Missing changelog notes for {version}")

    files = sorted(path for path in PLUGIN.rglob("*") if path.is_file())
    names = {path.relative_to(PLUGIN).as_posix() for path in files}
    if missing := REQUIRED - names:
        raise SystemExit(f"Missing required package files: {sorted(missing)}")
    for path in PLUGIN.rglob("*"):
        relative = path.relative_to(PLUGIN)
        if path.is_symlink() or any(part.startswith(".") for part in relative.parts):
            raise SystemExit(f"Unexpected hidden file or symlink: {relative}")
        if path.is_file() and path.suffix not in {".lua", ".svg", ".png"}:
            raise SystemExit(f"Unexpected plugin file: {relative}")

    expected = {"README.md": readme_path.read_bytes()}
    expected.update({path.relative_to(ROOT).as_posix(): path.read_bytes() for path in files})
    output = ROOT / "dist"
    output.mkdir(exist_ok=True)
    archive = output / "send2ereader.koplugin.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for name, payload in sorted(expected.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            z.writestr(info, payload)
    with zipfile.ZipFile(archive) as z:
        if len(z.namelist()) != len(expected) or set(z.namelist()) != set(expected):
            raise SystemExit("Archive layout mismatch")
        if z.testzip() is not None:
            raise SystemExit("Archive CRC failure")
        for name, payload in expected.items():
            if z.read(name) != payload:
                raise SystemExit(f"Archive content mismatch: {name}")

    (output / "release-notes.md").write_text(notes.group(1).strip() + "\n", encoding="utf-8")
    if github_output := os.environ.get("GITHUB_OUTPUT"):
        with open(github_output, "a", encoding="utf-8") as out:
            out.write(f"version={version}\ntag={tag}\n")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    print(f"PASS: {tag}; {len(expected)} verified ZIP entries; sha256={digest}")


if __name__ == "__main__":
    main()
