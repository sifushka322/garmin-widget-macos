# Localization

GarminDesk's next source version supports twelve languages: `en`, `ru`, `de`, `fr`, `es`, `it`, `pt-BR`, `nl`, `pl`, `ja`, `ko`, and `zh-Hans`. The public 0.4.0 packages contain English and Russian only.

## Catalogs

The English source catalog and Russian translation are in `Sources/GarminDesk/Localization.swift`. Each additional language has a `Sources/Shared/Localizations*.swift` catalog. Both the host app and widget extension compile the same tables. The five fixed widget titles and descriptions come from the same catalogs; the obsolete App Intents profile resources have been removed.

Every catalog must include every English key and preserve format arguments such as `%d` and `%@`. Use short, descriptive metric labels. Keep brand names such as Garmin Connect and Body Battery. Do not translate workout titles retrieved from Garmin, and do not turn measurement labels into medical advice.

## Adding or revising a language

1. Add the language and native name to `AppLanguage`, including preference matching and a formatting locale. Preserve stored language identifiers.
2. Add a complete catalog and select it in `Localizer.table(for:)`.
3. List the language in both bundle plists and translate all five widget titles/descriptions.
4. Run `LocalizationTests` and render app/widget fixtures. Check minimum-width screens, long labels and warnings, all widget sizes, and native-script fonts. Synthetic fixtures are not live gallery validation.
5. Have a fluent speaker review meaning and terminology before describing the translation as professionally reviewed. Keep a record of the reviewed version and any remaining limitations.

The automated tests reject missing or empty translations and changed format arguments. English fallback remains a runtime safeguard; it is not accepted as a substitute for a complete translation.

The interface follows the first supported system preference and uses English if none match. The Simplified Chinese catalog does not claim Traditional Chinese support. Brazilian Portuguese is the project's Portuguese variant. Selecting a language in the app updates the shared widget preferences; macOS controls when installed widgets and the gallery render those changes.

Apple recommends testing supported languages and regions, including changes in text length and fonts: [Localization](https://developer.apple.com/localization/), [internationalization testing](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPInternational/TestingYourInternationalApp/TestingYourInternationalApp.html).

New widget snapshots carry the actual selection in `widgetLanguage`, while the legacy `language` field stays within `system`/`en`/`ru` so an older running extension can still decode the handoff. The app’s own preferences keep the actual selection in `language`. Migration tests verify both old and new readers for all twelve languages.
