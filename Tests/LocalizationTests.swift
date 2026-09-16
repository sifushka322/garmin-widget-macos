import Foundation
import Darwin

/// Catalog completeness, preference migration and real formatter behavior.
@main
struct LocalizationTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard condition() else { throw Failure(description: message) }
    }

    static func placeholders(_ value: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"%(?:[1-9][0-9]*\$)?[-+ #0]*(?:[0-9]+)?(?:\.[0-9]+)?(?:hh|ll|h|l|L|z|t|j)?[@diuoxXfFeEgGaAcCsSp]"#)
        let source = value as NSString
        return expression.matches(in: value, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range) }.sorted()
    }

    static func preferenceSelection() throws {
        let cases: [([String], AppLanguage)] = [
            ([], .en), (["ar-SA", "de-AT"], .de), (["xx", "fr-CA", "en-US"], .fr),
            (["es-MX", "ru-RU"], .es), (["it-CH"], .it), (["en-GB"], .en),
            (["ru_KZ"], .ru), (["PT_br"], .ptBR), (["pt-PT"], .ptBR),
            (["nl-BE"], .nl), (["pl-PL"], .pl), (["ja-JP"], .ja), (["ko-KR"], .ko),
            (["zh-Hans-CN"], .zhHans), (["zh-CN"], .zhHans), (["zh-SG"], .zhHans),
            (["zh"], .zhHans), (["zh-Hans-TW"], .zhHans),
            (["zh-Hant", "ja-JP"], .ja), (["zh-Hant-CN", "de-DE"], .de),
            (["zh-TW", "fr-FR"], .fr), (["zh-HK", "ko-KR"], .ko),
            (["zh-MO"], .en), (["zh-Latn", "pl-PL"], .pl),
            (["zh-Hant", "zh-Hans"], .zhHans), (["unsupported", "system"], .en)
        ]
        for (identifiers, expected) in cases {
            try expect(AppLanguage.preferred(in: identifiers) == expected,
                       "Preferred-language matching failed for \(identifiers)")
        }
        try expect(AppLanguage.supported.count == 12, "The picker must expose all twelve languages")
        try expect(Set(AppLanguage.supported.map(\.nativeName)).count == 12, "Each language needs a distinct autonym")
        for language in AppLanguage.allCases {
            var preferences = AppPreferences()
            preferences.language = language
            let encoded = try AppJSON.encoder.encode(preferences)
            let restored = try AppJSON.decoder.decode(AppPreferences.self, from: encoded)
            try expect(restored.language == language, "Saved language must round-trip: \(language.rawValue)")
            let data = WidgetData(preferences: preferences, snapshot: .empty, isConnected: false)
            let widget = try AppJSON.decoder.decode(WidgetData.self, from: AppJSON.encoder.encode(data))
            try expect(widget.preferences.language == language, "The widget must retain the selected language")
        }
        for raw in ["system", "ru", "en"] {
            let legacy = try AppJSON.decoder.decode(AppPreferences.self, from: Data("{\"language\":\"\(raw)\"}".utf8))
            try expect(legacy.language.rawValue == raw, "Legacy language preferences must not be remapped")
        }
    }

    static func catalogParity() throws {
        let expected = Set(Localizer.english.keys)
        for language in AppLanguage.supported {
            let table = Localizer.table(for: language)
            try expect(Set(table.keys) == expected,
                       "\(language.rawValue) catalog mismatch: missing \(expected.subtracting(table.keys)), extra \(Set(table.keys).subtracting(expected))")
            for key in expected {
                let value = table[key] ?? ""
                try expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(language.rawValue) contains an empty translation: \(key)")
                try expect(placeholders(value) == placeholders(Localizer.english[key]!),
                           "\(language.rawValue) changed format placeholders: \(key)")
                try expect(Localizer.text(key, language: language) == value,
                           "Selected language must use its own table: \(language.rawValue), \(key)")
            }
            try expect(Localizer.text("unknown.test.key", language: language) == "unknown.test.key",
                       "Unknown keys must remain diagnosable")
            let training = TrainingPresentation(language: language)
            try expect(training.sportTitle("RUN") == table["training.sport.running"], "Sport aliases must use the selected table")
            try expect(training.sportSymbol("RUN") == "figure.run", "Localization must preserve sport symbols")
            try expect(training.sportTitle("unknown") == table["training.workout"], "Unknown sports need a translated generic label")
            let count = String(format: table["profile.previewCount"]!, locale: language.locale, 3, 7)
            try expect(count.contains("3") && count.contains("7") && !count.contains("%d"),
                       "Metric-count format must substitute both values")
        }
    }

    static func formatting() throws {
        let now = Date(timeIntervalSince1970: 1_789_473_600)
        let snapshot = GarminSnapshot(fetchedAt: now, sourceDate: "2026-09-16", devices: [], metrics: ["weight": .init(value: 1.5)])
        let dotLanguages: Set<AppLanguage> = [.en, .ja, .ko, .zhHans]
        let timeline = TrainingTimelineSnapshot(fetchedAt: now, futureCoverageEnd: "2026-10-31",
                                                futureCoverage: .publishedCalendar, futureUpdatedAt: now)
        for language in AppLanguage.supported {
            let number = dotLanguages.contains(language) ? "1.5" : "1,5"
            try expect(MetricFormatter(snapshot: snapshot, language: language).display("weight").hasPrefix(number),
                       "Metric decimals must follow \(language.rawValue)")
            let training = TrainingPresentation(language: language, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
            try expect(training.distance(1.5)?.hasPrefix(number) == true, "Training decimals must follow the selected locale")
            let day = training.dayText("2026-10-31")!
            let empty = training.futureEmptyText(timeline)
            try expect(empty.contains(day) && !empty.contains("%@"), "Calendar coverage must interpolate its localized date")
            try expect(training.futureCoverageText(timeline).contains(day), "Coverage detail must retain its bounded date")
            try expect(training.dayText("2026-02-30") == nil, "Localized date formatting must not accept an invalid day")
        }
        let english = TrainingPresentation(language: .en).dayText("2026-10-31")
        for language in [AppLanguage.de, .fr, .ptBR, .ja, .ko, .zhHans] {
            try expect(TrainingPresentation(language: language).dayText("2026-10-31") != english,
                       "Explicit \(language.rawValue) dates must not retain US English formatting")
        }
    }

    static func bundledLanguages() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let expected = Set(AppLanguage.supported.map(\.rawValue))
        for file in ["Resources/Info.plist", "Resources/Widgets-Info.plist"] {
            let bytes = try Data(contentsOf: root.appendingPathComponent(file))
            let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as! [String: Any]
            try expect(Set(plist["CFBundleLocalizations"] as? [String] ?? []) == expected,
                       "\(file) must advertise exactly the supported languages")
        }
        for language in AppLanguage.supported {
            for slot in WidgetSlot.allCases {
                try expect(Localizer.table(for: language)[slot.titleKey] != nil, "Each fixed widget needs a localized title")
                try expect(Localizer.table(for: language)[slot.descriptionKey] != nil, "Each fixed widget needs a localized description")
            }
        }
    }

    static func main() throws {
        try preferenceSelection()
        try catalogParity()
        try formatting()
        try bundledLanguages()
        print("PASS: \(checks) localization checks across twelve languages")
    }
}
