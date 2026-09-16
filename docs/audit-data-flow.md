# GarminDesk data-flow audit

Reviewed on September 15, 2026: `AppStore.swift`, `PythonBridge.swift`, `Connector/bridge.py`, and the locally installed `garminconnect==0.3.15`. The review used no credentials, Keychain access, or real Garmin requests. The four scenarios below were reproduced with `unittest.mock` and invented values. Line numbers in the findings refer to the state **before the fixes**. This report describes that historical implementation.

Following the audit, a separate request addressed the Swift side: it accepts early `session` events, stores safe structured diagnostics, uses a 210-second watchdog for each stage, and cancels the request and stops using the in-memory session if a Keychain write fails. `access_denied` and `security_challenge` are no longer classified as `auth`; actual `auth` failures no longer suppress Keychain deletion errors. Type checking of all app Swift sources passed. Connector changes that emit the new events are handled separately; these results alone do not verify Garmin sign-in.

## Findings

### P1 — successful authentication is lost after a subsequent download failure

**Locations:** `Connector/bridge.py:480–499`, `Connector/bridge.py:329–352`, `Sources/GarminDesk/AppStore.swift:170–179`.

`execute()` first completes `client.login()` or loads an existing session, validates the profile, then requests every data group. Only after `fetch_snapshot()` does it call `client.dumps()` and return the session. Swift saves the session only with a successful `result`.

A successful login followed by a 429 from the second data group is enough to trigger the problem: the first group has loaded, but only `error.rate_limit` is returned. The session never reaches Keychain, the user remains disconnected, and they must enter their password again after waiting. A complete network failure after successful login has the same result.

During `sync`, the existing session remains, but tokens refreshed inside the process are not returned either. The library does refresh `di_token`, and sometimes `di_refresh_token`, in `client.py:1378–1419`; refresh runs before a request when the token is close to expiration and after a 401 (`client.py:1641–1644`, `1682–1689`). The old refresh token cannot be assumed to remain valid after replacement; this audit did not test Garmin's invalidation policy.

**Specific fix:** separate session delivery from the data result. Add a `session` event carrying an opaque session and a Swift handler that saves it to Keychain without requiring a `snapshot`. Emit the post-login session before requesting data groups; after a successful DI-token refresh, immediately emit the new version when its contents change. For the pinned library version, this can wrap successful `_refresh_di_token` calls without letting the library write tokens to disk. A download failure should retain the latest usable session and previous data snapshot while still displaying the error. A session event must not replace real readings with demo data.

**Validation:** successful login → 429 on the second group must emit a session and an error, without another `login` call; token refresh → subsequent network failure must preserve the new session. Also test Keychain failure, cancellation, and rejection of session writes from an already cancelled `requestID`.

### P2 — Swift's timer terminates the process before its own budget expires

**Locations:** `Sources/GarminDesk/AppStore.swift:98–100`, `160–169`, `204–210`; `Connector/bridge.py:22–23`, `465–478`, `530–535`.

Swift allows 120 seconds for a normal request and for continuation after MFA. Python allows 180 seconds of network work and a separate 180 seconds waiting for MFA. A network operation still within the connector's own budget is therefore forcibly terminated after 120 seconds. This matters particularly when reading 14 data-group/profile requests sequentially: a standard library request has a 15-second timeout, while DI-token refresh allows 30 seconds.

There is no need to assume Garmin is always slow: any eight consecutive 15-second waits exhaust the shorter Swift timer. The connector cannot return its final state, and accumulated data and the new session are affected by the previous finding. During MFA, the mismatch is reversed: the UI waits up to 300 seconds, but the process stops waiting after 180 and classifies the deadline as `network`.

**Specific fix:** align the budgets. For example, retain 180 seconds for the process's network and MFA stages, and allow 200 seconds per stage in the outer watchdog. On `mfa_required`, restart the appropriate outer timer; after code submission, restart the network timer. Report an internal deadline expiration as `timeout`, which Swift can already localize, instead of `network`. Add that key to `ERROR_MESSAGES` and the protocol's allowed codes. Do not increase the number of retries. The implemented Swift fix noted above uses 210 seconds per stage.

**Validation:** use a fake clock to test network → MFA → network transitions and ensure that external termination does not precede the internal deadline. Tests do not need real 180-second waits.

### P2 — an unexpected profile format incorrectly deletes the session

**Locations:** `Connector/bridge.py:491–494`; `Sources/GarminDesk/AppStore.swift:189`.

After completed login, a profile of `{}` or a response without `displayName` becomes `BridgeError("auth")`. Swift interprets this code as proven session invalidity and deletes the saved token. A missing required response field is not a server authentication failure. For example, the library converts HTTP 204 to an empty object (`client.py:1694–1711`), so these states can be distinguished.

**Specific fix:** classify a missing or incorrectly typed `displayName` as `protocol`, and add a corresponding safe connector message. Delete the session only on a confirmed authentication failure. Do not request further data groups without `display_name`, because their URLs require it.

**Validation:** successful login/session restoration → empty profile must return `protocol` and retain the available session and previous readings. An actual authentication failure must still move the app to its disconnected state.

## Offline reproduction results

A `Mock` API was used inside `execute()`; local responses replaced `login`, `loads`, the profile, and all metrics. No real client was created. Session-event counts below include only messages sent through `emit`.

| Scenario | Code | login calls | loads calls | dumps calls | Session events |
|---|---:|---:|---:|---:|---:|
| Login succeeds; second group returns 429 | rate_limit | 1 | 0 | 0 | 0 |
| Session restored; second group returns 429 | rate_limit | 0 | 1 | 0 | 0 |
| Login succeeds; all groups fail with network errors | network | 1 | 0 | 0 | 0 |
| Login succeeds; profile lacks displayName | auth | 1 | 0 | 0 | 0 |

The token-rotation scenario was established from call order and the installed client's code, not a real Garmin token refresh.

## Request frequency and metric availability

- The catalog contains **26 metrics**, but one synchronization performs **12 metric-group requests + a profile request + a device-list request**: 14 ordinary requests before authentication, token refresh, and the internal retry after 401. This follows from `ENDPOINTS`, `fetch_snapshot()`, and `execute()`.
- At the default 15-minute interval, this is approximately **56 ordinary requests per hour**; at the allowed 5-minute interval, **168 per hour**, while the app is running. Profile configuration does not reduce requests: the connector does not receive the selected metric list. Manual refreshes add to these counts.
- These counts **do not establish the cause of the current Garmin restriction**. The reviewed source contains no confirmed safe quota for the user's account. Without server evidence, 56 requests cannot be declared the cause of a 429.
- A concrete optimization is to cache an unchanged device list separately instead of fetching it on every refresh, and validate the profile and retain `displayName` in the local session instead of fetching it during every normal sync. Repeat validation when restoring/changing a session. Keep an all-data mode for the overview, but allow less frequent requests for slowly changing groups such as sleep/HRV/weight.
- All groups are requested only for **today according to the Mac's calendar** (`bridge.py:324`). Weight may therefore be absent without a weigh-in today, even if yesterday's weight is available in Garmin Connect. The reviewed code neither promises nor implements a search for the latest value from earlier days. A product showing “latest weight” needs a separate bounded lookback with the measurement date; yesterday's reading must not be presented as today's.
- Support for 26 fields does not mean support for every fēnix 8 capability. A successful HTTP response with missing fields does not invent readings: they remain absent. For an empty result, the connector adds `no_data`; the reviewed UI displays the generic “Some readings are unavailable.” A more precise message for this state is “Garmin returned no readings for the selected day.”

## Behavior already handled consistently

- A normal nonfatal error in one group preserves successfully loaded groups and adds `unavailable.GROUP`.
- A 429 stops further requests. After the Swift fix, a pause of at least 30 minutes survives restarts and respects the server's `retryAfterSeconds`, capped at seven days. This is the app's waiting policy, not a promise about when Garmin will lift its restriction. Network failure does not automatically delete the previous session.
- On `auth`, memory moves to the disconnected state while the previous snapshot remains visible with that status. After restarting without a session, `init()` replaces it with demo data (`AppStore.swift:66–68`): the product should define this inconsistent behavior explicitly. For reliable offline viewing, retain the last real snapshot with `isConnected=false` until the user explicitly deletes it.
- Explicit `disconnect()` now clears memory before file operations, so failed cache deletion cannot let a timer restore the session in the current process. At the time of the finding, the `auth` branch still suppressed Keychain deletion errors with `try?`; if deletion failed, the old token could be read on the next launch. Error handling needed to be explicit, as in `disconnect()`. The post-audit Swift fix is recorded at the start of this report.
- stdout is read outside MainActor, and stderr is drained. Cancellation closes stdin, terminates the process, and changes `requestID`, so a late event from the cancelled operation is not applied to AppStore. Source review found no blocking race in these paths.

## Scope of the conclusion

This audit identifies reproducible state-persistence and timer-coordination defects. It does not establish the cause of a particular Garmin response during the user's login or confirm availability of all 26 metrics in their account. Those require a successful connection and real data retrieval; this audit performed neither.
