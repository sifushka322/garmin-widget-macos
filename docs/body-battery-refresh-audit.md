# Body Battery refresh and approximation audit

19 September 2026.

The previous native normalizer read only `bodyBatteryValuesArray` from the daily report. It ignored the summary's `bodyBatteryMostRecentValue`. The report can lag or contain sparse samples even while other groups refresh. The original freshness display also used the request time, allowing repeated reads of an old Body Battery sample to appear fresh. Both defects have regression coverage. The user's exact on-device incident was not reproduced: no authenticated Garmin payload was obtained during this audit.

## Current source selection

Both the daily report and daily summary are requested when Body Battery is selected. A timed report sample wins when the two agree or the sample is recent. If the summary's observation is more than 20 minutes after the report sample and its scalar differs, the scalar is used without a fabricated measurement timestamp. This threshold is a conservative product fallback, not proof that the untimed scalar is a newer measurement. An absent report can also use the summary. Previous-day groups cannot supply current-day readings. A newly received older report cannot replace a newer cached sample. Request time and measurement time remain distinct.

## Approximation provenance and limits

No verified numeric Garmin forecast endpoint or future-point schema was found. Garmin documents a trend arrow and model estimates after the watch was removed, but these are not evidence for a downloadable future forecast. The app's optional approximation is a **local straight-line estimate from recorded Garmin points**, visibly marked `≈`; it is never called a Garmin forecast.

The estimate uses the first and last points within the latest hour, requires at least a ten-minute observed span, rejects gaps over twenty minutes, conflicting duplicate timestamps and slopes over 60 points per hour, and clips to 0–100. These are conservative product rules, not physiological guarantees. It is recomputed once per minute without a network request. The horizon ends sixty minutes after the latest actual sample, irrespective of subsequent polls. An unrelated summary scalar, a newer measurement, a day change, demo data or retained-only data disables the old approximation. Actual value and measurement timestamp remain in the snapshot unchanged. A sparse report may legitimately supply no approximation.

## Evidence

- Garmin's own [Body Battery explanation](https://www.garmin.com/en-GB/garmin-technology/health-science/body-battery/) explains the underlying HR, HRV, movement, activity and rest signals.
- Garmin [Body Battery support](https://support.garmin.com/en-SG/?faq=2qczgfbN00AIMJbX33dRq9) describes trending arrows and synchronization.
- The upstream [python-garminconnect typed response](https://github.com/cyberjunky/python-garminconnect/blob/master/garminconnect/typed.py) documents `bodyBatteryValuesArray` as timestamp/value pairs. Extra unknown row layouts are not guessed.
- The maintainer's [Garmin API response model](https://pkg.go.dev/github.com/tamcore/garmin-mcp/internal/garmin/api#DailyStats) exposes `bodyBatteryMostRecentValue` separately from charged/drained/high/low totals.

Regression tests cover minute stepping, expiry, invalid/future samples, bounds, day rollover, newer measurements, stale report regression, scalar fallback, source conflicts and old-cache decoding. No health payload, account identifier or credential is included in test fixtures or this audit.
