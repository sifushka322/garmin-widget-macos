# Validation status

> Historical validation for GarminDesk 0.2.0 (through build 7). The app changes to a regular Dock/window interface in 0.3.0. See [0.3.0 release validation](releases/0.3.0.md); these earlier checks do not validate its new UI or packages.

Current artifact: **GarminDesk 0.2.0 build 7**, installed and open in `/Applications` on **macOS 26.6.2, Apple Silicon**. Its native app, ZIP and DMG are verified. The live feature evidence below was accumulated across development builds on this Mac. No account identifiers, personal measurements or session material are included.

## Confirmed in the installed application

- Normal Garmin sign-in works in the application's persistent WebKit window. A full app restart restored the saved website session without another password prompt. A later startup after two hours closed exposed a premature authentication decision during Garmin's automatic sign-in redirect; clicking Restore in the app recovered the existing session without credentials or an action on the website. The final source includes a bounded startup wait of up to 45 seconds. Build 7 completed a nominal unattended cycle after restart and the saved pause, as recorded below; the exact two-hour-closed scenario was not repeated after the fix.
- Background updates continued for several hours without pressing Refresh or taking other actions. The app obtained **12 data groups and 25 real metrics**. Missing weight data remains unavailable rather than becoming zero.
- The app retrieved **20 recent completed activities**. After the date parser correction, **20/20 real activities had valid start dates** in a live check. The app also successfully checked the published calendar for the current and following month. The calendar was empty, with verified coverage through **2026-10-31**. This is an empty published calendar, not a failed request or proof about every adaptive training plan.
- **Four GarminDesk widget kinds appeared in the actual macOS gallery. Two medium instances ran on the desktop with live timelines.** The user confirmed that the widgets displayed real measurements.
- All four static widget slots were assigned through the native app UI; the saved shared data contains their profile mappings. All five profiles and four slot assignments survived the app update. The user also confirmed that clicking a system widget opens the top GarminDesk panel.
- The runtime fix uses the extension linker entry point `_NSExtensionMain`. Earlier PlugInKit registration and standalone view previews were only preliminary evidence; gallery execution and live data are now separately confirmed.
- Build 7's self-contained **ZIP and DMG were verified**. The installed default app consists of native Swift code, WidgetKit and system WebKit, without a Python runtime or recipient-installed libraries.
- After the date changed to 16 September, the app showed a clear no-data state for the new day where fresh measurements were not yet available. It did not relabel the previous day's values as current data or invent zero values.
- The actual UI was switched RU → EN → system. The launch-at-login preference was enabled and persisted; this is not a claim of a tested full OS login/reboot. Accounts with multiple devices now use the neutral Garmin Connect header.

See the [live connection report](native-web-live-validation.md) and [WidgetKit runtime report](widget-runtime-validation-plan.md).

## Supporting local checks

- Host and extension compile with Swift 6.3.3 in Swift 5 language mode, targeting macOS 14 with the compatible macOS 26.5 SDK.
- Shared-model checks cover missing values versus zero, localization, invalid numbers, profile changes, disconnected state, malformed caches and file protection. Training presentation has **18 passing checks** for date, duration, distance, absence and coverage formatting.
- Host lifecycle and scheduling checks are recorded with their individual counts and reproduction commands in [native sync validation](native-sync-validation.md). These synthetic checks exercise failure paths independently of live account validation.
- An ad-hoc sandbox test reads a synthetic file in the dedicated widget directory, rejects a neighboring read and rejects writes. Actual WidgetKit now also reads the published snapshot successfully.
- The revised medium layout was visually checked across **12 RU/EN × density × metric-set PNG cases**, plus **two large-widget renders**. Small widgets also received the earlier RU/EN render review. These visual checks do not imply that every size and placement has the same system-runtime coverage as the two medium desktop instances.
- Additional focused checks passed: **48 boundary checks, 60 JavaScript checks and 74 training checks**.
- Bundle structure and nested ad-hoc signatures were checked for build 7. The optional legacy connector has separate offline tests; it is absent from the default native bundle.

## Storage and distribution

No Apple Account, paid Developer ID, notarization or App Group is required by the locally validated configuration. The technical ad-hoc signature remains necessary. WidgetKit receives read-only access to the dedicated `Widgets/widget-data.json` snapshot; credentials and the WebKit session are not copied there. A configured App Group remains an optional alternative.

The selected GitHub distribution model is an unnotarized, self-contained application. First opening a trusted download can require the standard macOS **Open Anyway** confirmation. A separate clean Mac has not yet been tested. See [distribution](distribution.md).

## Final build 7 artifacts

- Built, ZIP-extracted and installed bundles all report build **7**. Host and widget executables are byte-identical across those copies, verified with SHA-256.
- Ad-hoc signature, bundle structure and system-only dependency checks passed.
- ZIP: **2,492,037 bytes**. DMG: **2,642,915 bytes**. The DMG passed `hdiutil` CRC verification; both files match the published local SHA-256 checksum file.
- The archive scan found no user caches, tokens, credentials, Connector, `.venv` or embedded developer home path. The obsolete `#filePath` fallback was removed; development fallback now requires explicit `GARMIN_DESK_DEVELOPMENT_ROOT` and is not part of normal native operation.

## Final unattended runtime check — passed

After restart, build 7 honored the saved transient pause and automatically fetched at the next permitted timer cycle. No Refresh, Restore, password entry or website action was used. The new WebKit session was available, with no active authentication gate and no sync warnings. All 12 groups, including HRV, received updated retrieval state.

The dedicated widget snapshot was connected and had the same retrieval timestamp; five profiles and all four slot assignments remained present. All 20 activities retained valid start dates, with no training warnings. The next automatic refresh was scheduled.

For the new day, 16 September, there were **no measurements yet**. The UI showed the explicit empty-day message and did not manufacture zeros. The HTTP 204 HRV response now follows the valid no-data path instead of the previous erroneous transient-failure/backoff path; this is a successful empty response, not a populated HRV measurement.

This confirms the nominal post-restart automatic cycle after a preserved pause. The earlier two-hour-closed startup race was reproduced in build 5 and covered by the 48 focused boundary checks for the fix; that exact elapsed-time scenario was not re-run after the fix.

## Future compatibility work

These checks expand support beyond the tested personal installation; they are not blockers to that local use.

- The GitHub workflow has **not run**. Intel, other macOS versions (including the macOS 14 deployment target), and a separate clean Mac remain unverified.
- The optional Xcode/App Intents configuration variant has not received local metadata extraction or gallery testing. The working local release uses four static kinds with profile assignment in the app.
- Long-running observation does not prove indefinite session validity, every Garmin endpoint, every watch, all widget sizes, or all Notification Center and reboot scenarios.
- Before publishing source, review the exact staged files. The owner has authorized public source without selecting a license; no license is assigned here. No license has been selected on the owner's behalf; no public release has been published by these checks.

## Historical investigations

The earlier optional Python/mobile login path received HTTP 429. That result is historical and does not describe the working native WebKit connection. A separate official wellness export was inspected outside the project; its private contents are neither source nor release artifacts. The export audit does not imply that a production FIT importer exists.
