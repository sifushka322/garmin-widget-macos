# Full-stack and frontend audit — 16 September 2026

Baseline: `f6d68a3`, GarminDesk 0.3.0. Review and fixes: [draft PR #1](https://github.com/sifushka322/garmin-widget-macos/pull/1).

## Execution boundary

The owner's Mac is used only to read/edit source, inspect the Git diff and review CI-generated images. No app launch, installation, native test binary, compiler, WebKit session, Keychain operation, UI automation or login-item change is used. Native tests, sandbox probes, rendering and packaging run on ephemeral GitHub Actions machines. Fixtures contain synthetic data only. The normal application and main branch are not updated by this audit.

## Findings and fixes

| Priority | Reproduction / impact | Change and regression coverage |
| --- | --- | --- |
| P1 | The cache has no persisted account owner. After a restart, a profile response for another account can be combined with retained measurements when some endpoints fail. | Persist account ownership only in the private group cache. Clear readings and cadence when the verified owner differs or cannot be established. Host tests cover same, different and unknown owners with a failed sleep endpoint. |
| P1 | `refreshMinutes` is decoded without bounds; multiplication by 60 or 3 can trap on a damaged extreme integer in the app or widget. | Bound decoded preferences and compute time intervals after bounded conversion to `Double`. Tests cover `Int.min` and `Int.max`, including direct in-memory changes. |
| P2 | Stored metric/profile IDs bypass editor validation. Duplicate IDs reach SwiftUI `ForEach`; unknown or absent primary metrics produce inconsistent labels and selections. | Normalize decoded metric lists and primary selection; remove duplicate profile identities and recover an empty profile collection. Reuse the same sanitizer in the editor. |
| P2 | A successful endpoint advances the overall retrieval timestamp while another reading remains old. The widget previously considered only the primary metric. | Per-group metric freshness in the app, visible stale markers, local-day rollover handling, and the oldest retrieval among all visible widget metrics. Tests distinguish fresh steps from old sleep. |
| P2 | Mixed-mode previews show metric cards, but actual small/medium widgets show training. Training-only profiles have no preview. | Move the production widget view into Shared and render it in the editor for all content modes and sizes. Preserve readable child accessibility elements. |
| P2 | A connected installation with a missing/corrupt snapshot initializes with demo health readings. | All installations initialize without invented readings. First launch and widget gallery offer connection/setup; disconnect returns to an empty state. No demo action remains in the app. Host regressions cover onboarding and cleanup. |
| P2 | The legacy Python normalizer can throw on arbitrarily large integers or produce infinity after unit conversion. Strict JSON serialization then fails. | Reject unrepresentable numbers and non-finite converted results. Dedicated Python regression checks both cases. |
| P2 | Existing CI executes only two native suites and no JavaScript/Python contracts or visual fixtures. | Run all seven native suites, JavaScript stream checks, Python tests, synthetic rendering, sandbox isolation, signature/dependency checks and packaging on hosted runners. |
| P3 | A stored supported custom interval is absent from the refresh picker's tags. | Include the current interval and format it with localized minute units. |

## Frontend review

- Reviewed window/sidebar navigation, keyboard shortcuts, profile editing and selection, destructive confirmations, shared colors, number formatting, training layouts, loading/errors, empty/partial/disconnected states and widget links.
- Production widget content is now the single implementation for both the editor and extension. Small/medium mixed mode follows the actual training layout; large mixed mode includes the primary metric.
- Visual fixtures cover four app sections × RU/EN × light/dark × 780×620 and 1100×800 windows, plus six dashboard data states in both languages/themes; widget families, both densities, long labels/units, training and missing/stale/disconnected/retained readings.
- PNG generation is a smoke check and review artifact, not proof that text never clips or that VoiceOver/keyboard navigation works. Record visual inspection separately from rendering success.

### Visual hierarchy refinement

The initial functional layout still repeated refresh errors in the sidebar, used small low-emphasis status text and exposed setup actions before connection. The dashboard now has one readable status surface with the relevant action guidance, a single primary connection action on first launch, a quiet account indicator in the sidebar, stronger measurement headings, and a secondary widget-setup link. A lone profile is a section heading rather than a one-item selector. Connection diagnostics remain in the account pane. Both locales receive shorter, action-oriented waiting copy. These changes are evaluated through remote native renders; passing unit tests alone does not establish design quality.

## User-facing data availability

The follow-up requirement supersedes the older empty-day presentation: absence from today's response must not erase a useful last reading. Current `metrics` remain strictly day-scoped; `retainedMetrics` stores prior real readings with their original day, retrieval time and last-change time. The formatter may display those retained values, while cards and widget footers identify them as last available data. Real zero values replace saved readings normally. Disconnect/account changes clear both collections. No demo value can enter this fallback.

Repeated successful checks preserve each unchanged reading's `metricChangedAt`. A successful HTTP response is presented as a check, not evidence of a newly uploaded watch measurement. The app distinguishes initial connection, waiting for first readings, retained values, unchanged values, active checking and network failure. Guidance to sync the watch on the phone is an action the user can try; the app does not claim to know whether Bluetooth, distance or the phone caused a delay.

The visual audit also found transparency in the widget gradient and off-screen app captures. The shared widget background now has an opaque system-color base with a subtle tint overlay, and the root window has an explicit system background. CI lets native controls settle before capturing.

## Reviewed boundaries

Native network requests are generated GET routes. Swift checks the origin/path; WebKit uses an isolated client script, same-origin credentials, bounded streamed responses and abort handles. Native diagnostics omit cookies, CSRF values and response text. The sync policy separates authentication failures, transient backoff, server rate limits, cancellation, date changes and endpoint cadence. Widget data uses atomic replacement, owner-only permissions and a narrow read-only sandbox directory; the extension has no Garmin transport.

These observations describe reviewed code, not penetration testing or proof of an indefinitely valid third-party session. The optional Python bridge is not included in the default native app. No dependency or authentication implementation was replaced by this audit.

## Validation ledger

- Source diff whitespace check: passed.
- The [PR validation summary](https://github.com/sifushka322/garmin-widget-macos/pull/1) records the exact tested revision, hosted Actions run, suite counts, packaging results and visual inspection. It is the canonical final execution ledger, so later documentation does not require rebuilding unchanged application code.
- No current-audit runtime result is inferred from historical build 7/9 validation.

## Remaining runtime coverage

1. Real Garmin authentication, session renewal and device/account-specific response shapes need consented live integration testing. Offline mocks cannot establish external service compatibility.
2. WidgetKit gallery registration, desktop placement, refresh throttling, reboot and Notification Center need actual macOS runtime checks. PNGs and signed bundles cannot establish those behaviors.
3. Hosted macOS 26 runs do not validate the minimum macOS 14 deployment target, VoiceOver interaction, Increase Contrast or every system display setting.
4. An ad-hoc application remains unnotarized. This audit does not change the selected distribution model or publish a release.

GitHub runner labels were checked against the [official runner image catalog](https://github.com/actions/runner-images/blob/main/README.md). Remote execution is intentionally used in place of the owner's desktop for this audit.
