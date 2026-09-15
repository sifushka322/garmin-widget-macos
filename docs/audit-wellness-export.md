# Official daily wellness export audit

Audit date: 15 September 2026. This document records structural facts and field coverage only. It contains no account identifiers, device identifiers, original FIT filenames, measurement values or measurement timestamps.

## Source and scope

The parent downloaded the daily wellness archive through an existing authenticated Garmin Connect browser session. The original ZIP remains in the user's Downloads directory and is **not included in the project, app bundle or release archive**. The audit read the ZIP in memory; it did not extract personal files into the repository, upload data, authenticate to Garmin, or implement a production importer.

No FIT parser was present in the development `.venv`. With explicit task authorization, the official `garmin-fit-sdk==21.214.0` was installed into `/private/tmp/garmindesk-fit-audit-runtime` using `pip --target`. The `.venv`, application dependencies and requirements files were not changed. The installed package identifies Garmin International, Inc. as its author and the [Garmin FIT Python SDK repository](https://github.com/garmin/fit-python-sdk) as its homepage. The official developer documentation is [Garmin FIT SDK](https://developer.garmin.com/fit).

The parser used `Decoder.check_integrity()` and `Decoder.read()` with CRC checks, standard type conversion, scale/offset application and component/subfield expansion enabled. Dependency output was suppressed while decoding; only counts, types and field names were inspected in tool output.

## Integrity and contents

- ZIP size: **31,774 bytes**.
- **11 FIT files**, all unencrypted, each with a valid `.FIT` signature and consistent declared file lengths.
- **11/11 passed SDK integrity/CRC validation**.
- **Zero decoder errors**.
- **6,596 decoded messages**, spanning 20 named message types and 32 message types that the public SDK identifies only by numeric IDs.
- FIT protocol versions 1.0 and 2.0 are present; raw profile-version integers recorded in file headers are `2049` and `21213`. Header profile versions are distinct from the decoder package version; newer profiles use a different numeric encoding, so this audit preserves the raw integers.

The category labels below describe filename categories and decoded message contents. Original filenames, which can contain device identifiers, are deliberately omitted.

| Category | Files | FIT `file_id.type` | Recognized contents |
| --- | ---: | --- | --- |
| Wellness | 5 | `monitoring_b` | Monitoring samples, resting-heart-rate summaries, stress, respiration, some SpO₂ samples |
| Metrics | 2 | Numeric type `44` | Metadata plus numeric message/field IDs with no public semantic names |
| Overnight skin temperature | 1 | Numeric type `73` | `skin_temp_overnight_mesgs` and additional unnamed samples |
| HRV | 1 | Numeric type `68` | `hrv_value_mesgs`, `hrv_status_summary_mesgs` |
| Sleep | 1 | Numeric type `49` | `sleep_assessment_mesgs`, `sleep_level_mesgs`, event boundaries and unnamed messages |
| Sleep disruption | 1 | Numeric type `79` | Overnight severity and severity-period messages |

A numeric file type does not prevent decoding its public messages. Conversely, an error-free decode does not establish the meaning of unnamed messages.

## Recognized measurement message counts

Counts describe archive records, not measurement values or unique time samples. Duplicates, overlapping files and invalid/sentinel samples have not been removed.

| Message type | Count |
| --- | ---: |
| `monitoring_mesgs` | 1,172 |
| `monitoring_hr_data_mesgs` | 7 |
| `stress_level_mesgs` | 1,108 |
| `respiration_rate_mesgs` | 1,108 |
| `spo2_data_mesgs` | 535 |
| `hrv_value_mesgs` | 127 |
| `hrv_status_summary_mesgs` | 1 |
| `sleep_assessment_mesgs` | 1 |
| `sleep_level_mesgs` | 30 |
| `skin_temp_overnight_mesgs` | 1 |
| `sleep_disruption_overnight_severity_mesgs` | 1 |
| `sleep_disruption_severity_period_mesgs` | 14 |

## Coverage for GarminDesk

All fields listed as present below occur with non-null decoded values. Presence establishes potential coverage; it does not by itself establish the same daily aggregation as Garmin Connect.

| GarminDesk metric | Public SDK field present | Import considerations |
| --- | --- | --- |
| `heartRate` | `monitoring.heart_rate` | bpm. A latest valid timestamped sample is possible; handle compressed timestamps and device boundaries. |
| `restingHeartRate` | `monitoring_hr_data.resting_heart_rate`, `current_day_resting_heart_rate` | bpm. Choose the matching source day and documented summary meaning rather than averaging summaries. |
| `hrv` | `hrv_status_summary.last_night_average` | ms. This corresponds to the intended overnight HRV metric; `weekly_average` is a separate available field. |
| `sleepScore` | `sleep_assessment.overall_sleep_score` | Direct score field; confirm which sleep interval/day owns the assessment. |
| `steps` | Expanded `monitoring.steps` subfield | The SDK derives the named subfield from `cycles` for walking/running. Do not treat cycling/swimming cycles as steps or double-apply scaling. Daily counter semantics need validation. |
| `distance` | `monitoring.distance` | SDK output is metres; convert to kilometres once. Validate cumulative counters, resets and duplicate/overlapping files before producing a daily total. |
| `activeCalories` | `monitoring.active_calories` | kcal. Validate counter/interval semantics; summing every record can overcount. |
| `stress` | `stress_level.stress_level_value` with `stress_level_time` | Time series is available. Filter invalid/rest states and define aggregation; an arbitrary latest sample is not the app's daily-average stress value. |
| `spo2` | `spo2_data.reading_spo2` with `timestamp`, `mode`, `reading_confidence` | Percent. Available samples are not automatically Garmin's daily `averageSpO2`; handle sample mode, validity and averaging explicitly. |
| `respiration` | `respiration_rate.respiration_rate` with `timestamp` | breaths/min. The app currently labels this as sleeping respiration; use a validated sleep interval and appropriate aggregation rather than the latest all-day sample. |
| `sleepDuration`, `deepSleep`, `remSleep`, `lightSleep`, `awakeSleep` | `sleep_level.sleep_level` and `timestamp` | Potentially reconstructable from bounded stage intervals. The SDK defines awake/light/deep/REM/unmeasurable stages. The audit did not calculate durations or establish complete start/end coverage. Unknown spans must remain unknown. |

### Not confirmed from public named fields

The current export does not expose a verified mapping for `stepGoal`, total `calories`, `floors`, `intensityMinutes`, `bodyBattery`, `trainingReadiness`, `recoveryTime`, `vo2Max`, `trainingLoad`, `weight` or `hydration` through the public fields inspected.

- `ascent` exists in metres, but it does not establish Garmin's floors count.
- `active_time`, `duration_min` and intensity-related fields exist, but the explicit public `moderate_activity_minutes` and `vigorous_activity_minutes` fields are absent. Do not equate elapsed active time with Garmin's weighted intensity minutes.
- The metrics FIT files and several wellness messages contain numeric IDs and fields. They may hold additional measures, but this audit does not assign guessed meanings or scales to them.
- Overnight skin temperature and sleep-disruption records are additional available categories outside the current 26 canonical widget metrics.

## Requirements before a production importer

1. Keep the original ZIP as user-selected input; reject unsafe sizes and malformed ZIP/FIT data before processing. Extracting archive paths is unnecessary.
2. Use the SDK's units and timestamp expansion exactly once. Respect local-day boundaries from validated timestamps/correlation metadata; the ZIP's filename and download time are not individual measurement timestamps.
3. Resolve overlapping wellness files and counters before presenting daily totals. Preserve internal device boundaries without exposing identifiers in logs or widget snapshots.
4. Check sleep start/end coverage before deriving stage durations or sleeping respiration. Do not invent a final interval or fill missing periods with zero.
5. Preserve explicit provenance and freshness: a manually imported daily export is a historical local snapshot, not live watch synchronization.
6. Compare a future import with the corresponding visible Garmin Connect summaries, allowing for documented differences in time windows and aggregation. The current structural audit does not claim equality with those summaries.

## Result

This is a valid, nonempty official wellness export with substantial public FIT coverage. It establishes a concrete path for a local importer of selected measurements. It does not establish full coverage of all widget metrics, an implemented importer, or a working unattended Garmin API connection.
