# Local Garmin connector

`Connector/bridge.py` is a read-only client for Garmin's web services. There is
no HTTP listener, application backend, or telemetry service. Credentials and MFA
codes go directly to Garmin over HTTPS. The watch still needs to sync with Garmin
Connect: this does not pair with the watch or replace Garmin's cloud.

## Running and packaging

Development requires Python 3.12+ and the pinned packages in
`Connector/requirements-build.txt`. End users run the packaged Mac application;
they do not install Python, use pip, or open Terminal.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r Connector/requirements-build.txt
.venv/bin/python -m unittest discover -s Connector -p 'test_*.py'
scripts/build-connector.sh
```

The standalone output is `build/connector-dist/garmin-bridge/garmin-bridge`.
Copy its **entire containing directory**, including `_internal`, into
`Contents/Resources/Connector/garmin-bridge/` in the `.app`. The build script also
generates `build/connector-dist/THIRD_PARTY_NOTICES.txt` for the app's resources.
The interpreter's architecture determines the output architecture. Build arm64
and x86_64 on matching Python environments; this is not a universal binary.

`CONNECTOR_PYTHON`, `CONNECTOR_DIST_DIR`, and `CONNECTOR_WORK_DIR` can override
the script's development interpreter and output locations. Never point these
locations at a directory containing account data.

## JSON-lines protocol

Start a fresh process for every login, sync, or demo operation. Write one UTF-8
JSON object plus a newline to stdin. The only further input is an MFA response
if requested. Do not send secrets as command-line arguments, environment
variables, temporary files, or log messages. Keep stdin open until MFA has been
handled. A process exits after one final event: 0 for a result, 1 for an error.

Login request:

```json
{"command":"login","email":"YOUR_EMAIL","password":"YOUR_PASSWORD","isChina":false}
```

If Garmin requests a verification code, stdout emits and immediately flushes:

```json
{"event":"mfa_required"}
```

Reply on the **same process's stdin**:

```json
{"mfa":"123456"}
```

The process makes one attempt with the supplied code. Cancellation should
terminate the helper and discard its stdin data. A failed verification returns
an error; there is no automatic credential retry loop.

Subsequent synchronization:

```json
{"command":"sync","session":"OPAQUE_SESSION_RETURNED_BY_PREVIOUS_RESULT"}
```

Success:

```json
{"event":"result","session":"OPAQUE_UPDATED_SESSION","snapshot":{"fetchedAt":"2026-09-15T10:00:00Z","sourceDate":"2026-09-15","isDemo":false,"devices":["fēnix 8"],"metrics":{"steps":{"value":7248},"heartRate":{"value":64,"measuredAt":"2026-09-15T09:58:00Z"}},"warnings":[]}}
```

Before the final snapshot, the helper emits `{"event":"session","session":"OPAQUE_SESSION"}` immediately after obtaining a restorable DI session and whenever its serialized tokens change. The host must save these events in Keychain independently of measurement success. A later rate limit or timeout must not discard a session already saved. `result` continues to repeat the latest session for backward compatibility.

The helper can emit `diagnostic` events with a `diagnostic` object containing only `stage`, `httpStatus`, `apiErrorStatus`, `retryAfterSeconds`, `responseKind`, `requestCount`, and `challenge`. All fields are optional and constrained. No raw URLs, query strings, cookies, headers, response bodies, account identifiers or health values belong in diagnostics. A 429 takes priority over a simultaneous challenge marker so Retry-After is respected. Final API 401 is classified after the dependency finishes its standard token refresh/replay.

The session is a versioned JSON string enclosing the account region and the
client's serialized DI OAuth tokens. It must be treated as an opaque secret by
the native app and stored only in Keychain. It is not encrypted within the pipe.
Replace the Keychain value with the newest returned session because Garmin may
refresh its tokens while reading data. Email and password are not in this
envelope. The connector does not write any credentials, session files, or health
data. It uses `client.login`, `client.loads`, and `client.dumps` directly and
never `Garmin.login`, `client.load`, `client.dump`, or `logout` file operations.

Failure:

```json
{"event":"error","code":"auth","message":"Garmin sign-in is required. Check your credentials and verification code."}
```

The stable error codes are `auth`, `rate_limit`, `network`, `dependency`,
`access_denied`, `security_challenge`, `session_unsupported`, and `unknown`. The native app should localize codes; English `message` is a safe
fallback and never contains the underlying HTTP body, account data, or exception
text. Third-party logs and accidental stdout/stderr prints are suppressed.

## Demo and offline diagnostics

`{"command":"demo"}` returns a `result` with `isDemo:true`, 26 synthetic metrics,
and no `session`. It does not access the network or import Garmin dependencies.
Never persist it as real account data or remove the demo label in the UI.

`{"command":"diagnose"}` returns
`{"event":"diagnostics","ok":true,"connectorVersion":1,"garminconnect":"0.3.15"}`.
It constructs an unauthenticated client to load the embedded TLS extension and
checks the CA bundle, without making network requests. This is a release smoke
test, not a user sign-in flow.

Both commands work with a cleared environment, with no HOME, PYTHONPATH, venv,
or system Python. An example smoke test for the frozen helper:

```sh
printf '%s\n' '{"command":"diagnose"}' | env -i PATH=/usr/bin:/bin build/connector-dist/garmin-bridge/garmin-bridge
```

## Data meaning

Missing, null, non-finite, boolean, negative sentinel, and unknown-shape values
are omitted. Physiological values such as heart rate also reject zero. Valid
zero step counts, hydration amounts, and recovery times are preserved.

`fetchedAt` is download completion time, **not** watch synchronization time.
`sourceDate` is the calendar date requested in the Mac's local timezone.
`measuredAt` is included only when the API supplies an actual time for that
measurement. Timezone-free strings are interpreted as UTC only for documented
GMT/UTC fields. Aggregate daily values have no fabricated measurement timestamp.

| Metric key | Meaning and source field | Unit |
|---|---|---|
| steps / stepGoal | Daily summary `totalSteps` / `dailyStepGoal` | count |
| distance | `totalDistanceMeters` divided by 1000 | km |
| calories / activeCalories | `totalKilocalories` / `activeKilocalories` | kcal |
| floors | `floorsAscended` | floors |
| intensityMinutes | `moderateIntensityMinutes + 2 × vigorousIntensityMinutes`; requires both fields | credited minutes |
| restingHeartRate | Summary or daily-heart `restingHeartRate` | bpm |
| heartRate | Latest valid `[timestamp, value]` in `heartRateValues` | bpm |
| stress | Daily `averageStressLevel` | 0–100 |
| bodyBattery | Latest valid pair from body-battery report `bodyBatteryValuesArray` | 0–100 |
| sleepDuration | `dailySleepDTO.sleepTimeSeconds` divided by 60 | minutes |
| deepSleep / lightSleep / remSleep / awakeSleep | Corresponding `dailySleepDTO.*SleepSeconds` divided by 60 | minutes |
| sleepScore | `dailySleepDTO.sleepScores.overall.value` | 0–100 |
| hrv | `hrvSummary.lastNightAvg` | ms, last night |
| spo2 | Daily `averageSpO2` | % |
| respiration | `avgSleepRespirationValue` | breaths/min, during sleep |
| trainingReadiness | Latest timestamped readiness `score` | 0–100 |
| recoveryTime | Same readiness record's `recoveryTime`; `REACHED_ZERO` means 0 | minutes |
| vo2Max | Daily max-metrics `generic.vo2MaxPreciseValue`, then `vo2MaxValue` | ml/kg/min, running |
| trainingLoad | Primary watch's `mostRecentTrainingStatus.latestTrainingStatusData.*.acuteTrainingLoadDTO.dailyTrainingLoadAcute` | acute load |
| weight | Latest daily `dateWeightList[].weight` divided by 1000 | kg |
| hydration | `valueInML` | ml |

When multiple undated readiness records or multiple unmarked training devices
are returned, the connector omits an ambiguous value. Recovery is a snapshot,
not a continually decremented countdown. Unsupported measurements remain absent.

## Partial failures, limits, and refresh

Twelve metric-group requests and one device request run sequentially. A failed
optional group adds `unavailable.GROUP` (`stats`, `heart`, `body_battery`, `sleep`,
`hrv`, `spo2`, `respiration`, `readiness`, `vo2_max`, `training`, `weight`,
`hydration`, or `devices`) while retaining successful groups. `no_data` means the
response had no supported measurements. All-group failures produce an error.
Authentication failure or rate limiting stops further requests immediately.

The upstream retry setting is 0. Login uses only `mobile+cffi`, skipping the
library's additional strategies. The pinned client also rotates TLS profiles
inside that strategy; the connector explicitly uses its unchanged first/default
profile once and disables that internal rotation. Per-client transport guards
stop on the first HTTP 429 or JSON `error.status-code = 429`, before upstream
MFA, token-client, or cookie-authentication fallback handlers can retry. A
verification code is submitted to its original MFA endpoint at most once.
No TLS verification is disabled, no alternative profile is tried, and no
rate-limit bypass is attempted. These controls are exercised against the
installed client's real login/MFA/token flow using mocked HTTP transports.

`rate_limit` means Garmin reported 429 either as its HTTP status or inside an
error JSON document. It does not prove the HTTP status alone was 429, that the
limit is specific to this account/IP, or that the credentials are incorrect.
The final HTTP 403 is kept separate as `access_denied`; an explicit Cloudflare challenge marker produces `security_challenge`. Neither is reported as an invalid password.
The client defaults to 15-second individual API request timeouts. A separate
180-second process network budget bypasses library exception/retry handlers;
the MFA wait has its own 180-second budget. The caller should also terminate a
stuck/cancelled process and retain the last successful snapshot on errors.

Schedule automatic synchronization conservatively (for example every 15
minutes). Do not immediately retry `rate_limit`; let the user retry later.

## Evidence and limits

Authentication and normalization were checked against the installed
`garminconnect==0.3.15` source, especially `client.py`, `typed.py`, and the public
API methods. Additional response fields were checked against upstream tests,
examples, and independently maintained client data models:

- [python-garminconnect source](https://github.com/cyberjunky/python-garminconnect/tree/master/garminconnect)
- [Upstream unit tests](https://github.com/cyberjunky/python-garminconnect/blob/master/tests/test_garmin_unit.py)
- [Upstream demo: hydration, weight, and devices](https://github.com/cyberjunky/python-garminconnect/blob/master/demo.py)
- [go-garmin response models](https://pkg.go.dev/github.com/bastibuck/go-garmin)
- [garmin-mcp training and max-metrics response models](https://pkg.go.dev/github.com/tamcore/garmin-mcp/internal/garmin/api)

The current connector suite has 34 tests using synthetic fixtures and mocks.
Successful live login, MFA delivery, refresh-token acceptance, and an actual
fēnix 8 account's available fields still require successful user sign-in.
The retry-guard fix was tested without credentials or real Garmin requests.
