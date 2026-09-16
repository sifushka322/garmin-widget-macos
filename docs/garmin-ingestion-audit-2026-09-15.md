# Garmin data-ingestion audit — September 15, 2026

## Conclusion

A follow-up check located the failure: the app module's first login request returned HTTP 429 and Garmin JSON error code 429, before token issuance or measurement retrieval. Meanwhile, the existing Garmin Connect session in Chrome displayed real data, and an official daily export was successfully downloaded and verified. The main issue in the version reviewed was the module's initial login method; related session-persistence and diagnostic defects were fixed. The previous `429` response does not prove an incorrect password, an account-specific or IP-specific restriction, or a recovery deadline. The 30-minute pause was our retry-limiting measure, not a wait time supplied by Garmin.

A self-contained `.app`, SwiftUI, and WidgetKit do not solve Garmin access: the app uses unofficial Garmin Connect interfaces. Connection reliability must be verified separately with a real account and restoration of a saved session. This document records the September 15 investigation, not the status of subsequent implementations.

## Findings in our implementation

| Finding | Consequence | Status |
| --- | --- | --- |
| Only the mobile login method remained | It has a known history of 429 failures; waiting alone does not fix an incompatible login method | The exact stage and supported path need verification |
| The session was returned only after all measurement requests | A successful login or refreshed token could be lost after a later failure | Fixed: a separate session event before downloading and when tokens change |
| App watchdog allowed 120 seconds versus the module's 180-second budget | The app could interrupt a download still in progress | Fixed: 210 seconds per stage |
| Different causes became “network” or “sign in again” | API 401, access denial 403, a security challenge, and rate limiting 429 could not be distinguished | Safe stage, HTTP-code, Garmin-code, and Retry-After diagnostics added |
| The library accepts a web-cookie-only session but serializes only DI tokens | Such a session would not survive a restart | Now explicitly rejected as unsupported, without claiming an incorrect password |
| All 12 measurement groups and devices are requested on every refresh | At least 14 requests per sync including the profile check; some data rarely changes | Separate schedules and requests limited to needed groups are recommended |

The library author posted an [August 11 report of frequent failures in the initial mobile strategies](https://github.com/cyberjunky/python-garminconnect/discussions/387). It predates the installed 0.3.15 release from September 12 and does not prove that release fails for everyone. However, selecting it as the only route without a successful account check was insufficiently justified.

The installed library was current at the time of this audit. Reverting to garth was not considered a solution: its [final release](https://github.com/matin/garth/releases/tag/v0.8.0) announces the end of support for new logins after Garmin's changes.

## Data-access options

| Option | Provides | Limitation |
| --- | --- | --- |
| Garmin Connect through a saved local session | Broad metric coverage, automatic refresh, no developer-operated server | Unofficial interface; login, data retrieval, and session restoration must first be demonstrated |
| Normal website login + daily Wellness Export | Official access to FIT files for steps, sleep, stress, and HRV; suitable for backup import | Manual export; Body Battery and readiness must still be confirmed in the specific archive |
| Official Garmin Health API | A supported integration | Requires admission to Garmin's program; not a ready-to-use public API for a personal Mac app |
| Apple Health | Some metrics through an iPhone | Does not transfer the full required Garmin data set; macOS has no direct HealthKit store |
| Direct fēnix 8 access | Device files may be available through MTP and a separate access implementation | Not a ready replacement for Connect or guaranteed coverage of every metric |

The backup route requires a [daily wellness-data export](https://support.garmin.com/en-IE/marine/faq/W1TvTPW8JZ6LfJSfK512Q8/), not just workout exports. Detailed primary sources and limitations are in the [data-source audit](audit-data-options.md).

## Proposed path to a working connection

1. Perform one authorized check with the new diagnostics after observing the pause following a failure. Do not change IP, TLS fingerprint, or client to bypass the restriction.
2. Separate the stages: login → token issuance → API acceptance of the token → profile → measurements. On failure, retain only safe diagnostic details.
3. On success, immediately save the session in Keychain. Confirm restoration in a separate fresh process without entering the password again.
4. If normal web login is available, download a daily Wellness Export as the official backup route to real data. This does not imply that the browser automatically yields a session usable by our DI client.
5. Once data is verified, separate refresh frequencies: current summary more often, sleep/HRV/training assessments less often, device list rarely. Widgets read the local cache.

Readiness means real readings plus successful session restoration after restart. Demo data, compilation, and synthetic-response tests do not replace this criterion.

## Checks and remaining uncertainty

The module's 34 tests passed, including safe diagnostics, early session persistence, retention of a refreshed token after a later failure, and error classification. Native app type checking passed. Real secrets were not written to source, diagnostic reports, or build artifacts.

### Real-data validation

The user's Garmin Connect account opened successfully in the existing Chrome session with a current summary. No password re-entry was required. The standard health-data export section downloaded a daily ZIP for September 15, 2026 (31,774 bytes).

The official Garmin FIT SDK 21.214.0 verified all 11 FIT files: integrity/CRC and decoding completed without errors. Publicly documented fields confirmed steps, distance, active calories, heart rate, resting heart rate, stress, SpO₂, respiration, overnight HRV, sleep score, and sleep stages. Body Battery and training assessments had not yet been confirmed through documented fields; unrecognized messages were not interpreted by guesswork.

The archive remained in the user's Downloads folder and was not included in source or the build. This was a verified manual export, not working automatic GarminDesk synchronization. FIT import in the app was not yet implemented. Details: [archive validation](audit-wellness-export.md).

Automatic permission review had previously rejected entering a username and password in a new Garmin SSO web form. That entry was not performed; using the existing authenticated session required no password transfer.

### App-module recheck

After a conservative 30-minute pause, one check of the packaged module ran through a local diagnostic process. Saved credentials were read from Keychain and passed to the module only through stdin. The check did not use browser cookies or change the IP, TLS fingerprint, or login route.

Result at 18:52 Moscow time:

- `stage: login`, `requestCount: 1`.
- `httpStatus: 429`, `apiErrorStatus: 429`.
- `responseKind: json`, `challenge: false` (absence of a known marker does not exclude other Garmin protection).
- No `Retry-After` received.
- No token or snapshot received; session-restoration validation therefore did not run.
- Further requests stopped; the local pause remained in place.

At the end of this investigation, automatic GarminDesk connection remained unavailable despite data access through the normal website. Successful browser access did not establish that the selected programmatic login worked or provide an automatically transferable DI session.

Details: [authentication](audit-auth.md), [data flow](audit-data-flow.md), [data sources](audit-data-options.md).
