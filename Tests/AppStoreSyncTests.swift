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
    var holdStage: String?
    var pending: CheckedContinuation<Void, Never>?
    func beginBatch() { batches += 1 }
    func openSignIn(title: String) { opens += 1 }
    func closeSignIn() { onSignInClosed?() }
    func prepare(forceReload: Bool) async throws { prepares += 1; if let prepareError { throw prepareError } }
    func get(path: String, stage: String) async throws -> Any {
        calls.append(stage); paths.append(path)
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
         groups: GarminWebCache? = nil, metrics: [String] = ["steps"], contentMode: WidgetContentMode = .metrics) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GarminDeskHostTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var preferences = AppPreferences()
        preferences.profiles[0].metricIDs = metrics
        preferences.profiles[0].contentMode = contentMode
        preferences.profiles[0].primaryMetric = metrics[0]
        var initial = checkpoint ?? .init(); if checkpoint == nil { initial.sessionState = state }
        try AppJSON.encoder.encode(preferences).write(to: directory.appendingPathComponent("preferences.json"))
        try AppJSON.encoder.encode(initial).write(to: directory.appendingPathComponent("sync-policy.json"))
        if let previous { try AppJSON.encoder.encode(previous).write(to: directory.appendingPathComponent("snapshot.json")) }
        if let groups { try AppJSON.encoder.encode(groups).write(to: directory.appendingPathComponent("metric-groups.json")) }
        defaults.values["GarminDeskWebConnected"] = connected
        let clock = self.clock
        store = AppStore(supportDirectory: directory, webSession: web, defaults: defaults,
                         clock: { clock.moment }, sourceTimeZone: { TimeZone(secondsFromGMT: 0)! },
                         automaticScheduling: false, writesWidgetData: false)
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

    static func testFreshCadenceAndProfileReads() async throws {
        let rig = try Rig(); defer { rig.clean() }
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(rig.web.calls == ["profile", "stats", "devices"], "Initial batch should request only selected metrics plus metadata")
        try expect(rig.store.snapshot.metrics["steps"]?.value == 123, "Actual normalized values should reach the snapshot")
        try expect(rig.store.nextSyncAt == rig.clock.moment.wallTime.addingTimeInterval(900), "Completion must schedule a single next due refresh")
        rig.store.sync(trigger: .automatic); rig.store.sync(trigger: .wake)
        try expect(rig.web.prepares == 1, "Fresh automatic/wake refresh must do no website I/O")
        rig.clock.advance(900)
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(rig.web.calls == ["profile", "stats", "devices", "stats"], "Fast metric cadence must not re-fetch profile or devices")
        rig.clock.advance(86400)
        rig.store.sync(trigger: .wake); try await settled(rig.store)
        try expect(rig.web.calls.filter { $0 == "profile" }.count == 2, "Due profile group must perform a real request")
        try expect(rig.web.calls.filter { $0 == "devices" }.count == 2, "Device metadata should refresh daily")
        try expect(try rig.checkpoint().successfulGroups[.profile]?.moment.wallTime == rig.clock.moment.wallTime,
                   "Profile cadence stamp must reflect the actual profile request")
    }

    static func testProfileChangesCoalesce() async throws {
        let rig = try Rig(); defer { rig.clean() }
        rig.web.holdStage = "stats"
        rig.store.sync(trigger: .automatic); try await held(rig.web)
        rig.store.preferences.profiles[0].metricIDs.append("sleepDuration")
        rig.store.sync(trigger: .wake); rig.store.sync()
        try expect(rig.web.prepares == 1, "Changes and refresh clicks during a batch must join the current request")
        rig.web.release(); try await settled(rig.store)
        try expect(rig.store.nextSyncAt == rig.clock.moment.wallTime, "A newly selected group must be scheduled immediately after completion")
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(rig.web.calls == ["profile", "stats", "devices", "sleep"], "Follow-up must fetch only newly selected groups")
        try expect(rig.store.snapshot.metrics["sleepDuration"]?.value == 300, "New profile metrics must appear without a second user refresh")
        let prepares = rig.web.prepares
        rig.store.preferences.profiles[0].name = "Renamed"
        try expect(rig.web.prepares == prepares, "Presentation-only profile edits must not trigger data requests")
        rig.store.preferences.menuMetric = "hydration"
        try expect(rig.web.prepares == prepares, "A legacy menu preference must not add requests to the regular app")
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
        let rig = try Rig(metrics: ["steps", "sleepDuration"]); defer { rig.clean() }
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
        try expect(rig.web.calls == ["profile", "stats"], "Missing group cache must invalidate freshness without re-fetching valid metadata")
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

    static func testTrainingOptInAndCadence() async throws {
        let rig = try Rig(contentMode: .mixed); defer { rig.clean() }
        let day = SyncPolicy.sourceDay(for: rig.clock.moment.wallTime, timeZone: TimeZone(secondsFromGMT: 0)!)
        let requests = GarminWebAPI.calendarRequests(sourceDay: day)
        rig.web.payloads["activities"] = [["activityId": 42, "activityName": "Synthetic run", "duration": 1800, "distance": 5000]]
        for (index, request) in requests.enumerated() {
            rig.web.payloads["planned_workouts." + request.month] = ["calendarItems": [["itemType": "workout", "id": index + 10,
                "workoutId": 7, "date": request.lastDay, "title": "Synthetic plan"]]]
        }
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(rig.web.calls.suffix(3) == ["activities"] + requests.map { "planned_workouts." + $0.month }, "Training opt-in must fetch the activity list and exactly two calendar months")
        try expect(rig.store.trainingTimeline?.past.first?.distanceKM == 5, "Training normalization must reach published state")
        try expect(rig.store.trainingTimeline?.upcoming.count == 2, "Repeated workout templates on different dates remain separate appointments")
        try expect(rig.store.trainingTimeline?.futureCoverageEnd == requests.last?.lastDay, "Calendar coverage must end at the verified month boundary")
        try expect(rig.store.trainingTimeline?.pastUpdatedAt == rig.clock.moment.wallTime && rig.store.trainingTimeline?.futureIssue == nil, "Successful training sections retain explicit retrieval timestamps")
        rig.clock.advance(900)
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(rig.web.calls.filter { $0 == "activities" }.count == 2, "Activities follow the selected refresh cadence")
        try expect(rig.web.calls.filter { $0.hasPrefix("planned_workouts.") }.count == 2, "Calendar must not follow the faster activity cadence")
        let persisted = try AppJSON.decoder.decode(GarminSnapshot.self, from: Data(contentsOf: rig.directory.appendingPathComponent("snapshot.json")))
        try expect(persisted.trainingTimeline == rig.store.trainingTimeline, "Training data must survive the same private snapshot contract used by widgets")
    }

    static func testTrainingPartialAndRateLimit() async throws {
        let rig = try Rig(contentMode: .training); defer { rig.clean() }
        let day = SyncPolicy.sourceDay(for: rig.clock.moment.wallTime, timeZone: TimeZone(secondsFromGMT: 0)!)
        let requests = GarminWebAPI.calendarRequests(sourceDay: day)
        let firstStage = "planned_workouts." + requests[0].month
        let secondStage = "planned_workouts." + requests[1].month
        rig.web.payloads["activities"] = [["activityId": 9, "activityName": "Fixture"]]
        rig.web.payloads[firstStage] = ["calendarItems": [["itemType": "workout", "id": 8, "date": requests[0].lastDay]]]
        rig.web.errors[secondStage] = .rateLimited(3600)
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(!rig.web.calls.contains("stats") && !rig.web.calls.contains("body_battery"), "Training-only profiles do not fetch stored metric selections or the legacy menu metric")
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
        let rig = try Rig(contentMode: .mixed); defer { rig.clean() }
        let day = SyncPolicy.sourceDay(for: rig.clock.moment.wallTime, timeZone: TimeZone(secondsFromGMT: 0)!)
        let requests = GarminWebAPI.calendarRequests(sourceDay: day)
        rig.web.errors["planned_workouts." + requests[0].month] = .rateLimited(nil)
        rig.store.sync(trigger: .automatic); try await settled(rig.store)
        try expect(!rig.web.calls.contains("planned_workouts." + requests[1].month), "A 429 on the first calendar page must prevent reading the second page")
        try expect(rig.store.trainingTimeline?.futureCoverage == .unavailable, "Unavailable future data cannot claim an empty published plan")
    }

    static func main() async {
        do {
            try await testEmptyUnchangedAndRecovery()
            try await testAccountOwnershipAcrossRestart()
            try await testPolicyBeforeWebsite()
            try await testBootstrapExpiration()
            try await testFreshCadenceAndProfileReads()
            try await testProfileChangesCoalesce()
            try await testRateLimitAndClockRollback()
            try await testLegacyCooldownMigration()
            try await testPartialAndEmptyDays()
            try await testCancellationIgnoresLateResponses()
            try await testCacheAndCheckpointConsistency()
            try await testDisconnectCleanupOrdering()
            try testCacheDateBoundary()
            try await testTrainingOptInAndCadence()
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
            let rig = try Rig(previous: previous, groups: cache, metrics: ["steps", "sleepDuration"])
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

    static func testEmptyUnchangedAndRecovery() async throws {
        let firstInstall = try Rig(connected: false); defer { firstInstall.clean() }
        try expect(!firstInstall.store.snapshot.isDemo && !firstInstall.store.snapshot.hasMeasurements,
                   "First launch has no invented values")
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
        rig.store.disconnect()
        try expect(!rig.store.snapshot.hasMeasurements && !rig.store.snapshot.isDemo, "Disconnect clears current and retained values without entering demo")
        for slot in WidgetSlot.allCases {
            try expect(!slot.previewData.snapshot.hasMeasurements && slot.previewData.snapshot.trainingTimeline == nil,
                       "Widget gallery must not invent readings or workouts")
        }
    }
}
