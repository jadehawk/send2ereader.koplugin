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

A reachable, compatible Send2Ereader server is required. Allowed file types, size limits, and session lifetime are controlled by the server administrator; deployments commonly use a session lifetime of 15 minutes or more. The plugin follows the server-provided expiry rather than assuming a fixed duration. This repository contains the KOReader plugin; it does not install the server.

## Update and troubleshoot

To update, close KOReader, replace the plugin folder with the folder from the new release, and restart. Persistent settings and logs live under KOReader's settings directory, outside the plugin folder.

If a transfer fails, check Wi-Fi, server connection, session validity, and the download folder. Settings provides connection testing, debug logs, and the settings/log paths.

## Support

If you find the plugin useful, you can support development here:

<https://buymeacoffee.com/jadehawk>

Tutorials, demos, and project updates are available on YouTube:

<https://youtube.com/jadehawk>
