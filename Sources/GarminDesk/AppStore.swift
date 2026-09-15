import Foundation
import Combine
import ServiceManagement
import WidgetKit
import Darwin

@MainActor
final class AppStore: ObservableObject {
    @Published var preferences: AppPreferences {
        didSet {
            persistPreferences()
            webPolicy.configuration.refreshInterval = Double(max(5, preferences.refreshMinutes) * 60)
            if oldValue.refreshMinutes != preferences.refreshMinutes { scheduleRefresh() }
            if webConnected && requestedWebGroups(for: oldValue) != requestedWebGroups(for: preferences) { sync(trigger: .profilesChanged) }
        }
    }
    @Published var snapshot: GarminSnapshot { didSet { trainingTimeline = snapshot.trainingTimeline; publishWidgetData() } }
    @Published private(set) var trainingTimeline: TrainingTimelineSnapshot?
    @Published private(set) var widgetSharingAvailable = false
    @Published var hasSession = false { didSet { publishWidgetData() } }
    @Published var isSyncing = false
    @Published var lastErrorKey: String?
    @Published var connectionDiagnostic: BridgeDiagnostic?
    @Published var launchAtLogin = false
    @Published private(set) var needsWebSignIn = false
    @Published private(set) var nextSyncAt: Date?
    let supportDirectory: URL
    private let webSession: any GarminWebTransport
    private let defaults: UserDefaults
    private let clock: (() -> SyncPolicy.Moment)?
    private let sourceTimeZone: () -> TimeZone
    private let automaticScheduling: Bool
    private let writesWidgetData: Bool
    private var webDisplayName: String?
    private var webCache = GarminWebCache()
    private var webPolicy = SyncPolicy()
    private var webConnected = false
    private var webSyncTask: Task<Void, Never>?
    private var webRunID = UUID()
    private var pendingSignInVerification = false
    private var webDisconnectTask: Task<Void, Never>?
    private let bootID = AppStore.currentBootID()
    private var refreshTask: Task<Void, Never>?
    private var nextAllowedSync = Date.distantPast

    init(supportDirectory: URL? = nil, webSession: (any GarminWebTransport)? = nil,
         defaults: UserDefaults = .standard, clock: (() -> SyncPolicy.Moment)? = nil,
         sourceTimeZone: @escaping () -> TimeZone = { .autoupdatingCurrent },
         automaticScheduling: Bool = true, writesWidgetData: Bool = true) {
        self.supportDirectory = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GarminDesk", isDirectory: true)
        self.webSession = webSession ?? GarminWebSession()
        self.defaults = defaults
        self.clock = clock
        self.sourceTimeZone = sourceTimeZone
        self.automaticScheduling = automaticScheduling
        self.writesWidgetData = writesWidgetData
        let supportDirectory = self.supportDirectory
        let prefsURL = supportDirectory.appendingPathComponent("preferences.json")
        preferences = (try? Data(contentsOf: prefsURL)).flatMap { try? AppJSON.decoder.decode(AppPreferences.self, from: $0) } ?? AppPreferences()
        let cacheURL = supportDirectory.appendingPathComponent("snapshot.json")
        snapshot = (try? Data(contentsOf: cacheURL)).flatMap { try? AppJSON.decoder.decode(GarminSnapshot.self, from: $0) } ?? .demo
        trainingTimeline = snapshot.trainingTimeline
        webConnected = defaults.bool(forKey: "GarminDeskWebConnected")
        let policyURL = supportDirectory.appendingPathComponent("sync-policy.json")
        let checkpoint = (try? Data(contentsOf: policyURL)).flatMap { try? AppJSON.decoder.decode(SyncPolicy.Checkpoint.self, from: $0) } ?? .init()
        webPolicy = SyncPolicy(configuration: .init(refreshInterval: Double(max(5, preferences.refreshMinutes) * 60)), checkpoint: checkpoint)
        let groupURL = supportDirectory.appendingPathComponent("metric-groups.json")
        webCache = (try? Data(contentsOf: groupURL)).flatMap { try? AppJSON.decoder.decode(GarminWebCache.self, from: $0) } ?? .init()
        if webCache.version != 1 { webCache = .init() }
        // A missing/corrupt cache cannot inherit freshness from a separate policy
        // file, including an interrupted write from an older build.
        var restoredCheckpoint = webPolicy.checkpoint
        for (group, stamp) in restoredCheckpoint.successfulGroups where GarminPayloadNormalizer.groups.contains(group.rawValue) {
            if webCache.groups[group.rawValue]?.sourceDay != stamp.sourceDay {
                restoredCheckpoint.successfulGroups.removeValue(forKey: group)
            }
        }
        if let stamp = restoredCheckpoint.successfulGroups[.activities],
           webCache.pastActivities?.sourceDay != stamp.sourceDay {
            restoredCheckpoint.successfulGroups.removeValue(forKey: .activities)
        }
        if let stamp = restoredCheckpoint.successfulGroups[.plannedWorkouts] {
            let requests = GarminWebAPI.calendarRequests(sourceDay: stamp.sourceDay)
            if requests.isEmpty || requests.contains(where: { webCache.calendarMonths?[$0.month]?.sourceDay != stamp.sourceDay }) {
                restoredCheckpoint.successfulGroups.removeValue(forKey: .plannedWorkouts)
            }
        }
        webPolicy = SyncPolicy(configuration: webPolicy.configuration, checkpoint: restoredCheckpoint)
        needsWebSignIn = Self.requiresSessionAction(webPolicy.checkpoint.sessionState)
        hasSession = webConnected && !needsWebSignIn
        self.webSession.onConnectPageReady = { [weak self] in self?.runWebSync(trigger: .manual, completingSignIn: true) }
        self.webSession.onDiagnostic = { [weak self] diagnostic in self?.connectionDiagnostic = diagnostic }
        self.webSession.onSignInClosed = { [weak self] in
            guard let self else { return }
            self.needsWebSignIn = Self.requiresSessionAction(self.webPolicy.checkpoint.sessionState)
        }
        nextAllowedSync = Date(timeIntervalSince1970: defaults.double(forKey: "GarminDeskNextAllowedSync"))
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if preferences.profiles.isEmpty { preferences.profiles = [WidgetProfile()] }
        scheduleRefresh()
        publishWidgetData()
    }

    func text(_ key: String) -> String { Localizer.text(key, language: preferences.language) }
    func profile(_ id: UUID) -> WidgetProfile? { preferences.profiles.first { $0.id == id } }
    private var formatter: MetricFormatter { MetricFormatter(snapshot: snapshot, language: preferences.language) }
    func numericValue(_ id: String) -> Double? { formatter.value(id) }
    func displayValue(_ id: String) -> String { formatter.display(id) }
    func progress(_ id: String) -> Double? { formatter.progress(id) }

    var isStale: Bool { !snapshot.isDemo && Date().timeIntervalSince(snapshot.fetchedAt) > Double(max(preferences.refreshMinutes * 3, 60) * 60) }
    var updatedText: String {
        if snapshot.isDemo { return text("data.demo") }
        if snapshot.fetchedAt == .distantPast { return text("status.notConnected") }
        let date = DateFormatter(); date.locale = preferences.language.locale; date.dateStyle = .short; date.timeStyle = .short
        return text("data.updated") + " " + date.string(from: snapshot.fetchedAt)
    }

    func cancelLogin(resumeAutomatic: Bool = true) {
        refreshTask?.cancel(); refreshTask = nil; nextSyncAt = nil
        pendingSignInVerification = false
        webRunID = UUID(); webSyncTask?.cancel(); webSyncTask = nil
        if let request = webPolicy.activeRequest { _ = webPolicy.cancel(requestID: request.id) }
        webSession.cancel(); webSession.closeSignIn()
        isSyncing = false
        if resumeAutomatic { scheduleAfterCancellation() }
    }
    func connectGarmin() {
        guard !isSyncing, webDisconnectTask == nil else { return }
        let moment = syncMoment()
        if webPolicy.checkpoint.gate == nil && moment.wallTime < nextAllowedSync {
            lastErrorKey = "error.rate_limit"; nextSyncAt = nextAllowedSync; return
        }
        var preview = webPolicy
        if case .wait(let deadline) = webDecision(policy: &preview, trigger: .manual, verifying: true, at: moment) {
            nextSyncAt = deadline
            if webPolicy.checkpoint.gate?.reason == .rateLimit { lastErrorKey = "error.rate_limit" }
            return
        }
        lastErrorKey = nil
        webSession.openSignIn(title: text("connection.webTitle"))
    }
    func sync(trigger: SyncPolicy.Trigger = .manual) {
        guard webConnected, !needsWebSignIn else { return }
        runWebSync(trigger: trigger)
    }
    func showDemo() {
        guard !hasSession else { return }
        cancelLogin(resumeAutomatic: false); lastErrorKey = nil; snapshot = .demo
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && !launchAtLogin { lastErrorKey = "error.login_item" }
        } catch { launchAtLogin = SMAppService.mainApp.status == .enabled; lastErrorKey = "error.login_item" }
    }
    func disconnect() {
        guard webDisconnectTask == nil else { return }
        cancelLogin(resumeAutomatic: false)
        // Clear memory before fallible I/O so the timer cannot resurrect a session.
        hasSession = false; lastErrorKey = nil
        webConnected = false; webDisplayName = nil; needsWebSignIn = false
        defaults.set(false, forKey: "GarminDeskWebConnected")
        webPolicy.disconnect(); webCache = .init(); persistWebState()
        webDisconnectTask = Task { [weak self] in
            guard let self else { return }
            await self.webSession.disconnect()
            self.webDisconnectTask = nil
        }
        snapshot = .empty
        do {
            let cache = supportDirectory.appendingPathComponent("snapshot.json")
            if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
        } catch { if lastErrorKey == nil { lastErrorKey = "error.storage" } }
        snapshot = .demo
    }

    func addProfile() {
        var item = WidgetProfile(); item.name = text("profile.new")
        preferences.profiles.append(item)
    }
    func duplicateProfile(_ id: UUID) {
        guard var item = profile(id) else { return }
        item.id = UUID(); item.name = (item.name.isEmpty ? text("profile.default") : item.name) + " · " + text("profile.copy")
        preferences.profiles.append(item)
    }
    func deleteProfile(_ id: UUID) {
        guard preferences.profiles.count > 1 else { return }
        preferences.profiles.removeAll { $0.id == id }
    }
    func updateProfile(_ profile: WidgetProfile) {
        guard let index = preferences.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var cleaned = profile
        var seen = Set<String>()
        cleaned.metricIDs = profile.metricIDs.filter { id in MetricDefinition.catalog.contains { $0.id == id } && seen.insert(id).inserted }
        if cleaned.metricIDs.isEmpty { cleaned.metricIDs = [cleaned.primaryMetric] }
        if !cleaned.metricIDs.contains(cleaned.primaryMetric) { cleaned.primaryMetric = cleaned.metricIDs[0] }
        preferences.profiles[index] = cleaned
    }

    private static func requiresSessionAction(_ state: SyncPolicy.SessionState) -> Bool {
        switch state {
        case .expired, .unsupported, .securityChallenge, .accessDenied: return true
        case .unavailable, .available: return false
        }
    }

    private func requestedWebGroups(for preferences: AppPreferences) -> Set<SyncPolicy.Group> {
        GarminWebAPI.requiredGroups(metricIDs: Set(preferences.profiles.filter { $0.contentMode.includesMetrics }.flatMap(\.metricIDs)),
                                    includeTraining: preferences.profiles.contains { $0.contentMode.includesTraining })
    }

    private func webDecision(policy: inout SyncPolicy, trigger: SyncPolicy.Trigger,
                             verifying: Bool, at moment: SyncPolicy.Moment) -> SyncPolicy.Decision {
        let groups = requestedWebGroups(for: preferences)
        let day = SyncPolicy.sourceDay(for: moment.wallTime, timeZone: sourceTimeZone())
        if verifying || (webConnected && policy.checkpoint.sessionState == .unavailable) {
            return policy.beginSessionVerification(groups: groups, sourceDay: day, at: moment)
        }
        return policy.begin(groups: groups, sourceDay: day, trigger: trigger, at: moment)
    }

    private func runWebSync(trigger: SyncPolicy.Trigger, completingSignIn: Bool = false) {
        guard !isSyncing, webDisconnectTask == nil else { return }
        let verifying = completingSignIn || pendingSignInVerification
        guard verifying || (webConnected && !needsWebSignIn) else { return }
        let moment = syncMoment()
        // The legacy helper's persisted pause applies only when the native policy
        // has no gate. Native gates use a continuous clock, including across sleep.
        if webPolicy.checkpoint.gate == nil && moment.wallTime < nextAllowedSync {
            pendingSignInVerification = verifying
            if trigger == .manual { lastErrorKey = "error.rate_limit" }
            scheduleRefresh()
            return
        }
        let decision = webDecision(policy: &webPolicy, trigger: trigger, verifying: verifying, at: moment)
        let active: SyncPolicy.Request
        switch decision {
        case .start(let request): active = request
        case .wait:
            pendingSignInVerification = verifying
            scheduleRefresh()
            return
        case .needsUserAction(let state):
            needsWebSignIn = Self.requiresSessionAction(state)
            if needsWebSignIn { hasSession = false }
            scheduleRefresh()
            return
        case .coalesced, .idle: return
        }
        // A native monotonic gate has now elapsed. Do not let a wall-clock rollback
        // revive the compatibility helper's old deadline after this batch finishes.
        nextAllowedSync = .distantPast
        defaults.set(0, forKey: "GarminDeskNextAllowedSync")
        // Reserve a policy request before prepare/profile. Bootstrap failures must
        // be persisted just like failures from any measurement endpoint.
        refreshTask?.cancel(); refreshTask = nil
        pendingSignInVerification = false
        let runID = UUID(); webRunID = runID
        isSyncing = true; nextSyncAt = nil; lastErrorKey = nil; connectionDiagnostic = nil
        webSyncTask = Task { [weak self] in
            guard let self else { return }
            var successful = Set<SyncPolicy.Group>()
            var warnings: [String] = []
            var batchFailure: SyncPolicy.Failure?
            var cancelled = false
            var attemptedGroup: SyncPolicy.Group?
            let day = active.sourceDay
            self.webSession.beginBatch()
            defer {
                if self.webRunID == runID {
                    if cancelled { self.webPolicy.cancel(requestID: active.id) }
                    else {
                        self.webPolicy.finish(requestID: active.id, successfulGroups: successful,
                                              failure: batchFailure, at: self.syncMoment())
                        self.needsWebSignIn = Self.requiresSessionAction(self.webPolicy.checkpoint.sessionState)
                        self.hasSession = self.webConnected && !self.needsWebSignIn
                        // Even a valid empty day replaces yesterday's measurements.
                        self.commitWebCache(sourceDay: day, warnings: warnings)
                    }
                    self.persistWebState()
                    self.isSyncing = false; self.webSyncTask = nil
                    // Recompute from current preferences: a metric selected during
                    // this batch gets a single follow-up, without re-fetching fresh groups.
                    if cancelled { self.scheduleAfterCancellation() }
                    else { self.scheduleRefresh() }
                }
            }
            do {
                try await self.webSession.prepare(forceReload: false)
                try Task.checkCancellation()
                guard self.webRunID == runID else { return }
                if self.webDisplayName == nil || verifying || active.groups.contains(.profile) {
                    let payload = try await self.webSession.get(path: GarminWebAPI.profilePath, stage: "profile")
                    try Task.checkCancellation()
                    guard self.webRunID == runID else { return }
                    guard let profile = payload as? [String: Any],
                          let name = profile["displayName"] as? String, !name.isEmpty else { throw GarminWebError.invalidResponse }
                    // An explicit sign-in may select a different account. Never mix
                    // its new partial response with another account's cached values.
                    if verifying || (self.webDisplayName != nil && self.webDisplayName != name) {
                        self.webCache = .init(); self.snapshot = .empty
                    }
                    self.webDisplayName = name
                    if verifying || self.webPolicy.checkpoint.sessionState != .available {
                        self.webPolicy.sessionBecameAvailable(clearCadence: verifying)
                    }
                    self.webConnected = true; self.hasSession = true; self.needsWebSignIn = false
                    self.defaults.set(true, forKey: "GarminDeskWebConnected")
                    self.webSession.closeSignIn()
                    successful.insert(.profile)
                }
                guard let name = self.webDisplayName else { throw GarminWebError.signInRequired }
                let order: [SyncPolicy.Group] = [.stats, .bodyBattery, .sleep, .heart, .hrv, .readiness,
                    .respiration, .spo2, .vo2Max, .training, .weight, .hydration, .devices, .activities, .plannedWorkouts]
                for group in order where active.groups.contains(group) {
                    try Task.checkCancellation()
                    guard self.webRunID == runID else { return }
                    attemptedGroup = group
                    if group == .plannedWorkouts {
                        let requests = GarminWebAPI.calendarRequests(sourceDay: day)
                        guard !requests.isEmpty else { throw GarminWebError.invalidResponse }
                        self.webCache.calendarMonths = self.webCache.calendarMonths?.filter { key, _ in requests.contains { $0.month == key } }
                        var validMonths = 0
                        for request in requests {
                            try Task.checkCancellation()
                            guard self.webRunID == runID else { return }
                            do {
                                let payload = try await self.webSession.get(path: request.path, stage: group.rawValue + "." + request.month)
                                try Task.checkCancellation()
                                guard self.webRunID == runID else { return }
                                guard TrainingNormalizer.isRecognizedPlannedPayload(payload: payload) else { throw GarminWebError.invalidResponse }
                                let items = TrainingNormalizer.planned(payload: payload, sourceDay: day)
                                    .filter { String($0.localDate.prefix(7)) == request.month }
                                if self.webCache.calendarMonths == nil { self.webCache.calendarMonths = [:] }
                                self.webCache.calendarMonths?[request.month] = GarminCalendarMonthCache(sourceDay: day,
                                    retrievedAt: self.syncMoment().wallTime, items: items)
                                validMonths += 1
                            } catch GarminWebError.invalidResponse {
                                warnings.append("schema_mismatch." + group.rawValue + "." + request.month)
                                self.setTrainingIssue("schema_mismatch", group: group)
                                batchFailure = .transient
                            }
                        }
                        // Persist each successful month even when another fails,
                        // but never mark a partial calendar batch fully fresh.
                        if validMonths == requests.count {
                            successful.insert(group)
                            self.setTrainingIssue(nil, group: group)
                        }
                        continue
                    }
                    guard let path = GarminWebAPI.path(group: group, sourceDay: day, displayName: name) else { throw GarminWebError.invalidResponse }
                    do {
                        let payload = try await self.webSession.get(path: path, stage: group.rawValue)
                        try Task.checkCancellation()
                        guard self.webRunID == runID else { return }
                        if group == .devices {
                            guard let devices = payload as? [[String: Any]] else { throw GarminWebError.invalidResponse }
                            self.webCache.devices = Array(Set(devices.compactMap {
                                ($0["userAlias"] as? String) ?? ($0["productDisplayName"] as? String) ?? ($0["deviceTypeDisplayName"] as? String)
                            }.filter { !$0.isEmpty })).sorted()
                        } else if group == .activities {
                            guard TrainingNormalizer.isRecognizedPastPayload(payload: payload) else { throw GarminWebError.invalidResponse }
                            self.webCache.pastActivities = GarminPastActivitiesCache(sourceDay: day,
                                retrievedAt: self.syncMoment().wallTime, items: TrainingNormalizer.past(payload: payload))
                            self.setTrainingIssue(nil, group: group)
                        } else {
                            guard GarminPayloadNormalizer.isRecognizedPayload(group: group.rawValue, payload: payload) else { throw GarminWebError.invalidResponse }
                            let values = GarminPayloadNormalizer.normalize(group: group.rawValue, payload: payload)
                            self.webCache.groups[group.rawValue] = GarminMetricGroupCache(sourceDay: day,
                                retrievedAt: self.syncMoment().wallTime, metrics: values)
                        }
                        successful.insert(group)
                    } catch GarminWebError.invalidResponse {
                        warnings.append("schema_mismatch." + group.rawValue)
                        if group == .activities { self.setTrainingIssue("schema_mismatch", group: group) }
                        batchFailure = .transient
                    }
                }
                if !warnings.isEmpty { self.lastErrorKey = "error.partial" }
            } catch is CancellationError {
                cancelled = true
            } catch {
                guard self.webRunID == runID else { return }
                let failure = (error as? GarminWebError) ?? .network
                self.lastErrorKey = "error." + failure.code
                if let attemptedGroup, [.activities, .plannedWorkouts].contains(attemptedGroup), failure.code != "cancelled" {
                    self.setTrainingIssue(failure.code, group: attemptedGroup)
                }
                switch failure {
                case .rateLimited(let retryAfter):
                    let provided = retryAfter ?? 0
                    let delay = max(1800, min(604800, provided.isFinite ? provided : 1800))
                    self.nextAllowedSync = self.syncMoment().wallTime.addingTimeInterval(delay)
                    self.defaults.set(self.nextAllowedSync.timeIntervalSince1970, forKey: "GarminDeskNextAllowedSync")
                    batchFailure = .rateLimited(retryAfterSeconds: Int(delay.rounded(.up)))
                case .signInRequired: batchFailure = .authenticationExpired
                case .forbidden: batchFailure = .accessDenied
                case .challenge: batchFailure = .securityChallenge
                case .cancelled: cancelled = true
                case .network, .invalidResponse: batchFailure = .transient
                }
                if !cancelled { warnings.append(failure.code + "." + (self.connectionDiagnostic?.stage ?? "connection")) }
            }
        }
    }

    private func setTrainingIssue(_ issue: String?, group: SyncPolicy.Group) {
        if webCache.trainingIssues == nil { webCache.trainingIssues = [:] }
        webCache.trainingIssues?[group.rawValue] = issue
    }

    private func commitWebCache(sourceDay: String, warnings: [String]) {
        let current = webCache.snapshot(sourceDay: sourceDay, fallback: snapshot, warnings: warnings)
        guard !current.isDemo else { return }
        snapshot = current
        do { try writePrivate(AppJSON.encoder.encode(current), name: "snapshot.json") }
        catch { if lastErrorKey == nil { lastErrorKey = "error.storage" } }
    }
    private func persistWebState() {
        var checkpoint = webPolicy.checkpoint
        do {
            try writePrivate(AppJSON.encoder.encode(webCache), name: "metric-groups.json")
        } catch {
            // Persist the auth/rate-limit state even if health-cache storage fails;
            // don't restore freshness for data that may never have reached disk.
            checkpoint.successfulGroups = [:]
            if lastErrorKey == nil { lastErrorKey = "error.storage" }
        }
        do { try writePrivate(AppJSON.encoder.encode(checkpoint), name: "sync-policy.json") }
        catch { if lastErrorKey == nil { lastErrorKey = "error.storage" } }
    }
    private func syncMoment() -> SyncPolicy.Moment {
        if let clock { return clock() }
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        let seconds = Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
        return .init(wallTime: Date(), monotonicSeconds: seconds, bootID: bootID)
    }
    private static func currentBootID() -> String {
        var count = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &count, nil, 0) == 0, count > 1 else { return UUID().uuidString }
        var bytes = [CChar](repeating: 0, count: count)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &count, nil, 0) == 0 else { return UUID().uuidString }
        return String(cString: bytes)
    }

    private func scheduleAfterCancellation() {
        // Cancelling one request must neither retry immediately nor disable future
        // unattended updates for the rest of the application's lifetime.
        let delay = max(5 * 60, webPolicy.configuration.refreshInterval)
        scheduleRefresh(notBefore: syncMoment().wallTime.addingTimeInterval(delay))
    }

    private func scheduleRefresh(notBefore: Date? = nil) {
        refreshTask?.cancel(); refreshTask = nil; nextSyncAt = nil
        guard webDisconnectTask == nil, pendingSignInVerification || (webConnected && !needsWebSignIn) else { return }
        let moment = syncMoment()
        var preview = webPolicy
        let decision = webDecision(policy: &preview, trigger: .automatic,
                                   verifying: pendingSignInVerification, at: moment)
        let proposed: Date
        switch decision {
        case .start: proposed = moment.wallTime
        case .wait(let deadline): proposed = deadline
        case .needsUserAction, .coalesced, .idle: return
        }
        var deadline = proposed
        if webPolicy.checkpoint.gate == nil { deadline = max(deadline, nextAllowedSync) }
        // Day-scoped measurements expire at the local date boundary even when the
        // user chooses a long refresh interval. A server pause still takes priority.
        if preview.checkpoint.gate == nil && nextAllowedSync <= moment.wallTime {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = sourceTimeZone()
            if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: moment.wallTime)) {
                deadline = min(deadline, midnight)
            }
        }
        if let notBefore { deadline = max(deadline, notBefore) }
        nextSyncAt = deadline
        guard automaticScheduling else { return }
        let delay = min(7 * 24 * 60 * 60, max(0.05, deadline.timeIntervalSince(moment.wallTime)))
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            self.runWebSync(trigger: .automatic)
        }
    }
    func publishWidgetData() {
        guard writesWidgetData else { return }
        do {
            try WidgetDataStore.write(WidgetData(preferences: preferences, snapshot: snapshot, isConnected: hasSession))
            let configurationAvailable = WidgetDataStore.configurationAvailable
            if widgetSharingAvailable != configurationAvailable { widgetSharingAvailable = configurationAvailable }
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            if widgetSharingAvailable { widgetSharingAvailable = false }
        }
    }
    private func persistPreferences() {
        publishWidgetData()
        do { try writePrivate(AppJSON.encoder.encode(preferences), name: "preferences.json") }
        catch { lastErrorKey = "error.storage" }
    }
    private func writePrivate(_ data: Data, name: String) throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = supportDirectory.appendingPathComponent(name)
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}
