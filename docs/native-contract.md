# Native app and WidgetKit architecture

GarminDesk targets macOS 14+. The host is an AppKit menu-bar application with SwiftUI views; the embedded WidgetKit extension uses App Intents for per-widget profile selection.

## Responsibilities

- `Sources/GarminDesk/AppStore.swift`: login/MFA state, refresh scheduling, local preferences, Keychain session, snapshot persistence and publishing to WidgetKit.
- `Sources/GarminDesk/PythonBridge.swift`: asynchronous JSON-lines communication with the bundled frozen connector. Password and session use stdin, never process arguments.
- `Sources/GarminDesk/GarminDeskApp.swift`: menu-bar item, popover, settings window, wake handling and `garmindesk://settings` links.
- `Sources/GarminDesk/Views.swift`: dashboard, profile editor, connection form and system widget setup guide.
- `Sources/Shared`: Codable data contract and metric formatting compiled into both targets.
- `Sources/GarminDeskWidgets`: AppEntity profile query, configurable timeline provider and small/medium/large widget views.

The main application remains outside App Sandbox because it launches its bundled connector. The widget extension is sandboxed and reads a shared App Group snapshot. It does not launch Python, sign in, access the Keychain or fetch data over the network.

## Shared file

`widget-data.json` contains a version number, preferences, the latest Garmin snapshot and connection status. The application replaces this single file atomically and asks WidgetCenter to reload the timeline. Each widget reads a consistent combination of profiles and data. Credentials are never included.

The group identifier comes from `GARMIN_APP_GROUP` in both bundles' Info.plist. An absent identifier means sharing is unavailable; there is no fallback to another app's sandbox or an unprotected filesystem path. The app shows this state explicitly. The widget shows setup instructions when the shared data cannot be read.

Actual refresh timing belongs to macOS. The app periodically obtains new Garmin data while running, including after wake. A widget can retain a previously rendered snapshot after the app exits. The timestamp means data was retrieved from Garmin, not necessarily measured by the watch at that time.

## Profiles and rendering

A profile stores its stable UUID, display name, ordered metric IDs, primary metric, style and density. Each widget selects a profile through its own App Intent configuration. Changes to a selected profile are published automatically. A deleted profile produces an explicit reconfiguration message, rather than silently switching to unrelated metrics.

Small widgets display the primary metric. Medium widgets add two secondary metrics, or three with compact density. Large widgets add six or eight. The panel displays every selected metric in a scrollable view. Missing values display an em dash; progress bars are limited to meaningful goal ratios or 0–100 scales.

Both targets share Russian/English metric labels and locale-aware values. The default follows the system's preferred language. Widget gallery and App Intent labels use localized extension resources. Desktop appearance and placement are managed by macOS; the app's own theme setting affects its panel and settings.

## Local state and errors

The host stores preferences and snapshots under `~/Library/Application Support/GarminDesk` with private file permissions. The session is a generic-password Keychain item (`com.mikhail.garmindesk` / `garmin-session`). Disconnect clears in-memory authorization before fallible file operations, so the refresh timer cannot restore a disconnected session.

Cancellation and timeouts invalidate a request UUID, cancel the stream task and terminate the helper. MFA is explicitly cancellable. A missing metric is distinct from zero; partial endpoint failures preserve successful measurements and display a partial-data notice. The rate-limit response enforces a local cooldown.

See [connector protocol](connector-protocol.md) for payloads and units, and [distribution](distribution.md) for signing and build requirements. Real account login remains a separate manual acceptance check.
