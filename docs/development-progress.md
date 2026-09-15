# Development progress — automatic sync and widgets

> Historical validation for GarminDesk 0.2.0 (through build 7). The app changes to a regular Dock/window interface in 0.3.0. See [0.3.0 release validation](releases/0.3.0.md); these earlier checks do not validate its new UI or packages.

The final local artifact is **GarminDesk 0.2.0 build 7**, installed and open in `/Applications` on macOS 26.6.2, Apple Silicon. App, ZIP and DMG verification is complete. This ledger contains no personal health values or account information.

## Completed and observed

- Native Garmin sign-in through persistent system WebKit, real data ingestion and saved-session restoration without re-entering credentials. The final source includes a bounded startup wait; the nominal post-restart automatic cycle passed in build 7.
- Several hours of unattended background updates. The current integration retrieved **12 groups / 25 real metrics**, with honest unavailable states, including absent weight.
- A training timeline with **20 recent completed activities** and a successfully retrieved, empty published calendar covering the current and following month through **2026-10-31**. Empty, unavailable and stale sections remain distinct.
- Actual RU → EN → system-language switching and switching between training and lifestyle profiles. Five profiles and all four widget slots survived the update. The launch-at-login preference is enabled and persisted; OS login/reboot behavior is not claimed by that check.
- Valid start dates for **20/20 real past activities** after the parser correction.
- Revised medium-widget layout checked across **12 RU/EN × density × metric-set PNG cases**, plus **two large renders**.
- A neutral Garmin Connect header for multiple devices and a clear no-data state after the date boundary, without carrying old measurements forward as today's values.
- Actual WidgetKit execution after correcting the extension entry point to `_NSExtensionMain`: **four gallery kinds, two medium desktop instances and live timelines**. The user confirmed real measurements on the widgets.
- All four static widget slots assigned through the app UI and persisted in shared data. Clicking a system widget opens the top panel, confirmed by the user.
- Shared widget JSON without an Apple Account or App Group. A narrow read-only sandbox exception was first checked with synthetic files and is now also used by the working WidgetKit provider.
- Self-contained native Swift/WebKit packaging, verified build 7 ZIP/DMG, and installation under `/Applications`. Python is an explicit legacy opt-in, absent from the default bundle.

## Final build 7

Build 7 is installed and open. The built, ZIP-extracted and installed host/widget executables have identical SHA-256 hashes and matching versions. Structure, ad-hoc signatures, system-only dependencies, DMG CRC and both artifact checksums passed. ZIP size is 2,492,037 bytes; DMG size is 2,642,915 bytes. Archive checks found no private runtime files, optional Python runtime or embedded developer home path.

The final source contains the bounded startup-session wait. The existing transient backoff remains in force. New focused checks passed: 48 boundary, 60 JavaScript and 74 training checks.

**Final runtime check passed:** after restart and the preserved transient pause, build 7 fetched automatically without Refresh, Restore, credentials or website actions. The new WebKit session was available; sync and training warnings were empty. All 12 groups, including HRV, received updated retrieval state, and the connected widget snapshot had the same timestamp with five profiles and all four slots intact. All 20 activity dates remained valid; the next automatic refresh was scheduled.

The new day contained no measurements yet, and the UI correctly showed the empty-day message. HTTP 204 for HRV now means a valid empty response, without false zero values or the old spurious transient pause. This verifies the nominal automatic cycle after restart; the exact two-hour-closed scenario from build 5 was not repeated after the boundary fix.

## Future publication and compatibility

Wider platform checks expand support; they are not blockers to the tested personal installation.

- No public release has been published. For public source, review the exact staged files; publication without a selected license is authorized; no license is chosen by this work.
- The GitHub workflow is prepared but has not run. Intel, other macOS releases, the macOS 14 minimum target and a separate clean Mac are not yet verified.
- The local release uses four static widget kinds whose profiles are assigned in the app. The optional Xcode/App Intents variant has not been validated as an independent system profile picker.
- Two medium desktop instances do not establish every widget size, Notification Center, reboot or session-expiry scenario. Several hours of live sync do not establish indefinite Garmin session validity.
- Ad-hoc signing is the technical minimum used by this release. Apple Account, paid Developer ID and notarization are outside the selected distribution model. A trusted download may require the standard macOS first-open confirmation.

Historical Python login failures and the separate manual wellness export are recorded in the validation history. They are not current blockers to the native connection or system widgets.

Details: [validation](validation.md), [live connection](native-web-live-validation.md), [WidgetKit runtime](widget-runtime-validation-plan.md), [publication checklist](publication-checklist.md).
