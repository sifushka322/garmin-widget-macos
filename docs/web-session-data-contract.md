# Garmin web-session data contract

Research date: 15 September 2026. This is a read-only endpoint and normalization contract, not a claim that every endpoint has been tested in the user's web session. No account requests, credential use, cookie extraction or restriction-bypass experiments were performed for this document.

## Transport boundary: the host matters

| Surface | Meaning and evidence |
| --- | --- |
| `https://connectapi.garmin.com/{service-path}` | The installed `garminconnect==0.3.15` client's service host; see `client.py:313`, `_run_request:1641`. Its DI/header authentication is not a same-origin browser fetch from `connect.garmin.com`. |
| `https://connect.garmin.com/gc-api/{service-path}` | Current web-facing prefix defined by the same maintainer's `ha-garmin` client. Use as the primary candidate for same-origin web requests, subject to verification in the parent's normal session. [Maintainer constants](https://github.com/cyberjunky/ha-garmin/blob/main/src/ha_garmin/const.py) |
| `https://connect.garmin.com/modern/proxy/{service-path}` | Historical web proxy used in older public implementations. Its existence in old examples is not proof of current routing. [Historical implementation](https://github.com/abrander/garmin-connect/blob/master/SleepSummary.go) |
| `https://connect.garmin.com/atp-api/atp/athlete/calendar` | Separate adaptive-plan web API identified in maintainer sources; not a service path under `gc-api`. Its request parameters and response schema remain unverified here. |

A service named `web-gateway` or `mobile-gateway` is itself part of the service path; do not replace the outer `gc-api` prefix with that name. China routing is a separately selected `connect.garmin.cn/gc-api` origin, not an automatic alternative after an error.

WKWebView should retain its own normal persistent website session and perform read-only fetches from the verified Garmin origin. The website owns authentication, cookie renewal and challenge handling. The host should neither construct a `Cookie` header nor export cookies/tokens into Python. Do not send DI headers to the web origin or transplant `Origin`, `Referer`, user-agent or TLS identities from the Python client. If normal web requests require a CSRF mechanism, follow the actual website-supported request path within that session; do not invent token names or import private browser data.

Garmin's official Training API publishes workouts/plans through its approved program. That does not document these private read endpoints or guarantee access from a personal desktop app. [Official Training API](https://developer.garmin.com/gc-developer-program/training-api/)

## Verified service paths from the pinned Python client

Notation: `D` is a validated `YYYY-MM-DD` source date, `P` is the URL-path-encoded `displayName` from the signed-in user's social profile. All rows use **GET**. The service paths and query parameters below are verified in installed `garminconnect/__init__.py` functions; applying the `gc-api` prefix still requires web-session validation. [Public counterpart](https://github.com/cyberjunky/python-garminconnect/blob/master/garminconnect/__init__.py)

| Normalizer group | Service path | Query | Expected outer shape |
| --- | --- | --- | --- |
| Bootstrap | `/userprofile-service/socialProfile` | — | object with nonempty `displayName` |
| `stats` | `/usersummary-service/usersummary/daily/P` | `calendarDate=D` | object |
| `heart` | `/wellness-service/wellness/dailyHeartRate/P` | `date=D` | object |
| `body_battery` | `/wellness-service/wellness/bodyBattery/reports/daily` | `startDate=D&endDate=D` | array of daily objects |
| `sleep` | `/wellness-service/wellness/dailySleepData/P` | `date=D&nonSleepBufferMinutes=60` | object containing `dailySleepDTO` |
| `hrv` | `/hrv-service/hrv/D` | — | object or null |
| `spo2` | `/wellness-service/wellness/daily/spo2/D` | — | object |
| `respiration` | `/wellness-service/wellness/daily/respiration/D` | — | object |
| `readiness` | `/metrics-service/metrics/trainingreadiness/D` | — | array of snapshots |
| `vo2_max` | `/metrics-service/metrics/maxmet/daily/D/D` | — | array; some upstream consumers also accept an object |
| `training` | `/metrics-service/metrics/trainingstatus/aggregated/D` | — | object |
| `weight` | `/weight-service/weight/dayview/D` | `includeAll=true` | object containing `dateWeightList` |
| `hydration` | `/usersummary-service/usersummary/hydration/daily/D` | — | object |
| Devices | `/device-service/deviceregistration/devices` | — | array of device objects |

Installed source references: `get_user_summary:962`, `get_heart_rates:1150`, `get_daily_weigh_ins:1341`, `get_body_battery:1386`, `get_max_metrics:1484`, `get_hydration_data:1745`, `get_respiration_data:1753`, `get_spo2_data:1761`, `get_sleep_data:1925`, `get_hrv_data:2078`, `get_training_readiness:2099`, `get_training_status:2264`, `get_devices:2306`.

### Known web-version differences to resolve explicitly

The newer maintainer client uses `/gc-api/sleep-service/sleep/dailySleepData?date=D&nonSleepBufferMinutes=60`, without `P`. It also lists `/gc-api/wellness-service/wellness/dailySpo2`, but a matching invocation/query was not established in this audit. These are version-specific route differences, not instructions to probe alternates after 401/403/429. Prefer the route observed on the ordinary website and pin that adapter. [Web client implementation](https://github.com/cyberjunky/ha-garmin/blob/main/src/ha_garmin/client.py)

## The existing 26-metric normalization contract

This section specifies compatibility with `Connector/bridge.py`'s current normalizers. An optional value is omitted, never manufactured as zero. Accept finite numeric JSON values, reject booleans, numeric strings, null, negatives and documented sentinels. Zero is valid for counters, scores and durations; pulse, weight, HRV, SpO₂ and VO₂ require positive values. Score/percentage bounds are 100 where listed.

| Group | Canonical key ← payload field | Conversion / selection |
| --- | --- | --- |
| `stats` | `steps ← totalSteps`; `stepGoal ← dailyStepGoal` | Goal must be positive. |
| `stats` | `distance ← totalDistanceMeters` | metres / 1,000 → km |
| `stats` | `calories ← totalKilocalories`; `activeCalories ← activeKilocalories`; `floors ← floorsAscended`; `restingHeartRate ← restingHeartRate` | kcal, floors, bpm respectively |
| `stats` | `stress ← averageStressLevel` | Daily average, range 0…100; not latest stress. |
| `stats` | `intensityMinutes ← moderateIntensityMinutes + 2 × vigorousIntensityMinutes` | Require both fields; absent vigorous is not zero. |
| `heart` | `heartRate ← heartRateValues[][1]`; `restingHeartRate ← restingHeartRate` | Latest valid array timestamp `[0]`, not last array position. |
| `body_battery` | `bodyBattery ← bodyBatteryValuesArray[][1]` | Latest valid timestamp across daily records; 0…100. |
| `sleep` | `sleepDuration ← dailySleepDTO.sleepTimeSeconds`; `deepSleep ← deepSleepSeconds`; `remSleep ← remSleepSeconds`; `lightSleep ← lightSleepSeconds`; `awakeSleep ← awakeSleepSeconds` | Seconds / 60 → minutes. All stage fields belong to `dailySleepDTO`. |
| `sleep` | `sleepScore ← dailySleepDTO.sleepScores.overall.value` | 0…100; measurement time may come from `sleepEndTimestampGMT`. |
| `hrv` | `hrv ← hrvSummary.lastNightAvg` | ms, positive; overnight average rather than weekly average. |
| `spo2` | `spo2 ← averageSpO2` | Percent, 0 < value ≤ 100. |
| `respiration` | `respiration ← avgSleepRespirationValue` | Sleeping breaths/min; positive. |
| `readiness` | `trainingReadiness ← score`; `recoveryTime ← recoveryTime` | Latest UTC snapshot, or sole undated snapshot. Recovery is minutes; explicit `recoveryTimeChangePhrase == REACHED_ZERO` means zero. |
| `vo2_max` | `vo2Max ← generic.vo2MaxPreciseValue`, then `generic.vo2MaxValue` | Latest `generic.calendarDate`, positive. Preserve Garmin's intrinsic VO₂ units. |
| `training` | `trainingLoad ← mostRecentTrainingStatus.latestTrainingStatusData[device].acuteTrainingLoadDTO.dailyTrainingLoadAcute` | Prefer the unique `primaryTrainingDevice == true`; otherwise require exactly one device entry. Do not sum devices. |
| `weight` | `weight ← dateWeightList[].weight` | Latest valid `timestampGMT`, or sole undated record; grams / 1,000 → kg. |
| `hydration` | `hydration ← valueInML` | ml |

Use epoch milliseconds only for documented arrays/time fields. Accept explicit-offset ISO timestamps and known GMT fields; reject ambiguous local timestamps as UTC. `fetchedAt` describes acquisition, not measurement. Daily summaries without trustworthy instants retain `sourceDate` and omit `measuredAt`. Do not silently relabel yesterday's sleep/readiness/weight as today's measurement.

For a native implementation the group names are exactly `stats`, `heart`, `body_battery`, `sleep`, `hrv`, `spo2`, `respiration`, `readiness`, `vo2_max`, `training`, `weight`, `hydration`. A pure normalizer should take the untransformed response object, avoiding third-party convenience conversions applied twice.

## Past activities, workout library and calendar are distinct

| Purpose | GET service path | Query / shape |
| --- | --- | --- |
| Most recent completed activities | `/activitylist-service/activities/search/activities` | `start=0&limit=20`; array. The existing client also recognizes an `activityList` envelope in its last-activity helper. |
| Bounded activity history | Same list path | Optional `startDate`, `endDate`, `activityType`, `activitySubType`, `sortOrder`. Offset pagination; deduplicate stable IDs. |
| One completed activity | `/activity-service/activity/{activityId}` | object; summary may be nested in `summaryDTO` |
| Activity charts, only on demand | `/activity-service/activity/{activityId}/details` | `maxChartSize` and `maxPolylineSize`; positional samples use `metricDescriptors[].metricsIndex/key`, never a fixed column order. |
| Saved workout templates | `/workout-service/workouts` | `start=0&limit=20`; library entries, not completed or scheduled sessions |
| One workout definition | `/workout-service/workout/{workoutId}` | object containing workout definition/steps |
| Month calendar | `/calendar-service/year/{year}/month/{monthIndex}` | **Month index 0…11**; object containing `calendarItems` |
| One scheduled occurrence | `/workout-service/schedule/{scheduleId}` | object; schedule ID is distinct from reusable workout ID |
| Active-plan goal event | `/calendar-service/events` | `trainingPlanId={atpPlanId}`; evidence from the newer maintainer client, not the pinned method set |

Pinned references: `get_activities:2382`, `get_activities_by_date:2677`, `get_activity:3110`, `get_activity_details:3118`, `get_workouts:3279`, `get_workout_by_id:3288`, `get_scheduled_workouts:3587`, `get_scheduled_workout_by_id:3606`, `get_next_scheduled_workout:3618`.

Calendar rows mix item types. Filter `itemType == "workout"` for training sessions; never present weight/nap/other entries as workouts. Read the current and next month at a month boundary. `date` can be date-only: preserve an all-day occurrence instead of inventing a UTC midnight instant.

Known future-calendar limit: the pinned client's documentation says calendar-service can omit later adaptive/Coach sessions already visible in Garmin's app. Its fuller adaptive schedule belongs to a separate session-authenticated API. Therefore a successfully fetched empty month means “no published calendar entries in this response,” not “no training plan” or “rest day.” Mark calendar coverage explicitly until the ordinary web route and its schema are validated.

The newer maintainer source identifies `/atp-api/atp/athlete/calendar` as that separate gateway and `/calendar-service/events` as goal-event data. It does not supply a currently supported complete adaptive-calendar implementation. Do not guess required query parameters or claim full Coach coverage from `/trainingplan-service/trainingplan/fbt-adaptive/{id}`. [Maintainer implementation and limitations](https://github.com/cyberjunky/ha-garmin/blob/main/src/ha_garmin/client.py)

## Proposed native schemas

These are GarminDesk-owned schemas, not quoted Garmin payload contracts. Keep IDs as strings and optional values absent. Never infer a completed activity from a calendar date in the past.

```swift
struct PastActivitySummary: Codable {
    var id: String                 // activityId; stable across refreshes
    var title: String              // activityName, plain text
    var sportKey: String           // activityType.typeKey; unknown is retained
    var startedAt: Date?           // startTimeGMT or explicit-offset timestamp
    var localStart: String?        // startTimeLocal when no reliable zone exists
    var durationMinutes: Double?   // duration / 60, distinct from moving duration
    var movingMinutes: Double?     // movingDuration / 60
    var distanceKM: Double?        // distance / 1,000
    var calories: Double?
    var averageHeartRate: Double?  // averageHR
    var maximumHeartRate: Double?  // maxHR
}

struct PlannedWorkoutSummary: Codable {
    var occurrenceID: String       // calendar id / schedule id, source-namespaced
    var workoutID: String?         // reusable workoutId; not the occurrence key
    var localDate: String          // validated YYYY-MM-DD
    var startsAt: Date?            // only when a real time and zone are supplied
    var title: String
    var sportKey: String
    var durationMinutes: Double?   // only from a field with verified units
    var distanceKM: Double?        // likewise; unverified calendar units omitted
    var source: String             // calendar or adaptive_calendar
    var planID: String?
}

struct TrainingTimelineSnapshot: Codable {
    var fetchedAt: Date
    var past: [PastActivitySummary]
    var upcoming: [PlannedWorkoutSummary]
    var pastCoverageStart: String?
    var futureCoverageEnd: String?
    var futureCoverage: String     // published_calendar, adaptive_verified, unavailable
    var warnings: [String]
}
```

Calendar payload candidates seen in the maintainer source are `id`, `date`, `title`, `sportTypeKey`, `workoutId`, `atpPlanId`, `trainingPlanId`, `duration`, `distance`, `protectedWorkoutSchedule`, `phasedTrainingPlan`. Their presence does not prove units or completion state. Keep estimates separate from actual activity results. A library's `estimatedDurationInSecs`, when present and validated, can populate an estimate; do not conflate it with a calendar `duration` of unverified scale.

## Website page routes

Navigation routes and JSON endpoints are different contracts. Common `/modern/` routes used by public clients are `/modern/activities`, `/modern/activity/{activityId}`, `/modern/workouts`, `/modern/workout/{workoutId}`, `/modern/calendar`, `/modern/daily-summary/{D}` and `/modern/sleep/{D}`. Only adopt a deep link after the parent verifies that the normal website currently uses it; routing may migrate to `/app/`. Until then, a safe top-level Garmin Connect link is preferable to a guessed details URL. No deep link should contain credentials, session data or a fabricated schedule ID.

## Error handling, expiry and caching

| Response | Required behavior |
| --- | --- |
| 200 JSON with expected shape | Validate, normalize and replace only the corresponding successful group. A recognized empty result is distinct from schema mismatch. |
| 200 HTML / redirected login page | Treat as an expired/unauthenticated web session, not empty data or JSON corruption. Do not save raw HTML. |
| 401 | Pause data requests and surface normal website sign-in. Do not fall back to credential SSO or another host. |
| 403 | Access/challenge state, not necessarily a wrong password or unsupported device. Pause requests and let the normal visible website explain/resolve it. |
| 429 | Stop the batch, preserve cached measurements, honor bounded `Retry-After` and back off. Do not switch endpoints, profiles, accounts or origins. |
| 404 / 204 | Endpoint-specific absence only after authentication and routing are known valid. A 404 on a new route is not proof that the user lacks that metric. |
| 5xx / timeout / offline | Keep prior values with their real freshness; show update failure and retry only at the normal later schedule. |
| Unexpected JSON shape | Stable `schema_mismatch.<group>` diagnostic; retain prior data and omit unverified fields. Never turn a body into a logged error message. |

Use one synchronization owner, a bounded batch and no overlapping manual/timer runs. Initially fetch only selected metric groups plus recent activities/current-next calendar months. Reuse one stats response for its nine supported values. Cache device names and immutable activity details; refresh calendar and current-day data on their own cadence. Page back only when the user requests more history. A server session can expire even while the application is running; quiet background failure must not launch repeated sign-in windows.

Do not persist raw profile objects, response URLs containing profile IDs, GPS tracks, cookies or full activity payloads into widget shared storage. Persist only normalized values and bounded training summaries the product needs. Synthetic fixtures should cover sparse/zero/sentinel values, DST/date-only handling, malformed envelopes, month/year rollover, reused workout IDs, adaptive-calendar incompleteness and partial-batch failure.
