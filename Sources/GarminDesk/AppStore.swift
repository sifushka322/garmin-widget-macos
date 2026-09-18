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
            webPolicy.configuration.refreshInterval = preferences.refreshInterval
            if requestedWebGroups(for: oldValue) != requestedWebGroups(for: preferences) {
                runWebSync(trigger: .profilesChanged)
            }
            if oldValue.refreshMinutes != preferences.refreshMinutes { scheduleRefresh() }
        }
    }
    @Published var snapshot: GarminSnapshot { didSet { trainingTimeline = snapshot.trainingTimeline; publishWidgetData() } }
    @Published private(set) var trainingTimeline: TrainingTimelineSnapshot?
    @Published private(set) var widgetSharingAvailable = false
    @Published var hasSession = false { didSet { if oldValue != hasSession { publishWidgetData() } } }
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
    private let historicalRecoveryEnabled: Bool
    private let writesWidgetData: Bool
    private let widgetPublisher: ((WidgetData) throws -> Void)?
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
         automaticScheduling: Bool = true, writesWidgetData: Bool = true,
         historicalRecoveryEnabled: Bool = true,
         initialWidgetSharingAvailable: Bool = false,
         widgetPublisher: ((WidgetData) throws -> Void)? = nil) {
        self.supportDirectory = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GarminDesk", isDirectory: true)
        self.webSession = webSession ?? GarminWebSession()
        self.defaults = defaults
        self.clock = clock
        self.sourceTimeZone = sourceTimeZone
        self.automaticScheduling = automaticScheduling
        self.historicalRecoveryEnabled = historicalRecoveryEnabled
        self.writesWidgetData = writesWidgetData
        self.widgetPublisher = widgetPublisher
        self.widgetSharingAvailable = initialWidgetSharingAvailable
        let supportDirectory = self.supportDirectory
        let prefsURL = supportDirectory.appendingPathComponent("preferences.json")
        preferences = (try? Data(contentsOf: prefsURL)).flatMap { try? AppJSON.decoder.decode(AppPreferences.self, from: $0) } ?? AppPreferences()
        let cacheURL = supportDirectory.appendingPathComponent("snapshot.json")
        let cachedSnapshotData = try? Data(contentsOf: cacheURL)
        snapshot = .empty
        trainingTimeline = nil
        webConnected = defaults.bool(forKey: "GarminDeskWebConnected")
        let policyURL = supportDirectory.appendingPathComponent("sync-policy.json")
        let checkpoint = (try? Data(contentsOf: policyURL)).flatMap { try? AppJSON.decoder.decode(SyncPolicy.Checkpoint.self, from: $0) } ?? .init()
        webPolicy = SyncPolicy(configuration: .init(refreshInterval: preferences.refreshInterval), checkpoint: checkpoint)
        let groupURL = supportDirectory.appendingPathComponent("metric-groups.json")
        webCache = (try? Data(contentsOf: groupURL)).flatMap { try? AppJSON.decoder.decode(GarminWebCache.self, from: $0) } ?? .init()
        if webCache.version != 1 || webCache.accountDisplayName?.isEmpty != false { webCache = .init() }
        // Either cache file may be the last successful write from an account
        // switch. Discard both sides of a conflict before an error handler can
        // republish an unverified group's values without a profile response.
        if PrivateSnapshotStore.ownersConflict(cachedSnapshotData, cache: webCache) { webCache = .init() }
        if webConnected {
            let day = SyncPolicy.sourceDay(for: clock?().wallTime ?? Date(), timeZone: sourceTimeZone())
            webCache = PrivateSnapshotStore.restoreCache(cachedSnapshotData, cache: webCache, sourceDay: day)
            snapshot = PrivateSnapshotStore.restore(cachedSnapshotData, cache: webCache, sourceDay: day)
            trainingTimeline = snapshot.trainingTimeline
        }
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
            // A user closing the interactive window cancels its navigation and
            // verification, including a response already awaiting WebKit.
            self.cancelLogin()
            self.needsWebSignIn = Self.requiresSessionAction(self.webPolicy.checkpoint.sessionState)
        }
        nextAllowedSync = Date(timeIntervalSince1970: defaults.double(forKey: "GarminDeskNextAllowedSync"))
        launchAtLogin = SMAppService.mainApp.status == .enabled
        scheduleRefresh()
        persistPreferences()
    }

    func text(_ key: String) -> String { Localizer.text(key, language: preferences.language) }
    private var formatter: MetricFormatter { MetricFormatter(snapshot: snapshot, language: preferences.language) }
    func numericValue(_ id: String) -> Double? { formatter.value(id) }
    func displayValue(_ id: String) -> String { formatter.display(id) }
    func progress(_ id: String) -> Double? { formatter.progress(id) }

    var isStale: Bool {
        guard !snapshot.isDemo else { return false }
        let now = syncMoment().wallTime
        return Set(snapshot.metrics.keys).union(snapshot.retainedMetrics.keys).contains { metricIsStale($0, at: now) }
    }

    func metricIsStale(_ id: String, at now: Date? = nil) -> Bool {
        snapshot.metricIsStale(id, at: now ?? syncMoment().wallTime,
                               timeZone: sourceTimeZone(), staleInterval: preferences.staleInterval)
    }
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
    }

    private static func requiresSessionAction(_ state: SyncPolicy.SessionState) -> Bool {
        switch state {
        case .expired, .unsupported, .securityChallenge, .accessDenied: return true
        case .unavailable, .available: return false
        }
    }

    private func requestedWebGroups(for preferences: AppPreferences) -> Set<SyncPolicy.Group> {
        var groups = GarminWebAPI.requiredGroups(metricIDs: WidgetSlot.requiredMetricIDs(in: preferences), includeTraining: true)
        let moment = syncMoment()
        let day = SyncPolicy.sourceDay(for: moment.wallTime, timeZone: sourceTimeZone())
        if historicalRecoveryEnabled, webCache.historicalRecovery?.pending(sourceDay: day, at: moment).isEmpty == false {
            groups.insert(.historicalRecovery)
        }
        return groups
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
            var transientFailed = Set<SyncPolicy.Group>()
            var deferred = Set<SyncPolicy.Group>()
            let batchStarted = self.syncMoment().monotonicSeconds
            var lastPublished = batchStarted
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
                                              failure: batchFailure, transientFailedGroups: transientFailed,
                                              deferredGroups: deferred, at: self.syncMoment())
                        self.needsWebSignIn = Self.requiresSessionAction(self.webPolicy.checkpoint.sessionState)
                        self.hasSession = self.webConnected && !self.needsWebSignIn
                        // Current-day absence and last known values remain distinct.
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
                    let accountChanged = self.webCache.accountDisplayName != name
                    if accountChanged {
                        self.webCache = .init(); self.snapshot = .empty
                    }
                    self.webCache.accountDisplayName = name
                    self.webDisplayName = name
                    if verifying || accountChanged || self.webPolicy.checkpoint.sessionState != .available {
                        self.webPolicy.sessionBecameAvailable(clearCadence: verifying || accountChanged)
                    }
                    self.webConnected = true; self.hasSession = true; self.needsWebSignIn = false
                    self.defaults.set(true, forKey: "GarminDeskWebConnected")
                    self.webSession.closeSignIn()
                    successful.insert(.profile)
                }
                guard let name = self.webDisplayName else { throw GarminWebError.signInRequired }
                let order: [SyncPolicy.Group] = [.stats, .bodyBattery, .sleep, .heart, .hrv, .readiness,
                    .respiration, .spo2, .vo2Max, .training, .weight, .hydration, .devices, .activities, .plannedWorkouts, .historicalRecovery]
                for group in order where active.groups.contains(group) {
                    try Task.checkCancellation()
                    guard self.webRunID == runID else { return }
                    // Bound one batch to 90 continuous seconds plus at most one
                    // in-flight request. Unattempted groups remain immediately due.
                    if self.syncMoment().monotonicSeconds - batchStarted >= 90 {
                        deferred = active.groups.subtracting(successful).subtracting(transientFailed)
                        break
                    }
                    attemptedGroup = group
                    if group == .historicalRecovery {
                        // Recovery was queued by an earlier successful current-day
                        // batch. Never delay publication of today's first readings.
                        let recoveryNow = self.syncMoment()
                        let pending = self.webCache.historicalRecovery?.pending(sourceDay: day, at: recoveryNow) ?? []
                        guard let previousDay = GarminHistoricalRecovery.previousDay(for: day) else {
                            successful.insert(group); continue
                        }
                        for recoveredGroup in pending {
                            try Task.checkCancellation()
                            guard self.webRunID == runID else { return }
                            guard self.webCache.historicalRecovery?.pending(sourceDay: day, at: self.syncMoment()).contains(recoveredGroup) == true else { continue }
                            if self.syncMoment().monotonicSeconds - batchStarted >= 90 {
                                deferred.insert(group); break
                            }
                            self.webCache.historicalRecovery?.attempted.insert(recoveredGroup)
                            // Persist the consumed attempt before GET. A failed disk
                            // write skips network I/O, preserving the cross-launch cap.
                            do { try self.writePrivate(AppJSON.encoder.encode(self.webCache), name: "metric-groups.json") }
                            catch {
                                warnings.append("storage.historical_recovery")
                                self.lastErrorKey = "error.storage"
                                continue
                            }
                            if self.webCache.hasOwnedReading(for: recoveredGroup, snapshot: self.snapshot) { continue }
                            guard let path = GarminWebAPI.path(group: recoveredGroup, sourceDay: previousDay, displayName: name) else { continue }
                            do {
                                let payload = try await self.webSession.get(path: path, stage: "historical." + recoveredGroup.rawValue)
                                try Task.checkCancellation()
                                guard self.webRunID == runID else { return }
                                guard GarminPayloadNormalizer.isRecognizedPayload(group: recoveredGroup.rawValue, payload: payload),
                                      let recordDay = GarminPayloadNormalizer.historicalSourceDay(group: recoveredGroup.rawValue, payload: payload, requestedDay: previousDay) else {
                                    throw GarminWebError.invalidResponse
                                }
                                let retrievedAt = self.syncMoment().wallTime
                                let values = GarminPayloadNormalizer.normalize(group: recoveredGroup.rawValue, payload: payload, asOf: retrievedAt)
                                self.webCache.remember(group: .init(sourceDay: recordDay, retrievedAt: retrievedAt, metrics: values))
                                // No current-group stamp, projection, personal ranges
                                // or countdown is attached to a historical reading.
                            } catch GarminWebError.invalidResponse {
                                warnings.append("schema_mismatch.historical." + recoveredGroup.rawValue)
                            } catch GarminWebError.network {
                                warnings.append("network.historical." + recoveredGroup.rawValue)
                            }
                        }
                        if self.webCache.historicalRecovery?.pending(sourceDay: day, at: self.syncMoment()).isEmpty != false {
                            successful.insert(group)
                        }
                        continue
                    }
                    if group == .plannedWorkouts {
                        let requests = GarminWebAPI.calendarRequests(sourceDay: day)
                        guard !requests.isEmpty else { throw GarminWebError.invalidResponse }
                        self.webCache.calendarMonths = self.webCache.calendarMonths?.filter { key, _ in requests.contains { $0.month == key } }
                        let calendarNow = self.syncMoment()
                        let maximumAge = self.webPolicy.configuration.cadence(for: group)
                        if self.webCache.calendarRefreshProgress?.isCurrent(sourceDay: day, at: calendarNow, maximumAge: maximumAge) != true {
                            self.webCache.calendarRefreshProgress = .init(sourceDay: day, startedAt: calendarNow)
                        }
                        // A completed marker is valid only alongside the exact
                        // payload written in this refresh generation.
                        let validCompletedMonths = self.webCache.calendarRefreshProgress?.completedMonths.filter { month, stamp in
                            requests.contains { $0.month == month } &&
                            self.webCache.calendarMonths?[month]?.sourceDay == day &&
                            self.webCache.calendarMonths?[month]?.retrievedAt == stamp
                        } ?? [:]
                        self.webCache.calendarRefreshProgress?.completedMonths = validCompletedMonths
                        for request in requests where self.webCache.calendarRefreshProgress?.completedMonths[request.month] == nil {
                            try Task.checkCancellation()
                            guard self.webRunID == runID else { return }
                            if self.syncMoment().monotonicSeconds - batchStarted >= 90 {
                                deferred.insert(group)
                                break
                            }
                            do {
                                let payload = try await self.webSession.get(path: request.path, stage: group.rawValue + "." + request.month)
                                try Task.checkCancellation()
                                guard self.webRunID == runID else { return }
                                guard TrainingNormalizer.isRecognizedPlannedPayload(payload: payload) else { throw GarminWebError.invalidResponse }
                                let items = TrainingNormalizer.planned(payload: payload, sourceDay: day)
                                    .filter { String($0.localDate.prefix(7)) == request.month }
                                if self.webCache.calendarMonths == nil { self.webCache.calendarMonths = [:] }
                                let retrievedAt = self.syncMoment().wallTime
                                self.webCache.calendarMonths?[request.month] = GarminCalendarMonthCache(sourceDay: day,
                                    retrievedAt: retrievedAt, items: items)
                                self.webCache.calendarRefreshProgress?.completedMonths[request.month] = retrievedAt
                            } catch GarminWebError.invalidResponse {
                                warnings.append("schema_mismatch." + group.rawValue + "." + request.month)
                                self.setTrainingIssue("schema_mismatch", group: group)
                                transientFailed.insert(group)
                            } catch GarminWebError.network {
                                warnings.append("network." + group.rawValue + "." + request.month)
                                self.setTrainingIssue("network", group: group)
                                transientFailed.insert(group)
                            }
                        }
                        // Persist each successful month even when another fails,
                        // but never mark a partial calendar batch fully fresh.
                        if requests.allSatisfy({ self.webCache.calendarRefreshProgress?.completedMonths[$0.month] != nil }) {
                            self.webCache.calendarRefreshProgress = nil
                            successful.insert(group)
                            self.setTrainingIssue(nil, group: group)
                        }
                        if self.syncMoment().monotonicSeconds - lastPublished >= 10 {
                            self.commitWebCache(sourceDay: day, warnings: warnings)
                            lastPublished = self.syncMoment().monotonicSeconds
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
                            guard GarminPayloadNormalizer.isRecognizedPayload(group: group.rawValue, payload: payload),
                                  GarminPayloadNormalizer.matchesSourceDay(group: group.rawValue, payload: payload, sourceDay: day) else { throw GarminWebError.invalidResponse }
                            let retrievedAt = self.syncMoment().wallTime
                            var values = GarminPayloadNormalizer.normalize(group: group.rawValue, payload: payload, asOf: retrievedAt)
                            var projection = group == .bodyBattery
                                ? GarminPayloadNormalizer.bodyBatteryProjection(payload: payload, asOf: retrievedAt) : nil
                            if group == .bodyBattery,
                               let previous = self.webCache.groups[group.rawValue], previous.sourceDay == day,
                               let old = previous.metrics["bodyBattery"], let oldDate = old.measuredAt,
                               let newDate = values["bodyBattery"]?.measuredAt, oldDate > newDate {
                                // A lagging response may contain an earlier series.
                                // Keep the last actual sample and original trend expiry.
                                values["bodyBattery"] = old
                                projection = previous.bodyBatteryProjection
                            }
                            var cached = GarminMetricGroupCache(sourceDay: day, retrievedAt: retrievedAt, metrics: values)
                            cached.bodyBatteryProjection = projection
                            cached.metricContext = GarminPayloadNormalizer.metricContext(group: group.rawValue, payload: payload)
                            // Preserve the previous owned value before replacing
                            // this endpoint with a successful empty response.
                            if let old = self.webCache.groups[group.rawValue] { self.webCache.remember(group: old) }
                            self.webCache.groups[group.rawValue] = cached
                            if self.historicalRecoveryEnabled, values.isEmpty,
                               GarminHistoricalRecovery.eligibleGroups.contains(group),
                               !self.webCache.hasOwnedReading(for: group, snapshot: self.snapshot) {
                                if self.webCache.historicalRecovery == nil || day > self.webCache.historicalRecovery!.sourceDay {
                                    self.webCache.historicalRecovery = .init(sourceDay: day, startedAt: self.syncMoment())
                                }
                                // Expiry does not reset the generation on the same
                                // day. Attempts remain consumed until date/account change.
                                if self.webCache.historicalRecovery?.sourceDay == day {
                                    self.webCache.historicalRecovery?.queued.insert(group)
                                }
                            }
                        }
                        successful.insert(group)
                        // Fast batches still publish once. Slow batches expose
                        // completed groups at most once per ten seconds.
                        if self.syncMoment().monotonicSeconds - lastPublished >= 10 {
                            self.commitWebCache(sourceDay: day, warnings: warnings)
                            lastPublished = self.syncMoment().monotonicSeconds
                        }
                    } catch GarminWebError.invalidResponse {
                        warnings.append("schema_mismatch." + group.rawValue)
                        if group == .activities { self.setTrainingIssue("schema_mismatch", group: group) }
                        transientFailed.insert(group)
                    } catch GarminWebError.network {
                        warnings.append("network." + group.rawValue)
                        if group == .activities { self.setTrainingIssue("network", group: group) }
                        transientFailed.insert(group)
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
        webCache.remember(snapshot: snapshot)
        let current = webCache.snapshot(sourceDay: sourceDay, fallback: snapshot, warnings: warnings)
        guard !current.isDemo else { return }
        snapshot = current
        do { try writePrivate(PrivateSnapshotStore.encode(current, accountDisplayName: webCache.accountDisplayName), name: "snapshot.json") }
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
            let data = WidgetData(preferences: preferences, snapshot: snapshot, isConnected: hasSession)
            if let widgetPublisher {
                try widgetPublisher(data)
                return
            }
            try WidgetDataStore.write(data)
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
