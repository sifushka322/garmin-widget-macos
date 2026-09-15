# WidgetKit runtime: evidence and remaining validation

> Historical validation for GarminDesk 0.2.0 (through build 7). The app changes to a regular Dock/window interface in 0.3.0. See [0.3.0 release validation](releases/0.3.0.md); these earlier checks do not validate its new UI or packages.

## Current result

**Native widgets work in the tested local configuration:** GarminDesk 0.2.0, now installed as build 7 under `/Applications`, Apple Silicon, macOS 26.6.2, ad-hoc signing, no Apple Account and no App Group.

- Four GarminDesk kinds appeared in the **actual system gallery**: overview, sport, sleep and training.
- Two medium widget instances ran on the desktop with **live timelines**. The user confirmed that they show actual measurements.
- All four static slots were assigned to profiles in the native app UI; those assignments persisted in the shared widget data.
- The user confirmed that clicking a system widget opens the GarminDesk top panel.

Five profiles and all four slot assignments survived the app update. The revised medium layout passed 12 RU/EN × density × metric-set render cases, plus two large renders. Actual RU → EN → system-language switching was also checked.

No personal measurements, profile UUIDs, account identifiers or session material are included here. **Build 7 is installed and open; its app, ZIP and DMG are verified.** The final unattended cycle after restart refreshed a connected widget snapshot at the same retrieval time as the host, preserving five profiles and all four slots. See [overall validation](validation.md).

## Runtime fix

The direct Swift build must use the extension process entry point **`_NSExtensionMain`**, passed as `-Xlinker -e -Xlinker _NSExtensionMain`. The earlier executable could compile and register in PlugInKit while the widget process failed to provide a usable timeline. Correcting the entry point enabled actual gallery and provider execution in the tested build.

This conclusion now rests on the gallery, desktop instances and real timelines. Earlier PlugInKit registration, successful compilation and standalone SwiftUI renders were preliminary checks only.

## Data sharing without an Apple Account

The host writes a prepared JSON snapshot to:

```text
~/Library/Application Support/GarminDesk/Widgets/widget-data.json
```

The extension runs in App Sandbox with the documented `com.apple.security.temporary-exception.files.home-relative-path.read-only` entitlement restricted to:

```text
/Library/Application Support/GarminDesk/Widgets/
```

This follows the [Apple sandbox temporary-exception entitlement format](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html). It grants read access to that directory, not the user's whole home. WebKit cookies, passwords and legacy Keychain records are not in the widget snapshot.

`WidgetDataStore` resolves the current user's actual home through the system user record, validates the file and owner, rejects symlink reads, and writes protected snapshots atomically. An explicit App Group remains an optional mode; the default working configuration does not invent a Team ID or require a group.

A separate ad-hoc sandbox probe using synthetic files established allowed reads in the dedicated directory, denied reads of a neighboring file and denied writes. The actual WidgetKit provider is now also confirmed to read live shared data. The synthetic probe remains useful for testing the entitlement boundary without exposing health data.

## Configuration variants

| Variant | Status and behavior |
| --- | --- |
| Local `StaticConfiguration` | Validated in the system gallery. Four widget kinds use four slots; profiles are assigned in GarminDesk. Slot assignment and widget opening of the panel are confirmed. |
| Xcode `AppIntentConfiguration` | Optional variant with a per-instance system profile picker. Metadata extraction and this variant's gallery behavior remain unverified locally. |

The installed Command Line Tools lack `appintentsmetadataprocessor`. This limits the optional App Intents build; it is **not a blocker to the working static widgets**. The prepared CI uses full Xcode and requires metadata extraction, but has not run. The extraction command is based on the primary implementation in [Bazel rules_apple](https://github.com/bazelbuild/rules_apple/blob/main/apple/internal/resource_actions/app_intents.bzl).

`GARMIN_WIDGET_CONFIGURATION_MODE` records `static` or `profile-intents`; `GARMIN_WIDGET_CONFIGURATION_AVAILABLE` records a compiled configuration variant. These build flags do not themselves prove runtime behavior. `GARMIN_APPINTENTS_METADATA_AVAILABLE=false` is expected for the working local static variant.

## Signing and installation

The validated app uses ad-hoc signatures, including the sandbox entitlement on the extension. It does not use a paid Developer ID, notarization, an Apple Account or App Groups. Ad-hoc signing is a technical integrity requirement for Apple Silicon execution; it does not confer Gatekeeper trust. [Apple Silicon signing requirements](https://developer.apple.com/documentation/macos-release-notes/macos-big-sur-11_0_1-universal-apps-release-notes/).

Build 7's ZIP/DMG and installation in `/Applications` were verified, including byte-identical host/widget executables across built, extracted and installed copies. A trusted downloaded app may require the standard macOS **Open Anyway** action. No Gatekeeper-disable or quarantine-removal procedure is part of the package. See [distribution](distribution.md).

## Final build and future compatibility

Build 7 is compiled, installed and its exact artifacts are verified. The medium layout review is complete. Wider compatibility checks below are future work beyond the tested personal installation:

1. Run the prepared CI and separately validate its optional App Intents variant before promising its system profile picker.
2. Test Intel, other macOS versions including the macOS 14 target, and installation on a separate clean Mac before claiming those environments work.
3. Extend runtime coverage beyond the two medium desktop instances: other sizes, Notification Center and restart/reboot scenarios. Standalone renders already cover RU/EN layouts, but do not replace those system checks.

Actual gallery registration and the default shared-data path are confirmed on the tested Mac. Normal sign-in and saved-session reuse are confirmed; the final connection observations are tracked in the [live connection report](native-web-live-validation.md). Wider platform support is future work, not a blocker to the validated local widget runtime.
