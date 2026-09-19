# App and system-widget upgrade validation

## Incident on September 16, 2026

The live macOS gallery still showed the previous pulse icon and old dark widgets with the heading “Мой день” (“My day”), a “ДЕМО” (“DEMO”) badge, and sample readings. **0.4.0, build 10** was already installed at `/Applications/GarminDesk.app`, and the installed icon's checksum matched the current `Resources/AppIcon.icns`. The failure was not simply a missing new package on disk.

The running `GarminDeskWidgets` process had started on **September 15 at 22:00**, while the installed executables had been updated on **September 16 at 12:47**. Times were recorded using the Mac's local clock, Europe/Moscow. This indicates that the extension process survived the package replacement; stale gallery images were also observed. File verification and synthetic rendering did not detect this scenario.

Local recovery consisted of force-registering the installed app with `lsregister -f`, registering its extension with `pluginkit -a`, terminating `GarminDeskWidgets` processes with `pkill`, and restarting `NotificationCenter` with `killall`. The actual gallery, inspected through the UI afterward, showed the new watch icon, turquoise overview, and orange sport previews with empty-state prompts to connect Garmin.

**Only local gallery recovery was confirmed.** This was not a normal upgrade test, did not verify every kind/size, and is not a universal fix for users. These service operations are not part of the user upgrade process and must not be run automatically by the app. Personal readings, credentials, and profile identifiers are omitted from this report.

## What this scenario verifies

This procedure reproduces an upgrade from the previous public release to the exact candidate. Successful compilation, matching signatures/icons on disk, extension registration, and PNGs from test rendering remain necessary separate checks; they do not prove that macOS displays the new code and snapshots after replacing the app.

The app already writes a snapshot and calls `WidgetCenter.shared.reloadAllTimelines()` at launch and after subsequent changes. According to [Apple's documentation](https://developer.apple.com/documentation/widgetkit/widgetcenter), this API requests timeline updates for configured widgets. It does not confirm replacement of the running extension process or refresh of the gallery icon.

## Preparation

1. Use a Mac with a normal graphical session and no other GarminDesk copies sharing the same bundle ID. Record the macOS version/build, architecture, previous app version/build, candidate commit, and CI link. The owner's Mac is not required.
2. Download the previous public release and the candidate from the draft. Verify published SHA-256 checksums, signatures, and matching app/extension versions. Save checksums of the exact files to be installed. Record a separate result for each claimed architecture/OS; explicitly identify unverified configurations.
3. Install the previous release normally. For the 0.5.0 baseline, use its five fixed kinds: Summary, Day, Sport, Sleep, and Training calendar; there are no profiles or assignments to create. Record the Summary measurement selection, language, app/widget appearance, and refresh cadence. Use test data/an account without personal information, or an empty state. Do not publish the contents of a real cache. When testing an older release with profiles, separately record its assignments and expected migration.
4. Open the previous version's gallery and inspect every kind it provides in small, medium, and large sizes. Place widgets of every kind on the desktop, covering all three sizes across existing instances. Record their initial appearance and measurement selection (and legacy assignments only if that version has them). Confirm that the extension has launched; leave the widgets in place.

## Normal upgrade and required results

1. Quit only the GarminDesk app using **⌘Q**. In Finder, replace it in **Applications** with the app from the downloaded candidate DMG, then launch the installed copy. Do not delete the app beforehand or use clean preferences: this is an upgrade scenario.
2. Compare the installed app and embedded extension's versions/builds and signatures against the candidate. Verify that the installed executables and icon match the exact downloaded package.
3. Open the system gallery. Verify the current watch icon and appearance of **all five kinds in all three sizes**: Summary, Day, Sport, Sleep, and Training. The default colorful appearance uses turquoise for Day, orange for Sport, purple for Sleep, and blue for Training. Large Summary shows one leading measurement and supporting measurements in a unified layout, without calendar panels. Gallery previews must contain synthetic measurements and a sample calendar with a localized **Demo** badge; the five types should be distinguishable before connection. Preview dates should match the current calendar, and appearance/language/Summary selections should be reflected. Sport shows measurements only. Check the watch icon at the gallery's small size for an extra gray plate. Record how long it takes for the current images to appear. The current labeled examples are intentional and must not be confused with the old pulse-icon/“My day” design from the incident.
4. Check every existing desktop instance: new appearance, actual data or the correct empty state, and no old heading or diagnostic timestamp. Real desktop timelines must not display synthetic gallery readings or a Demo badge. If using a test account, check that widget content changes after a normal data refresh in the app and record the actual delay.
5. Verify that language, app appearance, refresh cadence, cached readings, calendar coverage, and the account connection are preserved. User-created profiles, assignments, and mixed layouts are intentionally retired; the app must have no profile editor or assignment controls. When upgrading from 0.5.0, Summary's existing ordered measurement selection must be preserved. A migration from an older profile-based release initializes Summary's default measurement list. Change its main measurement and selected values, verify the widget and preview reflect those choices, then reopen the app to confirm persistence. The kind identifiers from 0.5.0 stay unchanged. For a baseline older than 0.5.0, the four earlier identifiers stay unchanged and Day is added. Try Colorful, Light, and Dark in Widgets settings and confirm visibly different backgrounds and readable content in existing instances after normal timeline refresh. With a connected test account, clicking each widget must open its fixed purpose; without a connection, it should open account setup. Valid old profile URLs should resolve their known slot or fall back to Summary. State unverified links separately rather than treating them as a pass.
6. Add one new instance of each kind, including Day. Verify the transition from the marked gallery example to actual data or a connection/waiting state; an initial system placeholder is not an accepted live timeline. Close and reopen the gallery and the app. Confirm the five-type setup and chosen appearance persist. Record results and screenshots without personal data.

**Do not perform operations that could conceal an upgrade failure before completing the required checks:** clearing caches, running `lsregister`/`pluginkit`, force-terminating the extension or NotificationCenter, deleting old widgets, signing out of the user session, or rebooting the Mac. These operations may be used only after recording the failure, as separate diagnostics/recovery. A post-reboot check is useful additional evidence but does not replace a normal upgrade test.

If old images, the old icon, or a broken instance remain, record **FAIL** and the observation time, save diagnostics, and keep the release as a draft. Do not wait indefinitely or record success after service-level recovery. Fix the cause or revise the supported upgrade procedure, then repeat the scenario from the previous release to the new exact candidate.

## Report required to publish a draft

Complete a separate report for each tested environment:

| Field | Result |
| --- | --- |
| Date, time zone, test environment | Fill in |
| macOS/build, architecture | Fill in |
| Previous version/build and package source | Fill in |
| Candidate: version/build, commit, CI | Fill in |
| Downloaded DMG: source and SHA-256 | Fill in |
| Installed host/widget: versions, signatures, package match | PASS / FAIL + evidence |
| Gallery icon and 5 kinds × 3 sizes | PASS / FAIL + screenshots |
| Existing instances and content refresh | PASS / FAIL + delays; state data limitations explicitly |
| Settings/data migration, no profile UI, fixed-purpose links | PASS / FAIL |
| Colorful, Light, Dark in existing widgets | PASS / FAIL + refresh delays |
| New instances and reopening | PASS / FAIL |
| Service intervention before completing checks | Must be “none” |
| Overall result | PASS / FAIL; unchecked items do not count as PASS |

Link the report to the [publication checklist](publication-checklist.md). Publish the same draft with the same verified files; changing the package or source commit requires new acceptance testing. Recovery evidence from the 0.4.0 incident does not retrospectively complete this report.
