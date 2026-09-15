# Native web session: live validation

> Historical validation for GarminDesk 0.2.0 (through build 7). The app changes to a regular Dock/window interface in 0.3.0. See [0.3.0 release validation](releases/0.3.0.md); these earlier checks do not validate its new UI or packages.

Validated on **macOS 26.6.2, Apple Silicon**. The final **GarminDesk 0.2.0 build 7 is installed and open in `/Applications`**, and its ZIP/DMG are verified. The live observations below were accumulated across local development builds. Personal health values and account/session identifiers are intentionally excluded.

## Confirmed live behavior

- The normal Garmin sign-in page loads in the application's persistent WKWebView, and normal sign-in succeeds.
- Saved-session restoration without a password prompt succeeded after a full app restart. A later startup after two hours closed exposed the redirect timing issue described below; it does not establish that restoration already works in every startup state.
- Unattended background updates continued for several hours, without pressing Refresh or taking other actions. The app retrieved **12 data groups and 25 real metrics**. Real values in the native panel were compared with Garmin's page during validation.
- Missing weight is shown as unavailable. Missing values are not manufactured as zero.
- The training timeline contains **20 recent completed activities**. The corrected date parser was checked live: **20/20 activities have valid start dates**. Requests for the published calendar of the current and following month succeeded and returned no upcoming entries, with continuous verified coverage through **2026-10-31**.
- Four GarminDesk kinds appeared in the actual WidgetKit gallery. Two medium desktop instances produced live timelines, and the user confirmed real measurements on the widgets.
- All four static widget slots were assigned in the native UI and saved in the shared snapshot. Five profiles and all four assignments survived the update. The user confirmed that clicking a system widget opens GarminDesk's top panel.
- The self-contained build 7 app and its ZIP/DMG were verified locally. Default execution uses Swift and system WebKit; Python and additional libraries are not needed by the recipient.

## Startup follow-up and the date boundary

After the app had been closed for two hours, startup classified the website as unauthenticated before Garmin's automatic sign-in redirect completed. Clicking **Restore** in GarminDesk recovered the saved session without entering credentials or interacting with the website. The final source now includes a bounded bootstrap wait of up to **45 seconds**. Build 7 honored the saved transient pause and then completed an unattended timer cycle after restart, using the restored session without Refresh, Restore, credential entry or website action. No authentication gate or sync warnings remained. This confirms the nominal restart path; the exact earlier two-hour-closed interval was not repeated after the fix. See [overall validation](validation.md).

After midnight on 16 September, successfully retrieved new-day responses contained no fresh measurements at the time of observation, consistent with a new day before fresh watch data is available. The UI displayed a clear no-data message. Prior-day readings were not represented as current, and absence was not converted to zero. This is distinct from an authentication failure; no personal values are recorded here. In the final build 7 cycle, all 12 groups received fresh retrieval state and the connected widget snapshot matched its timestamp. The HTTP 204 HRV response correctly followed the valid no-data path, with no sync or training warnings, rather than producing the previous spurious transient pause. All 20 activity dates, five profiles and four widget assignments remained valid, and the next automatic refresh was scheduled.

Actual RU → EN → system-language switching was checked. The launch-at-login setting is enabled and persisted, without claiming an OS reboot/login test. The multi-device header now says Garmin Connect.

## Request implementation

An early native API request returned HTTP 403 because it omitted Garmin's `connect-csrf-token` header. The corrected same-origin, read-only request reads that value from the Garmin page's meta element and uses it entirely inside WebKit. It does not return the value to Swift or write it to the application's JSON files. WebKit manages the cookies.

The page meta/header pattern is also visible in the primary source implementations [Garmin Connect MCP](https://github.com/etweisberg/garmin-connect-mcp/blob/main/src/tools.ts) and [its API client](https://github.com/etweisberg/garmin-connect-mcp/blob/main/src/garmin-client.ts). GarminDesk does not use their browser-cookie export/session-file approach.

## Scope and final-build status

This establishes live ingestion, persistent normal website sign-in, several hours of unattended refresh, and actual widget consumption on the tested Mac. It does not prove that Garmin will never expire a session or that every endpoint, watch or account has data. An empty published calendar is distinct from adaptive plans that may not appear in that response.

Offline checks cover malformed payloads, zero versus missing values, access denial, rate limits, cancellation, partial cache retention, scheduling, date changes and training coverage. Those checks supplement the live observations; they do not establish every failure scenario on a real account.

Final build 7 is installed, and its exact app, ZIP and DMG have passed artifact verification. New focused offline checks passed: 48 boundary, 60 JavaScript and 74 training checks. The medium layout has passed 12 RU/EN × density × metric-set renders, plus two large renders. Intel, the minimum macOS version, other Macs and the prepared GitHub workflow remain future compatibility checks, not blockers to the tested personal installation. The optional App Intents per-instance picker remains separate from the working static-slot configuration. See [overall validation](validation.md).
