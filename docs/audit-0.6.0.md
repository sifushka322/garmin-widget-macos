# GarminDesk 0.6.0 audit

Version 0.6.0, build 12. Completed 19 September 2026 on macOS 26.6.2
(25G83), Apple Silicon, Swift 6.3.3 and macOS SDK 26.5, with macOS 14 target.

## Scope

Review covers Garmin payload normalization, Body Battery freshness and estimates,
per-group caching, account isolation, app/window/menu lifecycle, measurement
interpretations, WidgetKit presentation, compatibility with saved data, and
release packaging. Existing uncommitted project work was preserved.

## Findings addressed

- A newly fetched group timestamp could conceal an old Body Battery measurement.
  Freshness now also checks the actual sample time; regression checks cover an
  old sample retrieved now and a genuinely recent sample.
- A minimized sign-in window could stay hidden when reopened through the menu.
  Reopening now unminimizes the window and unhides the application.
- The release verifier now requires `LSUIElement=true` for the menu-bar app.
- The Body Battery normalizer ignored the summary's most-recent scalar. Both
  sources now participate, with a conservative twenty-minute preference rule
  for a differing untimed summary versus a timed report. This policy cannot
  prove which server-side source updated first. Older report responses cannot
  replace newer cached report samples. See [source selection and projection
  rules](body-battery-refresh-audit.md).
- An interrupted account switch could leave a snapshot from account A beside a
  group cache owned by account B. The private snapshot now carries its owner;
  conflicting owners discard both in-memory caches before verification. Legacy
  unowned snapshots rebuild from owned groups. Account ownership never enters
  the widget snapshot. Regression tests simulate a failed snapshot write and
  restore with both conflicting files.
- Interpretation review prevented comparing acute load against chronic-load
  limits and confusing nightly HRV with its weekly status. Unknown numeric
  training statuses are not guessed. Score labels use the same rounding as
  displayed values. See [metric evidence](metric-explanations-audit-2026-09-19.md).
- A final boundary check now rejects a previous-day Body Battery anchor even if
  an endpoint labels the containing response with today's date. Projection tests
  explicitly exercise the midnight transition.

## Validation log

- Legacy connector: 35 Python tests passed using the project's pinned `.venv`.
  The system Python lacks the optional connector dependency; no installation or
  dependency changes were made.
- Browser read boundary: 60 JavaScript checks passed with the bundled Node runtime.
- Draft preparation: 4 Python tests passed.
- Release promotion: 32 Python tests passed.
- Shell syntax, both source plists and whitespace checks passed.
- All native functional checks passed. The final assertion counts are below.
- The real AppKit event-loop test passed 33 menu/window checks using temporary
  storage, memory-only defaults and a fake transport. It does not use WebKit,
  personal data or the installed application. Closing/minimizing/reopening,
  settings, widget URLs, disconnected/busy/connected states, language changes,
  background refresh and accessory activation were exercised.
- The sandbox probe passed allowed snapshot reading, denial of neighboring
  reads, denial of direct/shared-store writes, and cleanup of synthetic fixtures.
- Rendering produced 618 widget, 204 app/popover and 45 calendar PNGs. Reviewed
  representative English/Russian small/medium/large widgets, minimum-width app
  cards, estimate/expired states, the actual Garmin load-ratio category, separate
  training status, and the low-night/balanced-week HRV case. No clipping or
  overlap was found in reviewed frames. This is not native-speaker review of all
  twelve interface languages.
- Final app and extension have matching 0.6.0/build-12 metadata, arm64 binaries,
  five static widget kinds, system-only dependencies, valid nested ad-hoc
  signatures, and the required menu-bar flag. DMG verification and both SHA-256
  checks passed. All nine ZIP payload files match an explicit allowlist of
  executables, plists, signatures, icon, license and notice. No cache/session or
  personal data files are included.

| Native suite | Passed checks |
| --- | ---: |
| Brand icon | 12 |
| Shared models | 234 |
| Widget configuration/migration | 214 |
| Widget metric policy | 34 |
| Training calendar | 39 |
| Training presentation | 18 |
| Localization | 12,737 |
| Sync policy | 206 |
| Garmin payload normalization | 198 |
| Training models | 74 |
| Metric explanations | 91 |
| Body Battery refresh/projection | 33 |
| Projected widget timeline | 13 |
| Web boundary | 49 |
| AppStore lifecycle/cache | 162 |
| AppKit menu/window lifecycle | 33 |

Execution notes: the command sandbox blocked Launch Services for the isolated
GUI test and `iconutil` during initial packaging. Those operations passed when
run outside the command sandbox with the same isolated fixtures/project output.
An initial integration check exposed the legacy Body Battery source-timestamp
fallback, which was corrected. The midnight fix was followed by targeted
Body Battery/timeline/shared-model checks, refreshed visual fixtures and a full
rebuild/repackage. No failed check is presented as a pass.

Local logs: `build/audit/native-0.6.0.log`, `final-checks-0.6.0.log`,
`menu-lifecycle-0.6.0.log`, `sandbox-0.6.0.log`, `build-0.6.0.log`,
`package-0.6.0.log` and `archive-0.6.0.txt`.

## Release files

- `build/GarminDesk-0.6.0-arm64.dmg`
- `build/GarminDesk-0.6.0-arm64.zip`
- `build/GarminDesk-0.6.0-arm64-SHA256.txt`

Final SHA-256:

```
6102ff57efe197d0480ef11ead527285cb1c89fa85bbab1621f4958fc2929579  GarminDesk-0.6.0-arm64.zip
84a73e122c874a023d159c6b9045798bf599206aaed0706916200a4a85d8f2cf  GarminDesk-0.6.0-arm64.dmg
```

## Unverified scope

The user's precise live Body Battery incident was not reproduced; no
authenticated Garmin payload was obtained during this audit. No verified
downloadable Garmin future forecast was found. The `≈` value is a bounded local
calculation from real Garmin points, which may be unavailable for sparse data.
The twenty-minute source-selection preference is a product policy, not proof of
relative server-side freshness. App/native tests and synthetic renders do not
establish exact minute-by-minute desktop refresh or a normal upgrade of existing
system widgets. Intel, macOS 14 runtime, a new OS login, and live sign-in were not
tested. The local release is not notarized or publicly published.

## Platform behavior

AppKit's accessory activation policy removes the Dock icon while allowing
application windows. [Apple AppKit documentation](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory).

WidgetKit receives dated timeline entries, but macOS controls when widgets render
and reload. Exact per-minute desktop refresh is not guaranteed. Preparing future
entries does not require a Garmin network request for each entry.
[Apple WidgetKit documentation](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date).

No public publication, installation over the user's application, login-item
change, or system-widget cache reset is part of this local build.
