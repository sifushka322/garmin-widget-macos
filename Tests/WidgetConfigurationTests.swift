import Foundation
import Darwin

/// Frozen subset of the old extension's wire schema. Do not use the current
/// AppPreferences/WidgetProfile decoder here: that would hide compatibility bugs.
private struct LegacyWidgetPreferences: Decodable {
    enum Language: String, Decodable { case system, en, ru }
    enum Appearance: String, Decodable { case system, light, dark }
    struct Profile: Decodable {
        enum Style: String, Decodable { case calm, sport, monochrome }
        enum Density: String, Decodable { case comfortable, compact }
        enum Content: String, Decodable { case metrics, training, mixed }
        let id: UUID
        let name: String
        let metricIDs: [String]
        let primaryMetric: String
        let style: Style
        let density: Density
        let contentMode: Content?
    }
    let language: Language
    let appearance: Appearance
    let refreshMinutes: Int
    let profiles: [Profile]
    let widgetProfileIDs: [String: String]
}

@main
struct WidgetConfigurationTests {
    struct Failure: Error, CustomStringConvertible { var description: String }
    static var checks = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw Failure(description: message) }
    }
    static func bytes(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    static func decodePreferences(_ object: [String: Any]) throws -> AppPreferences {
        try AppJSON.decoder.decode(AppPreferences.self, from: bytes(object))
    }
    static let oldID = "92F73079-FB63-4700-9962-D4DA5A5AC349"
    static func historicalPreferences(style: String = "sport") -> [String: Any] {
        ["language": "de", "appearance": "dark", "refreshMinutes": 30, "menuMetric": "hydration",
         "profiles": [["id": oldID, "name": "Custom fixture", "metricIDs": ["weight", "hydration"],
                       "primaryMetric": "weight", "style": style, "density": "compact", "contentMode": "mixed"]],
         "widgetProfileIDs": ["overview": oldID, "sport": oldID, "sleep": "dangling", "training": oldID]]
    }

    static func testPreferenceMigration() throws {
        let old = historicalPreferences()
        let migrated = try decodePreferences(old)
        try expect(migrated.language == .de && migrated.appearance == .dark && migrated.refreshMinutes == 30,
                   "Independent app settings must survive the removal of profiles")
        try expect(migrated.widgetAppearance == .colorful, "Legacy sport styling maps to the colorful product appearance")
        let serialized = try JSONSerialization.jsonObject(with: AppJSON.encoder.encode(migrated)) as! [String: Any]
        try expect(Set(serialized.keys) == ["language", "appearance", "widgetAppearance", "summaryMetrics", "refreshMinutes"],
                   "Standalone preferences must not save profiles, assignments, names, or legacy menu choices")
        try expect(migrated.summaryMetrics == AppPreferences.defaultSummaryMetrics,
                   "Old preferences must receive the new Summary defaults without restoring obsolete profile selections")
        let restored = try decodePreferences(serialized)
        try expect(restored.language == .de && restored.appearance == .dark && restored.refreshMinutes == 30,
                   "Migrated settings must remain stable across the second launch")
        for appearance in ["system", "light", "dark"] {
            var monochrome = historicalPreferences(style: "monochrome")
            monochrome["appearance"] = appearance
            try expect(try decodePreferences(monochrome).widgetAppearance == (appearance == "dark" ? .dark : .light),
                       "Legacy monochrome styling must map deterministically without decoding a new enum into an old field")
        }
        for value in [NSNull(), [], "corrupt", [["style": "unknown"]]] as [Any] {
            var damaged = old
            damaged["profiles"] = value
            damaged["widgetProfileIDs"] = ["training": "missing"]
            let decoded = try decodePreferences(damaged)
            try expect(decoded.language == .de && decoded.refreshMinutes == 30 && decoded.widgetAppearance == .colorful,
                       "Malformed obsolete profile data must not reset unrelated app settings")
            try expect(WidgetSlot.allCases.allSatisfy { !$0.profile(in: decoded).metricIDs.isEmpty },
                       "Every fixed type must be configured without a usable historical assignment")
        }
        for language in AppLanguage.allCases {
            var object = old; object["language"] = language.rawValue
            try expect(try decodePreferences(object).language == language, "Every existing language must survive migration")
        }
        for value in ["colorful", "light", "dark", "future-appearance"] {
            var object = historicalPreferences(style: "monochrome"); object["widgetAppearance"] = value
            try expect(try decodePreferences(object).widgetAppearance == (WidgetAppearance(rawValue: value) ?? .colorful),
                       "An explicit widget appearance wins over the obsolete profile style, with safe unknown-value fallback")
        }
        try expect(try decodePreferences([:]).refreshMinutes == 15, "Missing old settings receive normal defaults")
        try expect(try decodePreferences(["refreshMinutes": 0]).refreshMinutes == 5, "Migration must retain the minimum refresh interval")
        try expect(try decodePreferences(["refreshMinutes": 99999]).refreshMinutes == 1440, "Migration must retain the maximum refresh interval")
    }

    static func testOldSnapshotWithNewReader() throws {
        let fixture = GarminSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_789_473_600), sourceDate: "2026-09-15",
                                    devices: ["Fixture watch"], metrics: ["steps": .init(value: 0), "weight": .init(value: 75)])
        let snapshot = try JSONSerialization.jsonObject(with: AppJSON.encoder.encode(fixture))
        let old: [String: Any] = ["version": 1, "preferences": historicalPreferences(), "snapshot": snapshot, "isConnected": true]
        let decoded = try AppJSON.decoder.decode(WidgetData.self, from: bytes(old))
        try expect(decoded.isConnected && decoded.snapshot.sourceDate == fixture.sourceDate,
                   "An old snapshot must remain readable before the new host first launches")
        try expect(decoded.snapshot.metrics["steps"]?.value == 0 && decoded.snapshot.metrics["weight"]?.value == 75,
                   "Preference migration must not alter cached measurements, including optional historical readings")
        try expect(decoded.preferences.summaryMetrics == AppPreferences.defaultSummaryMetrics,
                   "An old widget snapshot must also receive Summary defaults before the host rewrites it")
        for slot in WidgetSlot.allCases {
            let recipe = slot.profile(in: decoded.preferences)
            try expect(recipe.id == slot.profile(in: AppPreferences()).id,
                       "Old custom UUIDs must not leak into fixed identities")
            if slot != .training {
                try expect(!recipe.metricIDs.contains("weight") && !recipe.metricIDs.contains("hydration"),
                           "An obsolete custom selection must not change a fixed widget's purpose")
            }
        }
    }

    static func testSummarySelectionAndPersistence() throws {
        let expectedDefaults = ["bodyBattery", "steps", "sleepDuration", "stress", "trainingReadiness", "restingHeartRate",
                                "sleepScore", "intensityMinutes", "activeCalories", "recoveryTime", "hrv"]
        try expect(AppPreferences().summaryMetrics == expectedDefaults, "Summary defaults must match the agreed mixed-metric selection")
        for invalid in [NSNull(), [], ["heartRate", "future-metric"], "malformed"] as [Any] {
            var old = historicalPreferences(); old["summaryMetrics"] = invalid
            let preferences = try decodePreferences(old)
            try expect(preferences.summaryMetrics == expectedDefaults && preferences.language == .de && preferences.refreshMinutes == 30,
                       "Invalid or empty Summary settings must recover without resetting independent preferences")
        }
        var object = historicalPreferences()
        object["summaryMetrics"] = ["hydration", "steps", "hydration", "heartRate", "weight", "future-metric"]
        var preferences = try decodePreferences(object)
        try expect(preferences.summaryMetrics == ["hydration", "steps", "weight"],
                   "Summary migration must retain the first occurrence of each supported selection in order")
        let snapshot = GarminSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_789_473_600), sourceDate: "2026-09-15",
                                     devices: [], metrics: ["steps": .init(value: 0), "bodyBattery": .init(value: 80),
                                                           "hydration": .init(value: 1250), "sleepDuration": .init(value: 480)])
        let available = WidgetMetricPolicy.summarySelection(preferences: preferences, snapshot: snapshot)
        try expect(available.primary == "hydration" && available.secondary == ["steps"],
                   "Summary must preserve chosen priority, accept real zero, skip missing readings, and exclude unselected fillers")
        preferences.summaryMetrics = ["weight", "hydration"]
        var missing = snapshot; missing.metrics["hydration"] = nil
        let absent = WidgetMetricPolicy.summarySelection(preferences: preferences, snapshot: missing)
        try expect(absent.primary == "weight" && absent.secondary.isEmpty,
                   "If all chosen readings are absent, Summary must show its chosen primary as missing without adding unrelated values")
        missing.retainedMetrics["weight"] = .init(reading: .init(value: 73), sourceDate: "2026-09-13",
                                                 retrievedAt: snapshot.fetchedAt, changedAt: snapshot.fetchedAt)
        let retained = WidgetMetricPolicy.summarySelection(preferences: preferences, snapshot: missing)
        try expect(retained.primary == "weight" && retained.secondary.isEmpty && MetricFormatter(snapshot: missing, language: .en).context("weight")?.contains("2026") == true,
                   "An explicitly chosen retained reading must remain available with its original provenance")
        preferences.summaryMetrics = ["steps", "weight", "steps", "unknown"]
        let roundtrip = try AppJSON.decoder.decode(AppPreferences.self, from: AppJSON.encoder.encode(preferences))
        try expect(roundtrip.summaryMetrics == ["steps", "weight"], "Encoding must preserve a sanitized, ordered Summary selection")
        let data = WidgetData(preferences: roundtrip, snapshot: snapshot, isConnected: true)
        let currentObject = try JSONSerialization.jsonObject(with: AppJSON.encoder.encode(data)) as! [String: Any]
        let legacy = try AppJSON.decoder.decode(LegacyWidgetPreferences.self, from: bytes(currentObject["preferences"]!))
        let summaryID = legacy.widgetProfileIDs["overview"]!
        try expect(legacy.profiles.first { $0.id.uuidString == summaryID }?.metricIDs == ["steps", "weight"],
                   "A running old extension must receive the selected Summary readings through its private compatibility recipe")
        try expect(WidgetSlot.sport.profile(in: roundtrip).metricIDs == WidgetSlot.sport.profile(in: AppPreferences()).metricIDs
                   && WidgetSlot.sleep.profile(in: roundtrip).metricIDs == WidgetSlot.sleep.profile(in: AppPreferences()).metricIDs,
                   "Editing Summary must not mutate the dedicated Sport or Sleep recipes")
        try expect(!WidgetSlot.overview.includesTraining && WidgetSlot.training.includesTraining,
                   "Summary is one metric widget; the dedicated Training type owns the calendar")
    }

    static func testNewSnapshotWithOldReader() throws {
        let prefs = try decodePreferences(historicalPreferences())
        let current = WidgetData(preferences: prefs, snapshot: .empty, isConnected: true)
        let object = try JSONSerialization.jsonObject(with: AppJSON.encoder.encode(current)) as! [String: Any]
        let legacy = try AppJSON.decoder.decode(LegacyWidgetPreferences.self, from: bytes(object["preferences"]!))
        try expect(object["version"] as? Int == 1, "The transition snapshot must retain the old readable schema version")
        try expect(legacy.profiles.count == 4 && legacy.widgetProfileIDs.count == 4,
                   "Only the four historical kinds need private compatibility assignments")
        try expect(legacy.language == .en && legacy.appearance == .dark && legacy.refreshMinutes == 30,
                   "The compatibility projection must use an old-reader language while preserving its other settings")
        var identities = Set<UUID>()
        for slot in [WidgetSlot.overview, .sport, .sleep, .training] {
            guard let id = legacy.widgetProfileIDs[slot.rawValue],
                  let recipe = legacy.profiles.first(where: { $0.id.uuidString == id }) else {
                throw Failure(description: "Old reader cannot resolve \(slot.rawValue)")
            }
            try expect(identities.insert(recipe.id).inserted, "Legacy projection IDs must be unique across kinds")
            try expect(recipe.id == slot.profile(in: prefs).id && !recipe.name.isEmpty,
                       "Each legacy kind resolves a stable, named recipe")
            try expect(recipe.metricIDs.contains(recipe.primaryMetric), "Old readers must receive a valid primary metric")
            try expect(recipe.contentMode == (slot == .training ? .training : .metrics),
                       "An old running extension must not mistake Sport for a calendar or Training for metrics")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GarminWidgetMigration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try WidgetDataStore.write(current, to: directory)
        let roundtrip = WidgetDataStore.read(from: directory)
        try expect(roundtrip?.isConnected == true && roundtrip?.preferences.language == .de,
                   "The snapshot projection must survive the real atomic writer and guarded reader")
        for language in AppLanguage.allCases {
            var translated = prefs; translated.language = language
            let data = try AppJSON.encoder.encode(WidgetData(preferences: translated, snapshot: .empty, isConnected: true))
            let translatedObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let old = try AppJSON.decoder.decode(LegacyWidgetPreferences.self, from: bytes(translatedObject["preferences"]!))
            let supported = LegacyWidgetPreferences.Language(rawValue: language.rawValue) ?? .en
            try expect(old.language == supported,
                       "Every current language must encode a value accepted by the original three-language extension")
            try expect(old.widgetProfileIDs.count == 4 && old.widgetProfileIDs.values.allSatisfy { id in old.profiles.contains { $0.id.uuidString == id } },
                       "Every language must preserve all four old kind assignments")
            let currentReader = try AppJSON.decoder.decode(WidgetData.self, from: data)
            try expect(currentReader.preferences.language == language,
                       "Snapshot compatibility must never change the language seen by the current reader")
            let standalone = try JSONSerialization.jsonObject(with: AppJSON.encoder.encode(translated)) as! [String: Any]
            try expect(standalone["language"] as? String == language.rawValue && standalone["widgetLanguage"] == nil,
                       "Compatibility language fields must not leak into standalone app preferences")
        }
    }

    static func testStableKindsAndRoutes() throws {
        let kinds: [WidgetSlot: String] = [.overview: "GarminDeskSummary", .day: "GarminDesk.day", .sport: "GarminDesk.sport",
                                         .sleep: "GarminDesk.sleep", .training: "GarminDesk.training"]
        try expect(WidgetSlot.allCases.count == 5, "The product exposes exactly five fixed widget types")
        for slot in WidgetSlot.allCases {
            try expect(slot.kind == kinds[slot], "Existing desktop kinds must retain their exact identity")
            let link = WidgetLink(slot: slot).url!
            try expect(link.host == "widget" && WidgetLink(url: link)?.slot == slot,
                       "A current widget must open its own purpose without a saved profile")
            let old = URL(string: "garmindesk://profile/" + oldID + "?slot=" + slot.rawValue)!
            try expect(WidgetLink(url: old)?.slot == slot, "Legacy explicit-purpose links must remain usable after deleting profile preferences")
        }
        for suffix in ["", "?slot=unknown", "?slot="] {
            try expect(WidgetLink(url: URL(string: "garmindesk://profile/" + oldID + suffix)!)?.slot == .overview,
                       "An old profile-only or unknown-slot link must safely open Summary")
        }
        for invalid in ["https://widget/sleep", "garmindesk://widget/unknown", "garmindesk://profile/not-a-uuid", "garmindesk://other/day"] {
            try expect(WidgetLink(url: URL(string: invalid)!) == nil, "Unrelated or malformed links must not create widget navigation")
        }
    }

    static func testSyntheticGalleryPreview() throws {
        let date = ISO8601DateFormatter().date(from: "2026-12-31T12:00:00Z")!
        let utc = TimeZone(secondsFromGMT: 0)!
        var preferences = AppPreferences()
        preferences.language = .de
        preferences.widgetAppearance = .dark
        preferences.summaryMetrics = ["hydration", "weight"]
        let preview = WidgetPreviewData.make(preferences: preferences, at: date, timeZone: utc)
        try expect(preview.snapshot.isDemo && preview.isConnected && preview.snapshot.hasMeasurements,
                   "Gallery examples must be filled and explicitly synthetic instead of imitating a live disconnected state")
        try expect(preview.preferences.language == .de && preview.preferences.widgetAppearance == .dark && preview.preferences.summaryMetrics == ["hydration", "weight"],
                   "A gallery preview must honor presentation settings and the chosen Summary measurements")
        try expect(preview.snapshot.fetchedAt == date && preview.snapshot.sourceDate == "2026-12-31",
                   "The supplied preview date must control its snapshot date, not the current process clock")
        try expect(preview.snapshot.devices.isEmpty && preview.snapshot.retainedMetrics.isEmpty && preview.snapshot.warnings.isEmpty,
                   "Synthetic previews must not contain personal device names, retained cache values, or real account diagnostics")
        let formatter = MetricFormatter(snapshot: preview.snapshot, language: preferences.language)
        try expect(Set(preview.snapshot.metrics.keys) == Set(MetricDefinition.catalog.map(\.id))
                   && MetricDefinition.catalog.allSatisfy { formatter.value($0.id) != nil },
                   "Every supported optional Summary choice needs a valid demo reading, with unsupported live pulse excluded")
        let summary = WidgetMetricPolicy.summarySelection(preferences: preferences, snapshot: preview.snapshot)
        try expect(summary.primary == "hydration" && summary.secondary == ["weight"],
                   "Synthetic Summary content must remain limited to the selected measurements")
        let expected: [WidgetSlot: String] = [.day: "bodyBattery", .sport: "trainingReadiness", .sleep: "sleepDuration"]
        for (slot, primary) in expected {
            let recipe = slot.profile(in: preferences)
            let selected = WidgetMetricPolicy.selection(for: recipe, snapshot: preview.snapshot)
            try expect(selected.primary == primary && recipe.contentMode == .metrics,
                       "Each dedicated measurement preview must retain its own purpose")
        }
        try expect(WidgetSlot.training.profile(in: preferences).contentMode == .training && !WidgetSlot.overview.includesTraining,
                   "The calendar preview belongs to Training while Summary remains a metric widget")
        guard let timeline = preview.snapshot.trainingTimeline else { throw Failure(description: "Gallery calendar lacks synthetic records") }
        try expect(timeline.past.count == 2 && timeline.upcoming.count == 3,
                   "A filled calendar preview must include both completed and planned examples")
        try expect(timeline.past.allSatisfy { $0.id.hasPrefix("preview-") && $0.title.isEmpty && ($0.startedAt ?? .distantFuture) <= date }
                   && timeline.upcoming.allSatisfy { $0.id.hasPrefix("preview-") && $0.title.isEmpty && $0.localDate >= "2026-12-31" },
                   "Preview records must be recognizable synthetic fixtures with localized sport titles and honest relative dates")
        try expect(timeline.futureCoveredMonths == ["2026-12", "2027-01"] && timeline.futureCoverageEnd == "2027-01-31",
                   "Preview coverage must roll into the next year without claiming the wrong month")
        let calendar = TrainingCalendarPresentation(snapshot: timeline, language: .de, now: date, timeZone: utc)
        try expect(calendar.events.count == 5 && calendar.events.contains { $0.kind == .completed && $0.day == calendar.today }
                   && calendar.events.contains { $0.kind == .planned && $0.day == calendar.today },
                   "The calendar must visibly distinguish completed and planned examples on the supplied current date")
        try expect(calendar.warning == nil && timeline.upcoming.allSatisfy { calendar.scheduleKnown(on: $0.localDate) },
                   "All sample planned dates must fall inside the sample's declared coverage")
        let repeated = WidgetPreviewData.make(preferences: preferences, at: date, timeZone: utc)
        try expect(try AppJSON.encoder.encode(repeated) == AppJSON.encoder.encode(preview),
                   "A fixed input date and settings must produce deterministic preview data")
        let east = WidgetPreviewData.make(preferences: preferences, at: date, timeZone: TimeZone(secondsFromGMT: 14 * 3600)!)
        try expect(east.snapshot.sourceDate == "2027-01-01" && east.snapshot.trainingTimeline?.futureCoveredMonths == ["2027-01", "2027-02"],
                   "Preview dates and coverage must respect the requested timezone at a year boundary")
        for language in AppLanguage.allCases {
            for appearance in WidgetAppearance.allCases {
                var local = preferences; local.language = language; local.widgetAppearance = appearance
                let translated = WidgetPreviewData.make(preferences: local, at: date, timeZone: utc)
                try expect(translated.preferences.language == language && translated.preferences.widgetAppearance == appearance
                           && translated.snapshot.metrics == preview.snapshot.metrics && translated.snapshot.trainingTimeline == timeline,
                           "Language and appearance changes must not inject personal or different demo measurements")
            }
        }
        let liveEntry = GarminEntry(date: date, data: preview, slot: .overview)
        let galleryEntry = GarminEntry(date: date, data: preview, slot: .overview, isGalleryPreview: true)
        try expect(!liveEntry.isGalleryPreview && galleryEntry.isGalleryPreview,
                   "Demo rendering requires an explicit entry flag; synthetic data alone must not authorize live display")
        let storedObject = try JSONSerialization.jsonObject(with: AppJSON.encoder.encode(preview)) as! [String: Any]
        try expect(storedObject["isGalleryPreview"] == nil && WidgetData.preview.snapshot.isDemo,
                   "The preview-only permission must not be serialized into a cache or silently change legacy demo data")
    }

    static func main() {
        do {
            try testPreferenceMigration()
            try testOldSnapshotWithNewReader()
            try testNewSnapshotWithOldReader()
            try testSummarySelectionAndPersistence()
            try testStableKindsAndRoutes()
            try testSyntheticGalleryPreview()
            print("PASS: \(checks) fixed widget migration and compatibility checks")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
