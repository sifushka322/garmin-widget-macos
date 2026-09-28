# Widget interpretation audit — 28 September 2026

## Findings

- Summary never rendered a scale. Its small supporting row omitted the status
  altogether, so the same measurement changed meaning with widget size.
- The dedicated Sleep widget showed a duration and “Total time asleep”; the
  available sleep-quality score did not help interpret that prominent value.
- Dedicated measurement widgets rendered progress only for the primary value.
  Supporting values had no visual position on a scale, and legacy compact rows
  omitted both interpretation and record period.
- Training load had a textual assessment, but the range or acute/chronic ratio
  was confined to hover help. Theme colors identified a metric category, not
  whether the received assessment was low, optimal, or high.
- App cards used either a generic progress ring or no scale. Stress and SpO₂
  looked like goals that should be filled, although their numbers do not mean
  “percent complete.”
- Existing fixtures omitted a step goal and default training context. This made
  ordinary visual reviews exercise missing-context fallback more than the live
  data contract. The local renders from 19 September confirmed these findings;
  they are baseline evidence, not validation of the changes below.

## Resolution contract

Use a shared visible assessment beside or below the number in Summary, dedicated
widgets, and app cards. A scale must explain what it measures and retain a short
text label, so color is never the sole carrier of meaning. Distinguish score
position, personal-goal progress, personal optimal range, and a category received
from Garmin. Do not assign arbitrary universal thresholds to raw training load,
HRV, resting pulse, hydration, weight, or VO₂ max.

Sleep duration may display the Garmin sleep score and quality scale only when
both readings belong to the same source day, including a retained pair from the
same completed night. A missing score or a score from another night must not
produce an invented good/bad judgment. An older night's date remains visible.

Load range assessment and Garmin's acute/chronic ratio category are distinct.
When the adapter supplies a ratio/category but no verified acute-load bounds,
display that received category as such. Missing context stays explicit; current
personal context must not be applied to a retained historical load or HRV value.
Steps use the recorded personal goal and cap the drawing when the goal is
exceeded, while keeping the actual total and achieved-goal text visible.

Stage bars show a neutral percentage of that night's total sleep, not a health
grade. Matching sleep records require equal source days and equal end timestamps
when present; untimed retained pairs also require a shared retrieval timestamp.
The rendered scale and VoiceOver announce the same assessment and score.

Readiness is valid only in the 1–100 range. Native and legacy ingestion now reject
zero readiness, and the formatter also rejects old cached invalid values, so an
invalid readiness cannot displace a valid main metric. Zero recovery time remains
valid and means the countdown has completed.

Preserve connection, missing-data, stale-data, and gallery/demo behavior. Reserve
enough vertical space for the notice and period label in small/medium widgets.
Short visible copy is preferable to shrinking long explanatory sentences into
unreadable text; full explanations remain available in help/accessibility.

Large widgets retain the first four supporting selections, leaving room for
readable assessments and dates at a stable size. Medium measurement widgets show
two supporting values, including both recovery and load in Sport. Small Summary
prioritizes its main measurement when dates or a notice need the space. Selection
order is preserved. Dashboard cards have equal fixed heights, with aligned header,
value and scale slots and dates at the bottom.

## Source basis

- [Garmin sleep score categories](https://support.garmin.com/en-IN/?faq=mBRMf4ks7XAQ03qtsbI8J6).
- [Garmin load ratio](https://www8.garmin.com/manuals/webhelp/GUID-AC520B63-3C82-4266-90F6-6E9F22D5F76E/EN-GB/GUID-200689D7-F65C-40F0-BB82-3C51236C676A.html).
- Additional existing sources and distinctions remain documented in
  [the metric explanation audit](metric-explanations-audit-2026-09-19.md).

The ratio gauge positions Garmin's reported category; it does not reinterpret a
numeric acute load or infer categories from unverified chronic bounds.

## Verification coverage

`Tests/RenderWidgets.swift` now includes a daily step goal and the live adapter's
ratio/category-shaped context in its ordinary synthetic sample. Existing exact
range scenarios remain separate. Added EN/RU scenarios exercise every widget
size in Summary and the relevant dedicated widget:

- same-night good sleep, poor sleep, absent sleep score, old score with current
  duration, old duration with current score, and a retained same-night pair;
- high stress, low Body Battery, steps beyond the personal goal;
- low and very high acute/chronic load categories;
- fully retained snapshots in every size/purpose, combining record dates and
  stale progress notices to expose the maximum vertical content height;
- disconnected and partial snapshots at every size, keeping error notices
  readable alongside the new indicators.

These scenarios also exercise Summary's compact supporting row. The dedicated
legacy `compactMetricRow` branch is currently unreachable through the fixed
`WidgetSlot.profile` projection, which always uses comfortable density; it still
needs source review when updating the shared assessment view.

Existing fixtures cover all supported languages, colorful/light/dark widget
appearances, gallery previews, missing primary data, partial data, disconnection,
waiting, retained records, Body Battery projections, explicit Summary selections,
and HRV weekly status independent of an unusual overnight value. Visual review
should inspect these together with adverse-state fixtures, especially Russian
small/medium widgets and the largest Summary grid.

## Initial local audit checks (older source snapshot)

The following results describe the initial audit before merging with the latest
0.6.0 main branch. They are historical evidence only. Final 0.7.0 validation and
installation results are recorded in [the candidate report](releases/validation/0.7.0-candidate.md).


- 995 Swift checks passed across MetricIndicator, MetricExplanation, SharedModel,
  WidgetMetricPolicy, GarminPayloadNormalizer, BodyBatteryProjection and
  WidgetConfiguration suites. Includes companion-record provenance, category
  boundaries, rounded values, historical dates, malformed input, and accessibility.
- 15 relevant offline Python normalization/fetch tests passed. The broader legacy
  Python suite passed 29 of 36; seven require the unavailable `garminconnect`
  dependency. No live Garmin requests or account changes were made.
- Final app renderer produced 204 synthetic PNGs. Narrow 780 px and wide 1100 px
  Russian dashboard layouts were visually checked, including equal row heights,
  mixed cards with/without scales, multi-line supporting text and retained sleep.
- Debug ARM64 app and all five WidgetKit kinds compiled using SDK 26.5.
  Bundle verification passed native dependencies, architecture, versions,
  configuration flags and ad-hoc signatures. Artifacts are `build/GarminDesk.app`
  and `build/GarminDesk-0.6.0-arm64.zip`. The sandboxed icon utility failed initially;
  the normal native build outside the sandbox succeeded. No installed application
  was replaced and no release was published.
- Final widget renderer completed successfully and produced 822 synthetic PNGs
  in `build/audit/context-2026-09-28/widgets-final`. Visual review confirmed readable
  scales/statuses across small, medium, and large Russian widgets, light/dark
  appearances and gallery previews. Fully retained snapshots and disconnection
  notices retain their headers, dates and footers without clipping; historical
  large widgets use four supporting values, and small Summary reserves the space
  for its primary measurement and notice. Sleep mismatch/missing-score fixtures,
  adverse scores, over-goal steps and acute/chronic ratio categories were checked.
