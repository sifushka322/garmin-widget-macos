import Foundation
import Darwin

/// Host behavior tests: fake website, clock and preferences; private temporary files.
/// No WebKit instance, Keychain, account, network, widgets or login-item mutation.
private final class MemoryDefaults: UserDefaults {
    var values: [String: Any] = [:]
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func double(forKey key: String) -> Double { (values[key] as? NSNumber)?.doubleValue ?? 0 }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@MainActor
private final class TestClock {
    var moment = SyncPolicy.Moment(wallTime: Date(timeIntervalSince1970: 1_789_473_600), monotonicSeconds: 1000, bootID: "host-test")
    func advance(_ seconds: Double, wallAdjustment: Double = 0) {
        moment.wallTime.addTimeInterval(seconds + wallAdjustment)
        moment.monotonicSeconds += seconds
    }
}

@MainActor
private final class MockWeb: GarminWebTransport {
    var onConnectPageReady: (() -> Void)?
    var onSignInClosed: (() -> Void)?
    var onDiagnostic: ((BridgeDiagnostic) -> Void)?
    var prepareError: GarminWebError?
    var errors: [String: GarminWebError] = [:]
    var payloads: [String: Any] = ["profile": ["displayName": "fixture-user"], "devices": [["productDisplayName": "Fixture watch"]],
                                   "stats": ["totalSteps": 123], "sleep": ["dailySleepDTO": ["sleepTimeSeconds": 18000]]]
    var prepares = 0
    var batches = 0
    var opens = 0
    var disconnects = 0
    var holdDisconnect = false
    var disconnectWaiter: CheckedContinuation<Void, Never>?
    var calls: [String] = []
    var paths: [String] = []
    var onGet: ((String) -> Void)?
    var holdStage: String?
    var pending: CheckedContinuation<Void, Never>?
    func beginBatch() { batches += 1 }
    func openSignIn(title: String) { opens += 1 }
    func closeSignIn() {} // Programmatic orderOut does not emit the user's window-close callback.
    func prepare(forceReload: Bool) async throws { prepares += 1; if let prepareError { throw prepareError } }
    func get(path: String, stage: String) async throws -> Any {
        calls.append(stage); paths.append(path)
        onGet?(stage)
        if holdStage == stage {
            holdStage = nil
            await withCheckedContinuation { pending = $0 }
        }
        if let error = errors[stage] { throw error }
        return payloads[stage] ?? NSNull()
    }
    func release() { let current = pending; pending = nil; current?.resume() }
    func cancel() {} // A late response deliberately tests the host's generation checks.
    func disconnect() async {
        disconnects += 1
        if holdDisconnect { await withCheckedContinuation { disconnectWaiter = $0 } }
    }
    func finishDisconnect() { let current = disconnectWaiter; disconnectWaiter = nil; current?.resume() }
}

@MainActor
private final class Rig {
    let directory: URL
    let defaults = MemoryDefaults()
    let clock = TestClock()
    let web = MockWeb()
    let store: AppStore
    init(state: SyncPolicy.SessionState = .available, connected: Bool = true,
         checkpoint: SyncPolicy.Checkpoint? = nil, previous: GarminSnapshot? = nil,
         groups: GarminWebCache? = nil, widgetPublisher: ((WidgetData) throws -> Void)? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GarminDeskHostTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preferences = AppPreferences()
        var initial = checkpoint ?? .init(); if checkpoint == nil { initial.sessionState = state }
        try AppJSON.encoder.encode(preferences).write(to: directory.appendingPathComponent("preferences.json"))
        try AppJSON.encoder.encode(initial).write(to: directory.appendingPathComponent("sync-policy.json"))
        if let previous { try AppJSON.encoder.encode(previous).write(to: directory.appendingPathComponent("snapshot.json")) }
        if let groups { try AppJSON.encoder.encode(groups).write(to: directory.appendingPathComponent("metric-groups.json")) }
        defaults.values["GarminDeskWebConnected"] = connected
        let clock = self.clock
        store = AppStore(supportDirectory: directory, webSession: web, defaults: defaults,
                         clock: { clock.moment }, sourceTimeZone: { TimeZone(secondsFromGMT: 0)! },
                         automaticScheduling: false, writesWidgetData: widgetPublisher != nil,
                         widgetPublisher: widgetPublisher)
    }
    func checkpoint() throws -> SyncPolicy.Checkpoint {
        try AppJSON.decoder.decode(SyncPolicy.Checkpoint.self, from: Data(contentsOf: directory.appendingPathComponent("sync-policy.json")))
    }
    func clean() { store.cancelLogin(resumeAutomatic: false); web.release(); try? FileManager.default.removeItem(at: directory) }
}

@main @MainActor
struct AppStoreSyncTests {
    struct Failure: Error, CustomStringConvertible { var description: String }
    static var checks = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !value() { throw Failure(description: message) }
    }
    static func settled(_ store: AppStore) async throws {
        for _ in 0..<5000 { if !store.isSyncing { return }; await Task.yield() }
        throw Failure(description: "Mock sync did not settle")
    }
    private static func held(_ web: MockWeb) async throws {
        for _ in 0..<5000 { if web.pending != nil { return }; await Task.yield() }
        throw Failure(description: "Mock did not reach held endpoint")
    }

    static func testPolicyBeforeWebsite() async throws {
        var checkpoint = SyncPolicy.Checkpoint(); checkpoint.sessionState = .available
        let moment = TestClock().moment
        checkpoint.gate = .init(startedAt: moment, duration: 3600, reason: .rateLimit)
        let rig = try Rig(checkpoint: checkpoint); defer { rig.clean() }
        rig.store.preferences.summaryMetrics = ["weight", "hydration"]
        rig.store.sync(trigger: .automatic); rig.store.sync(trigger: .wake); rig.store.connectGarmin()
        try expect(rig.web.prepares == 0 && rig.web.calls.isEmpty && rig.web.opens == 0,
                   "A server pause must prevent prepare, profile reads and opening sign-in")
        try expect(rig.store.nextSyncAt == moment.wallTime.addingTimeInterval(3600), "Host should publish exact gate deadline")
        try expect(!rig.store.isSyncing, "Waiting for cadence must not set the spinner")
    }

    static func testBootstrapExpiration() async throws {
        let rig = try Rig(state: .unavailable); defer { rig.clean() }
        rig.web.prepareError = .signInRequired
        rig.store.sync(trigger: .automatic)
        await Task.yield(); try await settled(rig.store)
        try expect(try rig.checkpoint().sessionState == .expired, "An auth failure during bootstrap must persist expired state")
        try expect(rig.store.needsWebSignIn && !rig.store.hasSession, "Expired cookies must not be presented as connected")
        try expect(rig.store.lastErrorKey == "error.auth", "Bootstrap auth error must remain visible")
        rig.clock.advance(86400)
        rig.store.sync(trigger: .wake); rig.store.sync()
        try expect(rig.web.prepares == 1 && rig.store.nextSyncAt == nil, "Expired bootstrap must not become an automatic login loop")
        let restored = AppStore(supportDirectory: rig.directory, webSession: MockWeb(), defaults: rig.defaults,
                               clock: { rig.clock.moment }, automaticScheduling: false, writesWidgetData: false)
        try expect(restored.needsWebSignIn && !restored.hasSession, "Relaunch must restore the expired state before scheduling")
        restored.cancelLogin()
        rig.web.prepareError = nil
        rig.web.onConnectPageReady?()
        try await settled(rig.store)
        try expect(rig.store.hasSession && !rig.store.needsWebSignIn, "Explicit completed website sign-in may recover an expired session")
        try expect(try rig.checkpoint().sessionState == .available, "Verified website session must be persisted as available")
    }

    private static func initialStages(at date: Date) -> [String] {
        let day = SyncPolicy.sourceDay(for: date, timeZone: TimeZone(secondsFromGMT: 0)!)
        return ["profile", "stats", "body_battery", "sleep", "hrv", "readiness", "respiration",
                "vo2_max", "training", "devices", "activities"]
            + GarminWebAPI.calendarRequests(sourceDay: day).map { "planned_workouts." + $0.month }
    }

    static func testFixedWidgetsAndIndependentCadences() async throws {
        let rig = try Rig(); defer { rig.clean() }
        let first = initialStages(at: rig.clock.moment.wallTime)
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(rig.web.calls == first,
                   "A fresh installation must fetch every fixed widget's metric and calendar data without profile assignments")
        try expect(rig.web.calls.count == Set(rig.web.calls).count,
                   "Summary and dedicated widgets must share each endpoint request within a batch")
        try expect(!rig.web.calls.contains("weight") && !rig.web.calls.contains("hydration") && !rig.web.calls.contains("heart"),
                   "The fixed product must not fetch optional manual-entry data or unsupported live heart rate")
        try expect(rig.store.snapshot.metrics["steps"]?.value == 123, "Actual normalized values should reach the snapshot")
        try expect(rig.store.nextSyncAt == rig.clock.moment.wallTime.addingTimeInterval(900), "Completion must schedule a single next due refresh")
        rig.store.sync(trigger: .automatic); rig.store.sync(trigger: .wake)
        try expect(rig.web.prepares == 1, "Fresh automatic/wake refresh must do no website I/O")
        rig.clock.advance(900)
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(Array(rig.web.calls.dropFirst(first.count)) == ["stats", "body_battery", "activities"],
                   "Fast daily readings and activity history must refresh without repeating sleep, training, metadata, or calendar requests")
        let count = rig.web.calls.count
        rig.clock.advance(900)
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(Array(rig.web.calls.dropFirst(count)) == ["stats", "body_battery", "sleep", "hrv", "readiness", "respiration", "training", "activities"],
                   "Thirty-minute groups must refresh independently of hourly VO2 max and scheduled workouts")
        rig.clock.advance(86400)
        rig.store.sync(trigger: .wake); try await settled(rig.store)
        try expect(rig.web.calls.filter { $0 == "profile" }.count == 2, "Due account metadata must perform a real request")
        try expect(rig.web.calls.filter { $0 == "devices" }.count == 2, "Device metadata should refresh daily")
        try expect(try rig.checkpoint().successfulGroups[.profile]?.moment.wallTime == rig.clock.moment.wallTime,
                   "Account cadence stamp must reflect the actual account request")
    }

    static func testPresentationChangesAndRefreshCoalesce() async throws {
        let rig = try Rig(); defer { rig.clean() }
        rig.web.holdStage = "stats"
        rig.store.sync(trigger: .automatic); try await held(rig.web)
        rig.store.preferences.widgetAppearance = .dark
        rig.store.preferences.language = .de
        rig.store.sync(trigger: .wake); rig.store.sync()
        try expect(rig.web.prepares == 1, "Appearance edits and refresh clicks during a batch must join the current request")
        rig.web.release(); try await settled(rig.store)
        try expect(rig.web.calls == initialStages(at: rig.clock.moment.wallTime),
                   "Presentation changes must not restart or broaden the fixed data request")
        try expect(rig.store.nextSyncAt == rig.clock.moment.wallTime.addingTimeInterval(900),
                   "Presentation changes must preserve normal cadence after completion")
        let prepares = rig.web.prepares
        rig.store.preferences.appearance = .light
        rig.store.preferences.widgetAppearance = .colorful
        rig.store.preferences.language = .ja
        try expect(rig.web.prepares == prepares, "Language and appearance changes must not trigger website requests")
        let persisted = try AppJSON.decoder.decode(AppPreferences.self, from: Data(contentsOf: rig.directory.appendingPathComponent("preferences.json")))
        try expect(persisted.language == .ja && persisted.appearance == .light && persisted.widgetAppearance == .colorful,
                   "Presentation settings must persist without a data refresh")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: rig.directory.appendingPathComponent("preferences.json"))) as? [String: Any]
        try expect(object?["profiles"] == nil && object?["widgetProfileIDs"] == nil,
                   "The host's persisted preferences must not recreate removed user profiles")
    }

    static func testAvailableReadingsKeepRealZero() async throws {
        let rig = try Rig(); defer { rig.clean() }
        rig.web.payloads["stats"] = ["totalSteps": 0]
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        let day = WidgetSlot.day.profile(in: rig.store.preferences)
        let visible = WidgetMetricPolicy.selection(for: day, snapshot: rig.store.snapshot)
        try expect(visible.primary == "steps" && visible.secondary == ["sleepDuration"],
                   "A real zero is available while absent daily readings remain hidden")
        try expect(day.primaryMetric == "bodyBattery" && day.prefersAvailableMetrics,
                   "Choosing an available reading must not change the fixed recipe or disable availability")
        try expect(rig.store.trainingTimeline?.past.isEmpty == true && rig.store.trainingTimeline?.futureIssue == nil,
                   "Successful empty training responses produce a verified empty timeline, not invented activities")
    }

    static func testSportAndCalendarStayDistinct() async throws {
        let rig = try Rig(); defer { rig.clean() }
        rig.web.payloads["readiness"] = [["score": 73, "recoveryTime": 0]]
        rig.web.payloads["activities"] = [["activityId": 91, "activityName": "Fixture activity", "duration": 600]]
        let day = SyncPolicy.sourceDay(for: rig.clock.moment.wallTime, timeZone: TimeZone(secondsFromGMT: 0)!)
        let calendar = GarminWebAPI.calendarRequests(sourceDay: day)
        for request in calendar { rig.web.payloads["planned_workouts." + request.month] = ["calendarItems": []] }
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        let sport = WidgetSlot.sport.profile(in: rig.store.preferences)
        let training = WidgetSlot.training.profile(in: rig.store.preferences)
        try expect(sport.contentMode == .metrics && !sport.contentMode.includesTraining && sport.style == .sport,
                   "Sport is a metric view even when the shared snapshot contains activities")
        try expect(training.contentMode == .training && !training.contentMode.includesMetrics,
                   "Training remains a calendar, without an unrelated metric grid")
        try expect(!WidgetSlot.overview.includesTraining && !WidgetSlot.sport.includesTraining && WidgetSlot.training.includesTraining,
                   "Summary and Sport show metrics; the dedicated Training widget owns the calendar")
        let selection = WidgetMetricPolicy.selection(for: sport, snapshot: rig.store.snapshot)
        try expect(selection.primary == "trainingReadiness" && selection.secondary.contains("recoveryTime"),
                   "Sport must display readiness and a real zero recovery time")
        try expect(rig.store.snapshot.metrics["trainingReadiness"]?.value == 73 && rig.store.snapshot.metrics["recoveryTime"]?.value == 0,
                   "Sport readings must reach the same snapshot as calendar data")
        try expect(rig.store.trainingTimeline?.past.first?.title == "Fixture activity" && rig.store.trainingTimeline?.futureCoverageEnd == calendar.last?.lastDay,
                   "The dedicated Training widget receives actual history and explicitly verified empty calendar coverage")
    }

    static func testSummaryOptionalReadingsAndRemoval() async throws {
        let rig = try Rig(); defer { rig.clean() }
        rig.web.payloads["weight"] = ["dateWeightList": [["weight": 73400]]]
        rig.web.payloads["hydration"] = ["valueInML": 0]
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        let initialCount = rig.web.calls.count
        rig.store.preferences.summaryMetrics = ["hydration", "weight", "steps"]
        try await settled(rig.store)
        try expect(Array(rig.web.calls.dropFirst(initialCount)) == ["weight", "hydration"],
                   "Explicit Summary selections must request only their new optional groups while fixed widget caches remain fresh")
        let selection = WidgetMetricPolicy.summarySelection(preferences: rig.store.preferences, snapshot: rig.store.snapshot)
        try expect(selection.primary == "hydration" && selection.secondary == ["weight", "steps"],
                   "A selected zero hydration reading must remain the first Summary metric and preserve the selected order")
        try expect(rig.store.snapshot.metrics["weight"]?.value == 73.4 && rig.store.snapshot.metrics["hydration"]?.value == 0,
                   "Explicit optional readings must reach the shared snapshot with real normalized values")
        let count = rig.web.calls.count
        rig.store.preferences.summaryMetrics = ["steps", "weight", "hydration"]
        try expect(rig.web.calls.count == count, "Reordering the same chosen readings must not fetch any endpoint again")
        rig.store.preferences.summaryMetrics = ["steps"]
        try await settled(rig.store)
        let single = WidgetMetricPolicy.summarySelection(preferences: rig.store.preferences, snapshot: rig.store.snapshot)
        try expect(single.primary == "steps" && single.secondary.isEmpty,
                   "Removing a Summary reading must hide it even while its cached value remains available")
        rig.clock.advance(3600)
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        let later = Array(rig.web.calls.dropFirst(count))
        try expect(!later.contains("weight") && !later.contains("hydration"),
                   "Removed optional Summary groups must stop refreshing when their cadence becomes due")
        try expect(later.contains("sleep") && later.contains("readiness") && later.contains("activities")
                   && later.filter { $0.hasPrefix("planned_workouts.") }.count == 2,
                   "A one-metric Summary must not disable the dedicated Sleep, Sport, or Training data requests")
        let persisted = try AppJSON.decoder.decode(AppPreferences.self, from: Data(contentsOf: rig.directory.appendingPathComponent("preferences.json")))
        try expect(persisted.summaryMetrics == ["steps"], "The chosen Summary list must persist without restoring hidden readings")
    }

    static func testSummaryChangesDuringSyncCoalesce() async throws {
        let rig = try Rig(); defer { rig.clean() }
        rig.web.holdStage = "stats"
        rig.store.sync(trigger: .automatic); try await held(rig.web)
        rig.store.preferences.summaryMetrics = ["hydration", "steps"]
        rig.store.sync(trigger: .wake); rig.store.sync()
        try expect(rig.web.prepares == 1, "Adding a Summary group during sync must coalesce with the active batch")
        rig.web.release(); try await settled(rig.store)
        try expect(rig.web.calls == initialStages(at: rig.clock.moment.wallTime),
                   "The original batch must finish once without duplicate requests from a mid-sync selection change")
        try expect(rig.store.nextSyncAt == rig.clock.moment.wallTime,
                   "A newly selected Summary group must become due immediately after the active batch")
        let count = rig.web.calls.count
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(Array(rig.web.calls.dropFirst(count)) == ["hydration"],
                   "The follow-up must fetch only the newly selected Summary endpoint")
    }

    static func testProfileRemovalMigratesWithoutSigningOut() async throws {
        let rig = try Rig(); defer { rig.clean() }
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        let oldID = UUID().uuidString
        let old: [String: Any] = ["language": "fr", "appearance": "dark", "refreshMinutes": 30,
            "profiles": [["id": oldID, "name": "Old fixture", "metricIDs": ["weight"], "primaryMetric": "weight",
                          "style": "monochrome", "density": "compact", "contentMode": "mixed"]],
            "widgetProfileIDs": ["sport": oldID, "sleep": "missing"]]
        let preferenceURL = rig.directory.appendingPathComponent("preferences.json")
        try JSONSerialization.data(withJSONObject: old).write(to: preferenceURL)
        let checkpointURL = rig.directory.appendingPathComponent("sync-policy.json")
        let groupsURL = rig.directory.appendingPathComponent("metric-groups.json")
        let checkpointBefore = try Data(contentsOf: checkpointURL)
        let groupsBefore = try Data(contentsOf: groupsURL)
        let web = MockWeb()
        let restored = AppStore(supportDirectory: rig.directory, webSession: web, defaults: rig.defaults,
                                clock: { rig.clock.moment }, sourceTimeZone: { TimeZone(secondsFromGMT: 0)! },
                                automaticScheduling: false, writesWidgetData: false)
        defer { restored.cancelLogin(resumeAutomatic: false) }
        try expect(restored.hasSession && !restored.needsWebSignIn && web.prepares == 0,
                   "Removing profile preferences must not sign out a connected user or start migration network requests")
        try expect(restored.preferences.language == .fr && restored.preferences.refreshMinutes == 30 && restored.preferences.widgetAppearance == .dark,
                   "First launch must migrate independent settings and monochrome appearance")
        try expect(restored.preferences.summaryMetrics == AppPreferences.defaultSummaryMetrics,
                   "Old custom profiles must migrate to the new editable Summary defaults")
        try expect(restored.snapshot.metrics["steps"]?.value == 123 && restored.trainingTimeline == rig.store.trainingTimeline,
                   "Profile migration must keep cached measurements and calendar coverage")
        try expect(try Data(contentsOf: checkpointURL) == checkpointBefore && Data(contentsOf: groupsURL) == groupsBefore,
                   "Preference migration must not rewrite cadence, account ownership, or endpoint caches")
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: preferenceURL)) as! [String: Any]
        try expect(persisted["profiles"] == nil && persisted["widgetProfileIDs"] == nil && persisted["widgetAppearance"] as? String == "dark",
                   "First launch must finish migrating the preference file without retaining obsolete user profiles")
        restored.sync(trigger: .automatic)
        try expect(web.prepares == 0, "Migrating to fixed widgets must preserve already fresh group cadence")
    }

    static func testRateLimitAndClockRollback() async throws {
        let rig = try Rig(); defer { rig.clean() }
        rig.web.prepareError = .rateLimited(7200)
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(try rig.checkpoint().gate?.duration == 7200, "Server retry delay must survive bootstrap failure")
        try expect(rig.store.nextSyncAt == rig.clock.moment.wallTime.addingTimeInterval(7200), "Long Retry-After must drive the next wakeup")
        rig.clock.advance(7200, wallAdjustment: -10000)
        rig.web.prepareError = nil
        rig.store.sync(trigger: .wake); try await settled(rig.store)
        try expect(rig.web.prepares == 2, "A wall-clock rollback must not revive an elapsed continuous-clock server pause")
        try expect(rig.store.nextSyncAt == rig.clock.moment.wallTime.addingTimeInterval(900), "Compatibility deadline must not reappear after successful native sync")
    }

    static func testLegacyCooldownMigration() async throws {
        let rig = try Rig(); defer { rig.clean() }
        let deadline = rig.clock.moment.wallTime.addingTimeInterval(1800)
        rig.defaults.set(deadline.timeIntervalSince1970, forKey: "GarminDeskNextAllowedSync")
        let web = MockWeb()
        let restored = AppStore(supportDirectory: rig.directory, webSession: web, defaults: rig.defaults,
                                clock: { rig.clock.moment }, sourceTimeZone: { TimeZone(secondsFromGMT: 0)! },
                                automaticScheduling: false, writesWidgetData: false)
        defer { restored.cancelLogin(resumeAutomatic: false) }
        restored.sync(); restored.connectGarmin()
        try expect(web.prepares == 0 && web.opens == 0 && restored.nextSyncAt == deadline,
                   "Removing the legacy bridge must preserve its saved server pause before website I/O")
        rig.clock.advance(1800)
        restored.sync(trigger: .automatic); try await settled(restored)
        try expect(restored.snapshot.metrics["steps"]?.value == 123, "Native sync must resume once the migrated pause expires")
        try expect(rig.defaults.double(forKey: "GarminDeskNextAllowedSync") == 0,
                   "An elapsed migrated pause must not reappear after native sync succeeds")
    }

    static func testPartialAndEmptyDays() async throws {
        let rig = try Rig(); defer { rig.clean() }
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        rig.clock.advance(1800)
        rig.web.payloads["stats"] = ["totalSteps": 456]
        rig.web.payloads["sleep"] = ["unexpected": true]
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(rig.store.snapshot.metrics["steps"]?.value == 456 && rig.store.snapshot.metrics["sleepDuration"]?.value == 300,
                   "Partial response must commit successful groups and preserve same-day failed groups")
        try expect(rig.store.snapshot.warnings == ["schema_mismatch.sleep"], "Partial schema failures need visible provenance")
        try expect(rig.store.lastErrorKey == "error.partial", "Partial failure must not be reported as full success")
        try expect(rig.store.nextSyncAt == rig.clock.moment.wallTime.addingTimeInterval(60), "Only failed/missing groups should retry after bounded backoff")
        rig.clock.advance(86400)
        rig.web.payloads["stats"] = NSNull(); rig.web.payloads["sleep"] = NSNull()
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(rig.store.snapshot.metrics.isEmpty && !rig.store.snapshot.isDemo, "A new day with no data must clear yesterday's values")
        try expect(rig.store.snapshot.retainedMetrics["steps"]?.reading.value == 456,
                   "An empty new day keeps the last real step count separately from today's measurements")
        try expect(rig.store.displayValue("steps") != "—", "The user still sees the last known real reading")
        try expect(rig.store.snapshot.retainedMetrics["steps"]?.sourceDate != rig.store.snapshot.sourceDate,
                   "Retained readings must not inherit the new day's date")
        try expect(rig.store.snapshot.sourceDate == SyncPolicy.sourceDay(for: rig.clock.moment.wallTime, timeZone: TimeZone(secondsFromGMT: 0)!),
                   "Empty day must carry the requested source date")
    }

    static func testCancellationIgnoresLateResponses() async throws {
        let rig = try Rig(); defer { rig.clean() }
        rig.web.holdStage = "profile"
        rig.store.sync(trigger: .automatic); try await held(rig.web)
        rig.store.cancelLogin()
        let initialDemo = rig.store.snapshot.isDemo
        rig.web.release()
        for _ in 0..<100 { await Task.yield() }
        try expect(!rig.store.isSyncing && rig.store.snapshot.isDemo == initialDemo, "Late cancelled profile response must not change snapshot or connection state")
        try expect(rig.web.calls == ["profile"] && rig.store.nextSyncAt == rig.clock.moment.wallTime.addingTimeInterval(900), "Cancel must prevent immediate retries while preserving later unattended sync")
        rig.store.sync(trigger: .wake); try await settled(rig.store)
        try expect(rig.store.snapshot.metrics["steps"]?.value == 123, "Cancelled request must not leave a permanent in-flight lock")
    }

    static func testCacheAndCheckpointConsistency() async throws {
        let time = TestClock().moment
        let day = SyncPolicy.sourceDay(for: time.wallTime, timeZone: TimeZone(secondsFromGMT: 0)!)
        var checkpoint = SyncPolicy.Checkpoint(); checkpoint.sessionState = .available
        for group in [SyncPolicy.Group.profile, .stats, .devices] {
            checkpoint.successfulGroups[group] = .init(moment: time, sourceDay: day)
        }
        let rig = try Rig(checkpoint: checkpoint, groups: GarminWebCache(accountDisplayName: "fixture-user")); defer { rig.clean() }
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(rig.web.calls == initialStages(at: time.wallTime).filter { $0 != "devices" }, "Missing group caches must invalidate freshness without re-fetching valid device metadata")
        let freshWeb = MockWeb()
        let restored = AppStore(supportDirectory: rig.directory, webSession: freshWeb, defaults: rig.defaults,
                                clock: { rig.clock.moment }, sourceTimeZone: { TimeZone(secondsFromGMT: 0)! },
                                automaticScheduling: false, writesWidgetData: false)
        restored.sync(trigger: .automatic)
        try expect(freshWeb.prepares == 0, "A relaunch with fresh cached measurements must not bootstrap the website before cadence")
        restored.cancelLogin(resumeAutomatic: false)

        let failure = try Rig(state: .unavailable); defer { failure.clean() }
        try FileManager.default.createDirectory(at: failure.directory.appendingPathComponent("metric-groups.json"), withIntermediateDirectories: true)
        failure.web.prepareError = .signInRequired
        failure.store.sync(trigger: .automatic); try await settled(failure.store)
        try expect(try failure.checkpoint().sessionState == .expired, "Cache write failure must not prevent persisting rejected authentication")
        try expect(failure.store.lastErrorKey == "error.auth", "Storage failure must not hide the actionable auth error")
    }

    static func testDisconnectCleanupOrdering() async throws {
        let rig = try Rig(); defer { rig.clean(); rig.web.finishDisconnect() }
        rig.web.holdStage = "profile"; rig.web.holdDisconnect = true
        rig.store.sync(trigger: .automatic); try await held(rig.web)
        rig.store.disconnect()
        rig.store.connectGarmin(); rig.store.disconnect()
        for _ in 0..<100 { await Task.yield() }
        try expect(rig.web.disconnects == 1 && rig.web.opens == 0, "Repeated disconnect and reconnect must wait for the same cookie cleanup")
        try expect(!rig.store.hasSession && !rig.defaults.bool(forKey: "GarminDeskWebConnected"), "Disconnect must clear connection before asynchronous cleanup")
        try expect(try rig.checkpoint().sessionState == .unavailable, "Disconnect must persist the unavailable session")
        rig.web.release()
        for _ in 0..<100 { await Task.yield() }
        try expect(!rig.store.snapshot.isDemo && !rig.store.snapshot.hasMeasurements && !rig.store.hasSession, "Late response from the disconnected account must not restore its values")
        rig.web.finishDisconnect()
        for _ in 0..<100 { await Task.yield() }
        rig.store.connectGarmin()
        try expect(rig.web.opens == 1, "A fresh sign-in should be allowed only after old cookies are erased")
    }

    static func testCacheDateBoundary() throws {
        let date = TestClock().moment.wallTime
        let yesterday = GarminSnapshot(fetchedAt: date, sourceDate: "2026-09-14", devices: [], metrics: ["steps": .init(value: 999)])
        let empty = GarminWebCache().snapshot(sourceDay: "2026-09-15", fallback: yesterday, warnings: ["network.stats"])
        try expect(empty.metrics.isEmpty && empty.sourceDate == "2026-09-15", "Cache must not attach yesterday's metrics to today's request")
        try expect(empty.retainedMetrics["steps"]?.sourceDate == "2026-09-14", "Keep the old reading's original day for the UI")
        var cache = GarminWebCache()
        cache.groups["stats"] = .init(sourceDay: "2026-09-15", retrievedAt: date, metrics: [:])
        var earlier = yesterday; earlier.sourceDate = "2026-09-15"
        try expect(cache.snapshot(sourceDay: "2026-09-15", fallback: earlier, warnings: []).metrics.isEmpty,
                   "Explicit empty same-day response must replace earlier values")
        try expect(GarminWebCache().snapshot(sourceDay: "2026-09-15", fallback: earlier, warnings: ["network.stats"]).warnings == ["network.stats"],
                   "Fallback retained after total failure must still expose the current failure")
    }

    static func testTrainingAlwaysAvailableAndCadence() async throws {
        let rig = try Rig(); defer { rig.clean() }
        let day = SyncPolicy.sourceDay(for: rig.clock.moment.wallTime, timeZone: TimeZone(secondsFromGMT: 0)!)
        let requests = GarminWebAPI.calendarRequests(sourceDay: day)
        rig.web.payloads["activities"] = [["activityId": 42, "activityName": "Synthetic run", "duration": 1800, "distance": 5000]]
        for (index, request) in requests.enumerated() {
            rig.web.payloads["planned_workouts." + request.month] = ["calendarItems": [["itemType": "workout", "id": index + 10,
                "workoutId": 7, "date": request.lastDay, "title": "Synthetic plan"]]]
        }
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(rig.web.calls.suffix(3) == ["activities"] + requests.map { "planned_workouts." + $0.month }, "The fixed Training widget must fetch the activity list and exactly two calendar months")
        try expect(rig.store.trainingTimeline?.past.first?.distanceKM == 5, "Training normalization must reach published state")
        try expect(rig.store.trainingTimeline?.upcoming.count == 2, "Repeated workout templates on different dates remain separate appointments")
        try expect(rig.store.trainingTimeline?.futureCoverageEnd == requests.last?.lastDay, "Calendar coverage must end at the verified month boundary")
        try expect(rig.store.trainingTimeline?.pastUpdatedAt == rig.clock.moment.wallTime && rig.store.trainingTimeline?.futureIssue == nil, "Successful training sections retain explicit retrieval timestamps")
        rig.clock.advance(900)
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(rig.web.calls.filter { $0 == "activities" }.count == 2, "Activities follow the selected refresh cadence")
        try expect(rig.web.calls.filter { $0.hasPrefix("planned_workouts.") }.count == 2, "Calendar must not follow the faster activity cadence")
        let persisted = try AppJSON.decoder.decode(GarminPrivateSnapshot.self, from: Data(contentsOf: rig.directory.appendingPathComponent("snapshot.json"))).snapshot
        try expect(persisted.trainingTimeline == rig.store.trainingTimeline, "Training data must survive the same private snapshot contract used by widgets")
    }

    static func testTrainingPartialAndRateLimit() async throws {
        let rig = try Rig(); defer { rig.clean() }
        let day = SyncPolicy.sourceDay(for: rig.clock.moment.wallTime, timeZone: TimeZone(secondsFromGMT: 0)!)
        let requests = GarminWebAPI.calendarRequests(sourceDay: day)
        let firstStage = "planned_workouts." + requests[0].month
        let secondStage = "planned_workouts." + requests[1].month
        rig.web.payloads["activities"] = [["activityId": 9, "activityName": "Fixture"]]
        rig.web.payloads[firstStage] = ["calendarItems": [["itemType": "workout", "id": 8, "date": requests[0].lastDay]]]
        rig.web.errors[secondStage] = .rateLimited(3600)
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(rig.web.calls.contains("stats") && rig.web.calls.contains("body_battery"), "Metric widgets must retain their successful readings even when a later calendar page fails")
        try expect(rig.store.trainingTimeline?.past.count == 1 && rig.store.trainingTimeline?.upcoming.count == 1, "A second-month failure must preserve independently successful history and first month")
        try expect(rig.store.trainingTimeline?.futureCoverageEnd == requests[0].lastDay, "Partial calendar cannot claim coverage of a failed month")
        try expect(rig.store.trainingTimeline?.futureIssue == "rate_limit", "Partial training must expose rate-limit provenance")
        try expect(try rig.checkpoint().successfulGroups[.plannedWorkouts] == nil, "Two-month cadence cannot be fresh after one successful page")
        try expect(try rig.checkpoint().successfulGroups[.activities] != nil, "Successful history keeps its independent cadence after calendar failure")
        let count = rig.web.calls.count
        rig.store.sync(); rig.store.sync(trigger: .wake)
        try expect(rig.web.calls.count == count, "Rate limit stops training refresh without a fallback")
        rig.clock.advance(3600)
        rig.web.errors[secondStage] = nil
        rig.web.payloads[firstStage] = ["unexpected": true]
        rig.web.payloads[secondStage] = ["calendarItems": []]
        rig.web.payloads["activities"] = ["unexpected": true]
        let oldTime = rig.store.trainingTimeline?.pastUpdatedAt
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(rig.store.trainingTimeline?.past.count == 1 && rig.store.trainingTimeline?.pastUpdatedAt == oldTime,
                   "Malformed history preserves last-known records and their original age")
        try expect(rig.store.trainingTimeline?.pastIssue == "schema_mismatch", "Retained history must identify why it is not fresh")
        try expect(rig.store.trainingTimeline?.upcoming.count == 1 && rig.store.trainingTimeline?.futureCoveredMonths?.count == 2,
                   "A valid empty next month adds coverage without deleting another month's cached appointment")
        rig.clock.advance(60)
        rig.web.payloads["activities"] = []
        rig.web.payloads[firstStage] = ["calendarItems": []]
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(rig.store.trainingTimeline?.past.isEmpty == true && rig.store.trainingTimeline?.upcoming.isEmpty == true,
                   "Valid empty activity and calendar responses clear old records")
        try expect(rig.store.trainingTimeline?.pastIssue == nil && rig.store.trainingTimeline?.futureIssue == nil,
                   "A successful empty refresh clears previous section errors")
    }

    static func testTrainingFirstPageRateLimitStops() async throws {
        let rig = try Rig(); defer { rig.clean() }
        let day = SyncPolicy.sourceDay(for: rig.clock.moment.wallTime, timeZone: TimeZone(secondsFromGMT: 0)!)
        let requests = GarminWebAPI.calendarRequests(sourceDay: day)
        rig.web.errors["planned_workouts." + requests[0].month] = .rateLimited(nil)
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(!rig.web.calls.contains("planned_workouts." + requests[1].month), "A 429 on the first calendar page must prevent reading the second page")
        try expect(rig.store.trainingTimeline?.futureCoverage == .unavailable, "Unavailable future data cannot claim an empty published plan")
    }

    static func testTransientEndpointDoesNotStarveOtherGroups() async throws {
        let rig = try Rig(); defer { rig.clean() }
        let now = rig.clock.moment.wallTime
        rig.web.errors["stats"] = .network
        rig.web.payloads["body_battery"] = [["bodyBatteryValuesArray": [[now.addingTimeInterval(-180).timeIntervalSince1970 * 1000, 70.0]]]]
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(rig.store.snapshot.metrics["bodyBattery"]?.value == 70 && rig.store.snapshot.metrics["sleepDuration"]?.value == 300,
                   "One failed endpoint cannot starve independent Garmin groups")
        let checkpoint = try rig.checkpoint()
        try expect(checkpoint.successfulGroups[.stats] == nil && checkpoint.successfulGroups[.bodyBattery] != nil && checkpoint.successfulGroups[.sleep] != nil,
                   "Only successful groups earn freshness")
        try expect(rig.store.nextSyncAt == now.addingTimeInterval(60), "Partial transient failure keeps bounded retry gate")
        rig.web.calls = []; rig.web.errors["stats"] = nil; rig.clock.advance(60)
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(rig.web.calls == ["stats"] && rig.store.snapshot.metrics["steps"]?.value == 123,
                   "Retry fetches only failed group; healthy readings keep their cadence")
    }

    static func main() async {
        do {
            try await testTransientEndpointDoesNotStarveOtherGroups()
            try await testBoundedBatchAndIncrementalProgress()
            try await testSameAccountVerificationPreservesReadings()
            try await testInteractiveCloseCancelsVerification()
            try testIndependentCacheWriteRecovery()
            try await testWidgetPublicationCount()
            try await testTransientCalendarMonthDoesNotStarveNextMonth()
            try await testWrongDayPayloadCannotBecomeCurrent()
            try await testBodyBatteryRefreshAndRegression()
            try await testEmptyUnchangedAndRecovery()
            try await testAccountOwnershipAcrossRestart()
            try await testPrivateSnapshotOwnerMismatchAndFailedWrite()
            try await testPolicyBeforeWebsite()
            try await testBootstrapExpiration()
            try await testFixedWidgetsAndIndependentCadences()
            try await testPresentationChangesAndRefreshCoalesce()
            try await testAvailableReadingsKeepRealZero()
            try await testSportAndCalendarStayDistinct()
            try await testSummaryOptionalReadingsAndRemoval()
            try await testSummaryChangesDuringSyncCoalesce()
            try await testProfileRemovalMigratesWithoutSigningOut()
            try await testRateLimitAndClockRollback()
            try await testLegacyCooldownMigration()
            try await testPartialAndEmptyDays()
            try await testCancellationIgnoresLateResponses()
            try await testCacheAndCheckpointConsistency()
            try await testDisconnectCleanupOrdering()
            try testCacheDateBoundary()
            try await testTrainingAlwaysAvailableAndCadence()
            try await testTrainingPartialAndRateLimit()
            try await testTrainingFirstPageRateLimitStops()
            print("PASS: \(checks) host lifecycle and cache checks")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    static func testAccountOwnershipAcrossRestart() async throws {
        let now = TestClock().moment.wallTime
        let day = SyncPolicy.sourceDay(for: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        for owner in [nil, "previous-account", "fixture-user"] as [String?] {
            var cache = GarminWebCache(accountDisplayName: owner)
            cache.groups["sleep"] = .init(sourceDay: day, retrievedAt: now.addingTimeInterval(-7200), metrics: ["sleepDuration": .init(value: 999)])
            let previous = cache.snapshot(sourceDay: day, warnings: [])
            let rig = try Rig(previous: previous, groups: cache)
            defer { rig.clean() }
            rig.web.payloads["sleep"] = ["unexpected": true]
            rig.store.sync(trigger: .automatic); try await settled(rig.store)
            try expect(rig.store.snapshot.metrics["steps"]?.value == 123, "New account's valid data is committed")
            try expect((rig.store.snapshot.metrics["sleepDuration"] != nil) == (owner == "fixture-user"), "Partial sync must retain cached measurements only for the verified owner")
            try expect((rig.store.snapshot.visibleReading("sleepDuration") != nil) == (owner == "fixture-user"), "Last-known fallback must also be isolated by account")
            let persisted = try AppJSON.decoder.decode(GarminWebCache.self, from: Data(contentsOf: rig.directory.appendingPathComponent("metric-groups.json")))
            try expect(persisted.accountDisplayName == "fixture-user", "Cache ownership survives process restart")
        }
        let rig = try Rig(); defer { rig.clean() }
        try expect(!rig.store.snapshot.isDemo && rig.store.snapshot.metrics.isEmpty, "A connected installation with missing cache cannot show invented demo measurements")
    }

    static func testPrivateSnapshotOwnerMismatchAndFailedWrite() async throws {
        let now = TestClock().moment.wallTime
        let day = SyncPolicy.sourceDay(for: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        var previous = GarminSnapshot(fetchedAt: now, sourceDate: day, devices: [],
                                      metrics: ["sleepDuration": .init(value: 999)])
        previous.retainedMetrics["hrv"] = .init(reading: .init(value: 888), sourceDate: "2026-09-14", retrievedAt: now, changedAt: now)
        let oldBytes = try PrivateSnapshotStore.encode(previous, accountDisplayName: "previous-account")
        var currentCache = GarminWebCache(accountDisplayName: "fixture-user")
        currentCache.groups["stats"] = .init(sourceDay: day, retrievedAt: now, metrics: ["steps": .init(value: 42)])

        try expect(!PrivateSnapshotStore.restore(oldBytes, cache: currentCache, sourceDay: day).hasMeasurements,
                   "Conflicting private owners must fail closed because either file could be the newer successful write")
        for saved in [try AppJSON.encoder.encode(previous), Data("invalid".utf8)] {
            let restored = PrivateSnapshotStore.restore(saved, cache: currentCache, sourceDay: day)
            try expect(restored.metrics["steps"]?.value == 42, "Legacy/damaged snapshot must recover verified group readings")
            try expect(restored.visibleReading("sleepDuration") == nil && restored.visibleReading("hrv") == nil,
                       "Unowned or differently owned current and retained readings must never enter fallback")
        }
        let matchingBytes = try PrivateSnapshotStore.encode(previous, accountDisplayName: "fixture-user")
        let matching = PrivateSnapshotStore.restore(matchingBytes, cache: currentCache, sourceDay: day)
        try expect(matching.visibleReading("sleepDuration")?.value == 999 && matching.visibleReading("hrv")?.value == 888,
                   "Matching ownership must preserve current and last-known provenance")
        try expect(!PrivateSnapshotStore.restore(matchingBytes, cache: .init(), sourceDay: day).hasMeasurements,
                   "A snapshot cannot establish ownership when the group cache is missing")

        let rig = try Rig(groups: GarminWebCache(accountDisplayName: "previous-account")); defer { rig.clean() }
        let snapshotURL = rig.directory.appendingPathComponent("snapshot.json")
        // An occupied directory deterministically fails the snapshot write while
        // metric-groups.json remains writable. Restoring old bytes afterwards
        // models an interrupted/denied replacement that left account A on disk.
        try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: false)
        rig.web.payloads["sleep"] = ["unexpected": true]
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        let cache = try AppJSON.decoder.decode(GarminWebCache.self, from: Data(contentsOf: rig.directory.appendingPathComponent("metric-groups.json")))
        try expect(cache.accountDisplayName == "fixture-user", "A separately successful cache write must persist the newly verified owner")
        var blockedTargetIsDirectory: ObjCBool = false
        try expect(FileManager.default.fileExists(atPath: snapshotURL.path, isDirectory: &blockedTargetIsDirectory) && blockedTargetIsDirectory.boolValue,
                   "The fixture must prove snapshot replacement failed while the group write succeeded")
        try FileManager.default.removeItem(at: snapshotURL)
        try oldBytes.write(to: snapshotURL)
        let web = MockWeb()
        web.payloads["sleep"] = ["unexpected": true]
        let reopened = AppStore(supportDirectory: rig.directory, webSession: web, defaults: rig.defaults,
                                clock: { rig.clock.moment }, sourceTimeZone: { TimeZone(secondsFromGMT: 0)! },
                                automaticScheduling: false, writesWidgetData: false)
        defer { reopened.cancelLogin(resumeAutomatic: false) }
        try expect(reopened.snapshot.visibleReading("sleepDuration") == nil && reopened.snapshot.visibleReading("hrv") == nil,
                   "Relaunch after a lost snapshot write must reject the previous account before any website request")
        try expect(!reopened.snapshot.hasMeasurements, "Conflicting files must not guess which account owns the current session")
        rig.clock.advance(60)
        web.prepareError = .network
        reopened.sync(trigger: .manual); try await settled(reopened)
        try expect(web.prepares == 1 && !reopened.snapshot.hasMeasurements,
                   "A failure before profile verification must not republish either side of an owner conflict")
        web.prepareError = nil
        rig.clock.advance(1800)
        reopened.sync(trigger: .manual); try await settled(reopened)
        try expect(reopened.snapshot.visibleReading("sleepDuration") == nil && reopened.snapshot.visibleReading("hrv") == nil,
                   "A partial new-account refresh must not resurrect the rejected old snapshot")
        try expect(reopened.snapshot.metrics["steps"]?.value == 123, "Profile verification must restore the new account's valid groups")
        let persisted = try AppJSON.decoder.decode(GarminPrivateSnapshot.self, from: Data(contentsOf: snapshotURL))
        try expect(persisted.accountDisplayName == "fixture-user", "The next successful private snapshot write must carry its owner")
        let widgetBytes = try AppJSON.encoder.encode(WidgetData(preferences: reopened.preferences, snapshot: reopened.snapshot, isConnected: true))
        let widgetText = String(decoding: widgetBytes, as: UTF8.self)
        try expect(!widgetText.contains("accountDisplayName") && !widgetText.contains("fixture-user") && !widgetText.contains("previous-account"),
                   "Private snapshot ownership must never be serialized into the widget payload")
    }


    static func testBoundedBatchAndIncrementalProgress() async throws {
        let slow = try Rig(); defer { slow.clean() }
        slow.web.errors["stats"] = .network
        slow.web.onGet = { _ in slow.clock.advance(30, wallAdjustment: -30) }
        slow.store.sync(trigger: .automatic); try await settled(slow.store)
        try expect(slow.web.calls == ["profile", "stats", "body_battery"],
                   "Continuous budget stops a batch after 90 seconds even when wall time does not move")
        try expect(slow.store.nextSyncAt == slow.clock.moment.wallTime,
                   "Unattempted groups remain due immediately without a global error gate")
        let count = slow.web.calls.count
        slow.store.sync(trigger: .automatic); try await settled(slow.store)
        let next = Array(slow.web.calls.dropFirst(count))
        try expect(next.first == "sleep" && !next.contains("stats"),
                   "Budget follow-up progresses to unattempted groups while failed stats respects its own retry gate")
        try expect(slow.store.snapshot.metrics["sleepDuration"]?.value == 300,
                   "A bad early endpoint cannot hold sleep indefinitely")

        let staged = try Rig(); defer { staged.clean() }
        let now = staged.clock.moment.wallTime
        staged.web.payloads["body_battery"] = [["bodyBatteryValuesArray": [[now.timeIntervalSince1970 * 1000, 72.0]]]]
        staged.web.onGet = { stage in if stage == "body_battery" { staged.clock.advance(11) } }
        staged.web.holdStage = "sleep"
        staged.store.sync(trigger: .automatic); try await held(staged.web)
        try expect(staged.store.isSyncing && staged.store.snapshot.metrics["bodyBattery"]?.value == 72,
                   "A slow batch publishes finished Body Battery before a later endpoint completes")
        staged.web.release(); try await settled(staged.store)
    }

    static func testSameAccountVerificationPreservesReadings() async throws {
        let rig = try Rig(); defer { rig.clean() }
        rig.store.sync(); try await settled(rig.store)
        rig.web.payloads["sleep"] = NSNull()
        rig.clock.advance(60)
        rig.web.onConnectPageReady?(); try await settled(rig.store)
        try expect(rig.store.snapshot.metrics["sleepDuration"] == nil &&
                   rig.store.snapshot.retainedMetrics["sleepDuration"]?.reading.value == 300,
                   "Reauthentication to the verified same owner preserves last known readings after valid absence")
        rig.web.payloads["profile"] = ["displayName": "different-fixture-owner"]
        rig.clock.advance(60)
        rig.web.onConnectPageReady?(); try await settled(rig.store)
        try expect(rig.store.snapshot.visibleReading("sleepDuration") == nil,
                   "A different verified owner still clears current and retained data")
    }

    static func testInteractiveCloseCancelsVerification() async throws {
        let rig = try Rig(); defer { rig.clean() }
        rig.web.holdStage = "profile"
        rig.store.connectGarmin()
        rig.web.onConnectPageReady?(); try await held(rig.web)
        rig.web.onSignInClosed?()
        try expect(!rig.store.isSyncing, "Closing the sign-in window cancels the waiting verification")
        rig.web.release()
        for _ in 0..<100 { await Task.yield() }
        try expect(rig.store.snapshot.metrics.isEmpty && rig.web.calls == ["profile"],
                   "A late verification reply cannot restart hidden requests after interactive close")
    }

    static func testIndependentCacheWriteRecovery() throws {
        let now = TestClock().moment.wallTime
        let day = SyncPolicy.sourceDay(for: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        var old = GarminWebCache(accountDisplayName: "fixture-user")
        old.groups["stats"] = .init(sourceDay: day, retrievedAt: now, metrics: ["steps": .init(value: 100)])
        old.groups["sleep"] = .init(sourceDay: day, retrievedAt: now, metrics: ["sleepDuration": .init(value: 300)])
        let oldSnapshot = old.snapshot(sourceDay: day, warnings: [])
        let oldBytes = try PrivateSnapshotStore.encode(oldSnapshot, accountDisplayName: "fixture-user")
        var current = old
        current.groups["stats"] = .init(sourceDay: day, retrievedAt: now.addingTimeInterval(60), metrics: ["steps": .init(value: 200)])
        let currentSnapshot = current.snapshot(sourceDay: day, fallback: oldSnapshot, warnings: [])
        let currentBytes = try PrivateSnapshotStore.encode(currentSnapshot, accountDisplayName: "fixture-user")
        try expect(PrivateSnapshotStore.restore(oldBytes, cache: current, sourceDay: day).metrics["steps"]?.value == 200,
                   "Newer owned groups repair an older snapshot after snapshot write failure")
        let restored = PrivateSnapshotStore.restore(currentBytes, cache: old, sourceDay: day)
        try expect(restored.metrics["steps"]?.value == 200, "Newer snapshot survives an older group file after group write failure")
        let restoredCache = PrivateSnapshotStore.restoreCache(currentBytes, cache: old, sourceDay: day)
        try expect(restoredCache.snapshot(sourceDay: day, fallback: restored, warnings: ["network.stats"]).metrics["steps"]?.value == 200,
                   "The next failed request cannot republish a group rolled back during restore")
        var mixed = old
        mixed.groups["sleep"] = .init(sourceDay: day, retrievedAt: now.addingTimeInterval(120), metrics: ["sleepDuration": .init(value: 500)])
        let reconciled = PrivateSnapshotStore.restore(currentBytes, cache: mixed, sourceDay: day)
        try expect(reconciled.metrics["steps"]?.value == 200 && reconciled.metrics["sleepDuration"]?.value == 500,
                   "Recovery compares each group independently instead of trusting either whole file")
        current.groups["stats"] = .init(sourceDay: day, retrievedAt: now.addingTimeInterval(180), metrics: [:])
        let absent = PrivateSnapshotStore.restore(currentBytes, cache: current, sourceDay: day)
        try expect(absent.metrics["steps"] == nil && absent.retainedMetrics["steps"]?.reading.value == 200,
                   "A newer explicit absence keeps only the previous real reading as retained")
    }

    static func testWidgetPublicationCount() async throws {
        var publications: [WidgetData] = []
        let rig = try Rig(widgetPublisher: { publications.append($0) }); defer { rig.clean() }
        rig.store.sync(); try await settled(rig.store)
        publications = []
        rig.clock.advance(60)
        rig.web.payloads["stats"] = ["totalSteps": 456]
        rig.store.sync(); try await settled(rig.store)
        try expect(publications.count == 1 && publications[0].snapshot.metrics["steps"]?.value == 456,
                   "A fast connected sync writes one final widget snapshot without an old-value reload")
        publications = []
        rig.store.hasSession = true
        try expect(publications.isEmpty, "Assigning the same connection flag publishes nothing")
        rig.store.disconnect()
        try expect(publications.last?.isConnected == false && publications.last?.snapshot.hasMeasurements == false,
                   "The last disconnect publication is empty and disconnected")
    }

    static func testTransientCalendarMonthDoesNotStarveNextMonth() async throws {
        let rig = try Rig(); defer { rig.clean() }
        let day = SyncPolicy.sourceDay(for: rig.clock.moment.wallTime, timeZone: TimeZone(secondsFromGMT: 0)!)
        let months = GarminWebAPI.calendarRequests(sourceDay: day)
        rig.web.errors["planned_workouts." + months[0].month] = .network
        rig.web.payloads["planned_workouts." + months[1].month] = ["calendarItems": [Any]()]
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(rig.store.trainingTimeline?.futureCoveredMonths == [months[1].month] &&
                   rig.store.trainingTimeline?.futureIssue == "network",
                   "One failed calendar month does not discard the next month's verified coverage")
        try expect(try rig.checkpoint().successfulGroups[.plannedWorkouts] == nil,
                   "Partial calendar is not marked fully fresh")
    }


    static func testWrongDayPayloadCannotBecomeCurrent() async throws {
        let rig = try Rig(); defer { rig.clean() }
        let firstDay = SyncPolicy.sourceDay(for: rig.clock.moment.wallTime, timeZone: TimeZone(secondsFromGMT: 0)!)
        rig.store.sync(); try await settled(rig.store)
        rig.clock.advance(86400)
        let currentDay = SyncPolicy.sourceDay(for: rig.clock.moment.wallTime, timeZone: TimeZone(secondsFromGMT: 0)!)
        rig.web.payloads["stats"] = ["calendarDate": firstDay, "totalSteps": 999]
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(rig.store.snapshot.sourceDate == currentDay && rig.store.snapshot.metrics["steps"] == nil,
                   "Yesterday's explicit day label cannot become today's fresh step total")
        try expect(rig.store.snapshot.retainedMetrics["steps"]?.reading.value == 123 &&
                   rig.store.snapshot.retainedMetrics["steps"]?.sourceDate == firstDay,
                   "A wrong-day reply preserves the original reading and day as retained")
        try expect(try rig.checkpoint().successfulGroups[.stats]?.sourceDay == firstDay,
                   "A wrong-day payload cannot earn current-day freshness")
    }

    static func testBodyBatteryRefreshAndRegression() async throws {
        let rig = try Rig(); defer { rig.clean() }
        let now = rig.clock.moment.wallTime
        func payload(_ offset: TimeInterval, _ value: Double) -> [[String: Any]] {
            [["bodyBatteryValuesArray": [[now.addingTimeInterval(offset).timeIntervalSince1970 * 1000, value]]]]
        }
        rig.web.payloads["body_battery"] = payload(-180, 70)
        rig.store.sync(); try await settled(rig.store)
        try expect(rig.store.snapshot.metrics["bodyBattery"] == .init(value: 70, measuredAt: now.addingTimeInterval(-180)),
                   "Body Battery retains actual sample time after successful sync")
        rig.clock.advance(60)
        rig.web.payloads["body_battery"] = payload(-600, 80)
        rig.store.sync(); try await settled(rig.store)
        try expect(rig.store.snapshot.metrics["bodyBattery"]?.value == 70,
                   "An older report received later must not roll Body Battery backwards")
        rig.clock.advance(60)
        rig.web.payloads["body_battery"] = payload(60, 65)
        rig.store.sync(); try await settled(rig.store)
        try expect(rig.store.snapshot.metrics["bodyBattery"] == .init(value: 65, measuredAt: now.addingTimeInterval(60)),
                   "A later actual sample replaces the old Body Battery")
        rig.clock.advance(60)
        rig.web.payloads["body_battery"] = NSNull()
        rig.web.payloads["stats"] = ["totalSteps": 123, "bodyBatteryMostRecentValue": 63]
        rig.store.sync(); try await settled(rig.store)
        try expect(rig.store.snapshot.metrics["bodyBattery"] == .init(value: 63) && rig.store.snapshot.bodyBatterySourceGroup == "stats",
                   "Summary supplies latest Body Battery if daily report is empty without inventing its sample time")
        try expect(rig.store.snapshot.bodyBatteryProjection == nil,
                   "An undated summary cannot inherit the previous series trend")
    }

    static func testEmptyUnchangedAndRecovery() async throws {
        let firstInstall = try Rig(connected: false); defer { firstInstall.clean() }
        try expect(!firstInstall.store.snapshot.isDemo && !firstInstall.store.snapshot.hasMeasurements,
                   "First launch has no invented values")
        let legacyDemo = try Rig(previous: .demo); defer { legacyDemo.clean() }
        try expect(!legacyDemo.store.snapshot.isDemo && !legacyDemo.store.snapshot.hasMeasurements,
                   "A historical cached demo must never become live account readings on relaunch")
        let gallery = WidgetPreviewData.make(preferences: AppPreferences(), at: firstInstall.clock.moment.wallTime)
        let savedGallery = try Rig(previous: gallery.snapshot); defer { savedGallery.clean() }
        try expect(!savedGallery.store.snapshot.isDemo && !savedGallery.store.snapshot.hasMeasurements && savedGallery.store.trainingTimeline == nil,
                   "Even accidentally persisted gallery examples must be cleared from live readings and calendar state")
        let rig = try Rig(); defer { rig.clean() }
        rig.store.sync(); try await settled(rig.store)
        let original = rig.store.snapshot
        try expect(!original.hasUnchangedMeasurements, "First real response introduces data")
        rig.clock.advance(60)
        rig.store.sync(); try await settled(rig.store)
        try expect(rig.store.snapshot.hasUnchangedMeasurements, "A successful fetch of identical readings is a check, not a new measurement")
        try expect(rig.store.snapshot.metricChangedAt["steps"] == original.metricChangedAt["steps"], "Checking cannot advance the last changed time")
        rig.clock.advance(60)
        rig.web.payloads["stats"] = NSNull()
        rig.store.sync(); try await settled(rig.store)
        try expect(rig.store.snapshot.metrics["steps"] == nil && rig.store.snapshot.visibleReading("steps")?.value == 123,
                   "A valid absence keeps the last known value without manufacturing current data")
        try expect(rig.store.snapshot.retainedMetrics["steps"]?.retrievedAt == original.fetchedAt.addingTimeInterval(60),
                   "A retained value keeps the last successful retrieval, not the empty response timestamp")
        let restored = AppStore(supportDirectory: rig.directory, webSession: MockWeb(), defaults: rig.defaults,
                                clock: { rig.clock.moment }, automaticScheduling: false, writesWidgetData: false)
        try expect(restored.snapshot.visibleReading("steps")?.value == 123 && restored.snapshot.metrics["steps"] == nil,
                   "Last-known provenance survives a restart")
        restored.cancelLogin(resumeAutomatic: false)
        rig.clock.advance(60)
        rig.web.payloads["stats"] = ["totalSteps": 0]
        rig.store.sync(); try await settled(rig.store)
        try expect(rig.store.snapshot.metrics["steps"]?.value == 0 && rig.store.snapshot.retainedMetrics["steps"] == nil,
                   "A real zero replaces the saved value and clears its stale marker")
        try expect(!rig.store.snapshot.hasUnchangedMeasurements, "Changed measurements clear the unchanged state")
        rig.store.snapshot = .empty
        rig.store.snapshot.retainedMetrics["steps"] = .init(reading: .init(value: 123), sourceDate: "2026-09-14", retrievedAt: original.fetchedAt, changedAt: original.fetchedAt)
        try expect(rig.store.isStale, "Retained progress remains dated even when no current-day fetch has completed")
        rig.store.snapshot.retainedMetrics = ["sleepDuration": .init(reading: .init(value: 480), sourceDate: "2026-09-14", retrievedAt: original.fetchedAt, changedAt: original.fetchedAt)]
        try expect(!rig.store.isStale, "A completed sleep record alone cannot mark the host as a stale live feed")
        rig.store.disconnect()
        try expect(!rig.store.snapshot.hasMeasurements && !rig.store.snapshot.isDemo, "Disconnect clears current and retained values without entering demo")
        for slot in WidgetSlot.allCases {
            let preview = slot.previewData(language: .en, at: rig.clock.moment.wallTime)
            try expect(preview.snapshot.isDemo && preview.snapshot.hasMeasurements && preview.snapshot.trainingTimeline != nil,
                       "Filled gallery examples must stay explicitly synthetic for every widget type")
        }
    }
}
