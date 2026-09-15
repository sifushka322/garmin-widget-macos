import Foundation
import Darwin

/// Standalone checks for the data exchanged by the Mac app and WidgetKit.
/// Compile with Sources/Shared/*.swift and Sources/GarminDesk/Localization.swift.
@main
struct SharedModelTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static var checked = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checked += 1
        guard condition() else { throw Failure(description: message) }
    }

    static func decodeSnapshot(_ json: String) throws -> GarminSnapshot {
        try AppJSON.decoder.decode(GarminSnapshot.self, from: Data(json.utf8))
    }

    static func snapshot(_ values: [String: Double]) -> GarminSnapshot {
        GarminSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_789_459_200), sourceDate: "2026-09-15",
            devices: [], metrics: values.mapValues { MetricReading(value: $0) })
    }

    static func testMissingMeasurementsAndUnits() throws {
        let empty = MetricFormatter(snapshot: .empty, language: .en)
        try expect(empty.value("steps") == nil, "A missing measurement must remain absent.")
        try expect(empty.display("steps") == "—", "An absent value must not appear as zero.")
        try expect(empty.progress("steps") == nil, "A missing measurement must not create goal progress.")

        let values = snapshot(["steps": 0, "stress": 0, "distance": 5.2, "sleepDuration": 462,
            "restingHeartRate": 54, "hrv": 62, "hydration": 1750, "vo2Max": 49])
        let en = MetricFormatter(snapshot: values, language: .en)
        let ru = MetricFormatter(snapshot: values, language: .ru)
        try expect(en.display("steps") == "0", "A real zero-step reading must remain visible.")
        try expect(en.progress("stress") == 0, "A real zero score must preserve zero progress.")
        try expect(en.display("distance") == "5.2 km", "English distance should use its locale and unit.")
        try expect(ru.display("distance") == "5,2 км", "Russian distance should use its locale and unit.")
        try expect(en.display("sleepDuration") == "7 h 42 min", "Sleep minutes should convert to hours and minutes.")
        try expect(ru.display("sleepDuration") == "7 ч 42 мин", "Duration units should follow the selected language.")
        try expect(ru.display("restingHeartRate") == "54 уд/мин", "Heart-rate units should be localized.")
        try expect(ru.display("hrv") == "62 мс", "HRV units should be localized.")
        try expect(ru.display("vo2Max") == "49 мл/кг/мин", "VO₂ max units should be localized.")
        try expect(en.display("spo2") == "—", "One missing metric must not inherit another metric's value.")
    }

    static func testInvalidValuesAndGoals() throws {
        let invalid = MetricFormatter(snapshot: snapshot(["steps": .infinity, "stress": .nan,
            "sleepDuration": -1, "recoveryTime": Double.greatestFiniteMagnitude]), language: .en)
        try expect(invalid.value("steps") == nil, "Infinite measurements must be rejected.")
        try expect(invalid.display("stress") == "—", "NaN measurements must be unavailable.")
        try expect(invalid.display("sleepDuration") == "—", "A negative duration must not appear as a valid measurement.")
        try expect(invalid.display("recoveryTime") == "—", "An overflowing duration must not crash formatting.")

        let noGoal = MetricFormatter(snapshot: snapshot(["steps": 100]), language: .en)
        let zeroGoal = MetricFormatter(snapshot: snapshot(["steps": 100, "stepGoal": 0]), language: .en)
        let exceeded = MetricFormatter(snapshot: snapshot(["steps": 12000, "stepGoal": 10000, "bodyBattery": 120]), language: .en)
        try expect(noGoal.progress("steps") == nil, "Step progress needs an actual goal.")
        try expect(zeroGoal.progress("steps") == nil, "A zero goal must not divide by zero.")
        try expect(exceeded.progress("steps") == 1, "An exceeded goal must stay within the progress bar.")
        try expect(exceeded.progress("bodyBattery") == 1, "Scores must stay within the progress bar.")
        try expect(exceeded.progress("stepGoal") == nil, "A goal value itself must not imply a progress scale.")
    }

    static func testSnapshotCompatibility() throws {
        let minimal = try decodeSnapshot("""
        {"fetchedAt":"2026-09-15T10:00:00Z","sourceDate":"2026-09-15","metrics":{"steps":{"value":0}}}
        """)
        try expect(minimal.devices.isEmpty, "Older snapshots may omit devices.")
        try expect(minimal.warnings.isEmpty, "Older snapshots may omit warnings.")
        try expect(!minimal.isDemo, "Real connector snapshots must not default to demo.")
        try expect(minimal.metrics["steps"]?.measuredAt == nil, "A missing measurement timestamp must remain unknown.")
        try expect(minimal.metrics["steps"]?.value == 0, "Snapshot decoding must preserve real zero values.")
        try expect(minimal.trainingTimeline == nil, "Older metric-only snapshots must not fabricate training data.")

        let fractional = try decodeSnapshot("""
        {"fetchedAt":"2026-09-15T10:00:00.123Z","sourceDate":"2026-09-15","metrics":{"heartRate":{"value":65,"measuredAt":"2026-09-15T09:58:00Z"}},"warnings":["sleep"]}
        """)
        try expect(fractional.metrics["heartRate"]?.measuredAt != nil, "Measurement time must survive decoding.")
        try expect(fractional.warnings == ["sleep"], "Partial-data warnings must survive the shared contract.")
        let encoded = try AppJSON.encoder.encode(fractional)
        let roundTrip = try AppJSON.decoder.decode(GarminSnapshot.self, from: encoded)
        try expect(roundTrip.sourceDate == fractional.sourceDate, "The Garmin calendar date must survive encoding.")
        try expect(roundTrip.metrics["heartRate"]?.measuredAt == fractional.metrics["heartRate"]?.measuredAt,
                   "Measurement times must not be replaced by fetch time.")

        let missingMetrics = """
        {"fetchedAt":"2026-09-15T10:00:00Z","sourceDate":"2026-09-15"}
        """
        try expect((try? decodeSnapshot(missingMetrics)) == nil, "Missing required metrics must reject a damaged snapshot.")
    }

    static func testProfileSelectionAndDisconnection() throws {
        var preferences = AppPreferences()
        let oldProfile = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","metricIDs":["steps"],"primaryMetric":"steps","style":"calm","density":"compact"}
        """
        let migrated = try AppJSON.decoder.decode(WidgetProfile.self, from: Data(oldProfile.utf8))
        try expect(migrated.contentMode == .metrics && migrated.name == "Legacy", "Legacy profiles remain metric-only without resetting custom settings.")
        let oldPreferences = try AppJSON.decoder.decode(AppPreferences.self, from: Data(("{\"profiles\":[" + oldProfile + "]}").utf8))
        try expect(oldPreferences.widgetProfileIDs.isEmpty && oldPreferences.profiles[0].id == migrated.id,
                   "Older preferences gain empty widget slots while keeping stable profile IDs.")
        preferences.profiles[0].contentMode = .mixed
        preferences.widgetProfileIDs["sport"] = preferences.profiles[0].id.uuidString
        let restoredPreferences = try AppJSON.decoder.decode(AppPreferences.self, from: AppJSON.encoder.encode(preferences))
        try expect(restoredPreferences.widgetProfileIDs == preferences.widgetProfileIDs && restoredPreferences.profiles[0].contentMode == .mixed,
                   "Content modes and explicit widget slot mappings survive persistence.")
        var second = WidgetProfile()
        second.name = "Sleep"
        second.primaryMetric = "sleepDuration"
        second.metricIDs = ["sleepDuration", "sleepScore", "hrv"]
        preferences.profiles.append(second)
        let disconnected = WidgetData(preferences: preferences, snapshot: snapshot(["steps": 125]), isConnected: false)
        try expect(disconnected.profile(id: nil)?.id == preferences.profiles.first?.id,
                   "An unconfigured widget should use the first profile.")
        try expect(disconnected.profile(id: second.id.uuidString)?.name == "Sleep", "A configured widget must resolve its saved profile.")
        try expect(disconnected.profile(id: UUID().uuidString) == nil, "A removed profile must not silently select unrelated metrics.")
        try expect(disconnected.profile(id: "invalid-id") == nil, "An invalid profile identifier must be treated as unavailable.")

        let bytes = try AppJSON.encoder.encode(disconnected)
        let restored = try AppJSON.decoder.decode(WidgetData.self, from: bytes)
        try expect(!restored.isConnected, "Disconnected state must survive the widget handoff.")
        try expect(!restored.snapshot.isDemo, "Cached real measurements must not become demo data after disconnection.")
        try expect(restored.snapshot.metrics["steps"]?.value == 125, "Disconnect status and cached measurements are distinct fields.")

        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        try expect(Set(object?.keys.map { $0 } ?? []) == Set(["version", "preferences", "snapshot", "isConnected"]),
                   "The shared file must contain data and preferences only, with no credentials.")
        let preview = WidgetData.preview
        try expect(preview.snapshot.isDemo && !preview.isConnected, "Gallery examples must remain visibly demo and disconnected.")
    }

    static func testSharedFileValidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GarminDesk-contract-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try expect(WidgetDataStore.read(from: directory) == nil, "A not-yet-created shared file must prompt setup.")
        try expect(WidgetDataStore.read(from: nil) == nil, "An explicitly unavailable directory must not fall back to another location.")
        try expect(WidgetDataStore.storageMode == .localReadOnlyCache, "A build without an App Group must use its local read-only cache.")
        try expect(WidgetDataStore.userHomeDirectory?.isFileURL == true, "Resolve only the current user's home from the system user record.")
        try expect(WidgetDataStore.localCacheURL?.path.hasSuffix("/Library/Application Support/GarminDesk/Widgets") == true,
                   "The local handoff must be confined to its dedicated Widgets directory.")
        do {
            try WidgetDataStore.write(.preview, to: nil)
            throw Failure(description: "Writing without a shared container must fail.")
        } catch WidgetDataStore.StoreError.unavailable {
            checked += 1
        }

        try WidgetDataStore.write(.preview, to: directory)
        let restored = WidgetDataStore.read(from: directory)
        try expect(restored?.version == 1, "A valid shared file should be readable.")
        try expect(restored?.snapshot.isDemo == true, "Writing a preview must preserve its demo marker.")
        let file = directory.appendingPathComponent(WidgetDataStore.fileName)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Shared health data must have owner-only file permissions.")
        let outside = directory.appendingPathComponent("synthetic-outside.json")
        try FileManager.default.moveItem(at: file, to: outside)
        let sentinel = Data("synthetic outside sentinel".utf8)
        try sentinel.write(to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        try expect(WidgetDataStore.read(from: directory) == nil, "The reader must not follow a substituted snapshot symlink.")
        try WidgetDataStore.write(.preview, to: directory)
        try expect(WidgetDataStore.read(from: directory)?.snapshot.isDemo == true,
                   "An atomic write must replace a symlink without modifying its target.")
        let outsideBytes = try Data(contentsOf: outside)
        try expect(outsideBytes == sentinel, "Atomic snapshot replacement must not change a symlink target.")

        var unsupported = WidgetData.preview
        unsupported.version = 99
        try AppJSON.encoder.encode(unsupported).write(to: file, options: .atomic)
        try expect(WidgetDataStore.read(from: directory) == nil, "Unsupported shared schema versions must be rejected.")
        try Data("{broken".utf8).write(to: file, options: .atomic)
        try expect(WidgetDataStore.read(from: directory) == nil, "Partial or damaged JSON must be treated as unavailable.")
        try Data("{}".utf8).write(to: file, options: .atomic)
        try expect(WidgetDataStore.read(from: directory) == nil, "Missing shared fields must not fabricate health measurements.")
    }

    static func testKnownLabels() throws {
        for language in [AppLanguage.ru, .en] {
            for definition in MetricDefinition.catalog {
                try expect(Localizer.text(definition.titleKey, language: language) != definition.titleKey,
                           "Every available metric needs a translated title: \(definition.id).")
                try expect(Localizer.text(definition.widgetTitleKey, language: language) != definition.widgetTitleKey,
                           "Every widget label needs a translation or the full-title fallback: \(definition.id).")
            }
            for key in ["widget.openApp", "widget.openAppHint", "widget.profileMissing", "widget.profileMissingHint", "widget.demo", "widget.connect"] {
                try expect(Localizer.text(key, language: language) != key, "Widget state label is missing: \(key).")
            }
        }
    }

    static func main() {
        do {
            try testUntrustedPreferencesAndFreshness()
            try testMissingMeasurementsAndUnits()
            try testInvalidValuesAndGoals()
            try testSnapshotCompatibility()
            try testProfileSelectionAndDisconnection()
            try testSharedFileValidation()
            try testKnownLabels()
            print("PASS: \(checked) shared-model checks")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    static func testUntrustedPreferencesAndFreshness() throws {
        for raw in [Int.min, Int.max] {
            let decoded = try AppJSON.decoder.decode(AppPreferences.self, from: Data("{\"refreshMinutes\":\(raw),\"profiles\":[]}".utf8))
            try expect((300...86400).contains(decoded.refreshInterval), "Untrusted cadence must be bounded before arithmetic")
            try expect(decoded.profiles.count == 1, "Empty stored profiles recover to an editable profile")
            var direct = AppPreferences(); direct.refreshMinutes = raw
            try expect(direct.staleInterval.isFinite, "Programmatic cadence cannot overflow")
        }
        var profile = WidgetProfile()
        profile.metricIDs = ["unknown", "steps", "steps"]
        profile.primaryMetric = "unknown"
        let repaired = try AppJSON.decoder.decode(WidgetProfile.self, from: AppJSON.encoder.encode(profile))
        try expect(repaired.metricIDs == ["steps"] && repaired.primaryMetric == "steps", "Stored invalid IDs and duplicates cannot reach ForEach or the API")
        var prefs = AppPreferences(); prefs.profiles = [profile, profile]
        let decoded = try AppJSON.decoder.decode(AppPreferences.self, from: AppJSON.encoder.encode(prefs))
        try expect(decoded.profiles.count == 1, "Duplicate stored profile identities are repaired")

        let now = Date(timeIntervalSince1970: 1_789_473_600)
        let zone = TimeZone(secondsFromGMT: 0)!
        var cached = snapshot(["steps": 100, "sleepDuration": 480])
        cached.sourceDate = SyncPolicy.sourceDay(for: now, timeZone: zone)
        cached.fetchedAt = now
        cached.groupUpdatedAt = ["stats": now, "sleep": now.addingTimeInterval(-7200)]
        try expect(cached.metricIsStale("sleepDuration", at: now, timeZone: zone, staleInterval: 3600), "Fresh steps cannot hide old sleep data")
        try expect(!cached.metricIsStale("steps", at: now, timeZone: zone, staleInterval: 3600), "Fresh values remain fresh")
        cached.sourceDate = "2026-01-01"
        try expect(cached.metricIsStale("steps", at: now, timeZone: zone, staleInterval: 3600), "Yesterday's data is stale even during server backoff")
        cached.isDemo = true
        try expect(!cached.metricIsStale("steps", at: now, timeZone: zone, staleInterval: 3600), "Demo remains explicitly demo")
    }
}
