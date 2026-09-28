# Send2Ereader for KOReader

Current plugin version: **0.1.0**

Send books from KOReader or receive books through a Send2Ereader server. Create or join a transfer session, share its code or QR code, and browse the session's books in a cover grid or list.

## Install

1. Download **send2ereader.koplugin.zip** from the [latest release](https://github.com/jadehawk/send2ereader.koplugin/releases/latest).
2. Extract it. Copy the complete **send2ereader.koplugin** folder into your device's **koreader/plugins/** directory.
3. Confirm that **koreader/plugins/send2ereader.koplugin/main.lua** exists; avoid an extra nested folder.
4. Restart KOReader and open **Send2Ereader** from its Tools menu.

The release ZIP contains a root README and the plugin folder. GitHub's automatically generated source archives also contain development files; use the named release ZIP for installation.

## Use

- Connect your reader to Wi-Fi and open Send2Ereader.
- In Settings, configure your Send2Ereader server and download folder, then test the connection. The default server is **https://send.techy-notes.com**.
- Create a session or join one using its session code. Other devices must use the same server.
- Send the currently open book or choose a file to upload.
- Browse the session's books and download them into your selected folder. Grid/list layout controls are available in Settings.
- Share the session code or QR code with the device you want to transfer books to.

A reachable, compatible Send2Ereader server is required. Allowed file types, size limits, and session lifetime are controlled by that server. This repository contains the KOReader plugin; it does not install the server.

## Update and troubleshoot

To update, close KOReader, replace the plugin folder with the folder from the new release, and restart. Persistent settings and logs live under KOReader's settings directory, outside the plugin folder.

If a transfer fails, check Wi-Fi, server connection, session validity, and the download folder. Settings provides connection testing, debug logs, and the settings/log paths.

## Development and releases

The plugin was exported from the authoritative ThinkForge **send2ereader_v2** workspace; see [SOURCE.md](SOURCE.md). Keep future source changes synchronized with that project before publishing.

With Python 3, Lua 5.1, and its compiler installed, run from this repository on Linux or WSL:

```sh
python3 .github/scripts/verify.py
python3 .github/scripts/release.py
```

Verification checks every Lua file and runs every **spec/*_test.lua** file in a separate process. The current suite covers the client, diagnostic logging, plugin state, and settings dialog. It uses KOReader stubs; device UI/network testing remains a separate manual check.

The build synchronizes this README's version from **_meta.lua**, validates the matching version in **main.lua**, checks the changelog, builds **dist/send2ereader.koplugin.zip**, and verifies every archived file against its source.

For a release, update both Lua version declarations and CHANGELOG.md, run both commands, commit, and push a matching **vX.Y.Z** tag (four-part versions are also supported). GitHub Actions runs the full Lua suite, validates the package, and publishes the ZIP with changelog release notes. Manual workflow dispatch publishes the version in the selected commit. Pull requests and branch pushes run the same checks without publishing.
