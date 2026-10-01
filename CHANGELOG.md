# Changelog

## [0.1.1]

- Use `_meta.lua` as the single source of truth for the plugin version across runtime UI, update checks, HTTP user-agent reporting, README synchronization, and release packaging.
- Add built-in GitHub release update checks with automatic prompts, a manual **Settings > About > Check for Updates** action, user-confirmed installation, and restart prompting.
- Support and regression-test both three-part versions such as `0.1.1` and future four-part versions such as `0.1.1.2` in GitHub release packaging and updater comparisons.
- Render real covers and the placeholder cover at the same calculated card dimensions, including explicit SVG scaling for the placeholder to prevent clipping or overlap.

## [0.1.0]

- Initial standalone KOReader plugin release, exported from send2ereader_v2.
- Send the current book or a selected file through a Send2Ereader server.
- Create and join transfer sessions with session-code and QR-code sharing.
- Browse session books in grid or list view and download to a chosen folder.
- Configure the server, browser layout, and download folder; inspect diagnostic logs.
- Add verified release ZIP packaging and GitHub Actions with the complete Lua test suite.
