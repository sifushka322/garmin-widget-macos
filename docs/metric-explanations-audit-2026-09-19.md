# Metric interpretation audit — 19 September 2026

The dashboard previously exposed numbers and their reporting dates, with little
help interpreting them. The shared `MetricExplanation` presentation now provides
a short status, personal context where available, and an explanation for every
catalog metric. Dashboard cards include an information button with the longer
explanation and a relevant Garmin source. Widget layouts can use the same model.
The explanation copy supports Russian and English; other interface languages
currently use English for these additions.

## Interpretation rules

| Metric | Displayed interpretation | Constraint |
| --- | --- | --- |
| Acute training load | Below / within / above the personal Garmin range; exact lower and upper values | No universal threshold. A recognized Garmin training status is a separate line. Low load never automatically becomes “detraining.” |
| HRV | Last night's value, explicitly distinguished from Garmin's weekly HRV status | Weekly average and personal baseline are shown when provided. The nightly value never determines the weekly status. |
| Training readiness | Poor 1–24, low 25–49, moderate 50–74, high 75–94, prime 95–100 | Uses Garmin's published scale. Zero has no readiness assessment. |
| Sleep score | Poor <60, fair 60–79, good 80–89, excellent 90–100 | Sleep length alone does not determine sleep quality. |
| Stress | Resting 0–25, low 26–50, medium 51–75, high 76–100 | Explicitly described as the day's average from `averageStressLevel`, not current emotions or an instantaneous measurement. |
| Body Battery | Very low / low / moderate / high energy reserve, at 25/50/75 boundaries | Uses the current Garmin manual terminology; older Garmin manuals use different adjectives for the same bands. The interpretation uses the rounded displayed value, including a supported projection. |
| Recovery time | Time until another hard session, or countdown complete | Not a prescription for complete inactivity. Represents the last Garmin reading. |
| VO₂ max | Aerobic fitness estimate; personal trend | No fitness category without Garmin's age/sex context. |
| Resting pulse, respiration, SpO₂ | Period and meaning of the measurement | No diagnosis from an isolated number; no invented normal threshold. |
| Sleep duration and stages | Recorded night and relation to overall sleep | Stage duration has no universal good/bad cutoff in this UI. |
| Steps | Progress relative to the user's daily goal, if available | Historical retained steps never compare against today's goal. |
| Intensity minutes | Moderate + twice vigorous minutes, for the day | Not elapsed workout duration and not the weekly total. |
| Calories | Total includes resting + active expenditure | Active calories are already included; these are not intake or a calorie deficit. |
| Weight, hydration, distance, floors | What was recorded and for which period | No inferred health or training assessment from an absolute total. |

Personal context is ignored for a retained historical reading so the UI cannot
compare yesterday's load against a current range. Invalid/inverted/nonfinite
ranges and unrecognized raw status tokens are ignored. Missing context is stated
plainly, rather than assigning a reassuring or alarming category. Numeric score
bands round like the displayed whole-number score.

The live adapter preserves Garmin's `acwrStatus` and
`dailyAcuteChronicWorkloadRatio` as an explicitly labeled acute/chronic ratio.
The payload's `minTrainingLoadChronic` and `maxTrainingLoadChronic` describe
chronic load: they are deliberately **not** used to classify the displayed acute
load. Exact acute-range presentation is supported by the shared model, but the
current adapter leaves those optional fields absent because that mapping has
not been verified. In the absence of Garmin's recognized ratio category, the
card states that a personal range is unavailable, while still showing a
recognized training status if provided.

Garmin training status terms covered are detraining, recovery, maintaining,
productive, peaking, overreaching, unproductive, strained, no status and paused.
They are interpreted only from recognized semantic Garmin tokens, not guessed
from numeric status codes or from load alone.

Raw adapter shape checks were cross-checked against primary client source:
[python-garminconnect HRV models](https://github.com/cyberjunky/python-garminconnect/blob/master/garminconnect/typed.py),
[home-assistant-garmin_connect training fixtures](https://github.com/cyberjunky/home-assistant-garmin_connect/blob/main/tests/conftest.py),
and [Garmin MCP typed training fields](https://pkg.go.dev/github.com/tamcore/garmin-mcp/internal/garmin/api).
Known numbered semantic feedback phrases such as `PRODUCTIVE_3` preserve their
recognized status; arbitrary suffixes and numeric status codes remain unknown.

## Official sources consulted

- Acute load is a weighted recent exercise-load measure, and differs from the
  simple seven-day sum used on older devices:
  [Garmin training load](https://www.garmin.com/en-GB/garmin-technology/cycling-science/physiological-measurements/training-load/).
- The optimal range depends on training history and fitness, rather than a
  universal raw load number:
  [Garmin optimal range support](https://support.garmin.com/da-DK/?faq=UpBmHc6pFp3EI5BZa1Ru48).
- Training status is a longer-term interpretation of fitness, load and HRV:
  [Garmin training status manual](https://www8.garmin.com/manuals/webhelp/GUID-2CF5620C-E585-4E0A-9CC3-9565533EEE4D/EN-US/GUID-6F81BF5B-B49A-4506-95E2-0F4A04D8B319.html),
  [Garmin training status explanation](https://www.garmin.com/en-GB/blog/garmin-training-status-and-how-to-use-it/).
- HRV status compares a seven-day average with a personal baseline, formed using
  about three weeks of sleep data:
  [Garmin HRV status manual](https://www8.garmin.com/manuals/webhelp/GUID-25E3235D-44D2-4384-A591-DD1D71BEBCB1/EN-US/GUID-9282196F-D969-404D-B678-F48A13D8D0CB.html).
- Readiness categories:
  [Garmin training readiness](https://www.garmin.com/en-MY/garmin-technology/running-science-entry-level/after-running/training-readiness/).
- Sleep score categories:
  [Garmin sleep tracking support](https://support.garmin.com/en-IN/?faq=mBRMf4ks7XAQ03qtsbI8J6).
- Stress categories:
  [Garmin stress manual](https://www8.garmin.com/manuals/webhelp/legacy/EN-US/GUID-9282196F-D969-404D-B678-F48A13D8D0CB.html).
- Body Battery interpretation:
  [Garmin Venu 4 manual](https://www8.garmin.com/manuals/webhelp/GUID-2CF5620C-E585-4E0A-9CC3-9565533EEE4D/EN-US/GUID-87E1392B-2C55-40B7-A1FF-3AB9252DA0A0.html).
- Recovery time concerns readiness for the next hard workout:
  [Garmin recovery time manual](https://www8.garmin.com/manuals/webhelp/GUID-5D183A14-BB43-4A9B-B441-5F824214CE40/EN-US/GUID-DAC27D10-886A-4EA8-8339-674479E9574A.html).
- VO₂ max classifications depend on age and sex:
  [Garmin VO₂ max standard ratings](https://www8.garmin.com/manuals/webhelp/GUID-AC520B63-3C82-4266-90F6-6E9F22D5F76E/EN-US/GUID-1FBCCD9E-19E1-4E4C-BD60-1793B5B97EB3.html).
- Weighted intensity minutes and calorie terminology:
  [Garmin intensity minutes](https://www.garmin.com/en-MY/garmin-technology/health-science/intensity-minutes/),
  [Garmin calories burned](https://www.garmin.com/en-GB/garmin-technology/health-science/calories-burned/).

## Verification

`Tests/MetricExplanationTests.swift` covers all catalog metrics; every readiness,
sleep and stress category boundary; score rounding; malformed ranges; missing
personal context; a detraining status alongside an optimal load; independence of
nightly HRV and weekly status; retained-history isolation; unsupported metrics;
nonfinite values; Russian copy; English fallback; and additive context decoding.
The shared test runner and dashboard/widget rendering checks provide integration
validation. See the release audit for executed test and render results.
