import Foundation

/// A transport-independent scheduler. This value contains no credentials, account
/// identifiers, measurements, or file paths. The owner supplies clocks and performs I/O.
///
/// Integration:
/// - Ask `begin` on launch, wake, a timer, manual refresh, or a metric-profile change.
/// - Start network work only for `.start`; concurrent calls return `.coalesced`.
/// - Pass successful endpoint groups to `finish`, including partial responses.
/// - After finish, call begin again with the latest desired groups; newly selected
///   groups run once and groups satisfied by the just-finished request are coalesced.
/// - For `.wait`, convert the deadline to a delay relative to the supplied wall
///   time and use a monotonic one-shot timer. Re-evaluate on wake/date/zone changes.
/// - Cancel the actual transport when `cancel`/`disconnect` invalidates its request.
/// - Persist `checkpoint` privately. It excludes in-flight work, so a terminated app
///   cannot restore a permanent busy state. It contains no actual cached measurements.
struct SyncPolicy {
    enum Group: String, CaseIterable, Codable, Hashable {
        case stats, heart, bodyBattery = "body_battery", sleep, hrv, spo2, respiration
        case readiness, vo2Max = "vo2_max", training, weight, hydration, profile, devices
        // Opt-in: only request these after the selected connector supports them.
        case activities, plannedWorkouts = "planned_workouts"

        static let currentMetrics = Set(allCases.filter { $0 != .activities && $0 != .plannedWorkouts })
        var isDaily: Bool { self != .profile && self != .devices }
    }

    enum SessionState: String, Codable {
        case unavailable, available, expired, unsupported, securityChallenge, accessDenied
    }

    enum Trigger { case automatic, wake, manual, profilesChanged }

    /// Monotonic seconds must include sleep and use the same origin within `bootID`.
    /// A stable OS boot identifier permits safe reuse across process launches. If an
    /// owner only has a process clock, use a fresh bootID per process and wall fallback.
    struct Moment: Codable, Equatable {
        var wallTime: Date
        var monotonicSeconds: TimeInterval
        var bootID: String
    }

    struct Configuration {
        var refreshInterval: TimeInterval = 15 * 60
        var manualMinimumInterval: TimeInterval = 30
        var cadenceOverrides: [Group: TimeInterval] = [:]

        func cadence(for group: Group) -> TimeInterval {
            let base = refreshInterval.isFinite ? min(24 * 60 * 60, max(5 * 60, refreshInterval)) : 15 * 60
            if let override = cadenceOverrides[group], override.isFinite { return min(7 * 24 * 60 * 60, max(30, override)) }
            switch group {
            case .stats, .heart, .bodyBattery, .hydration, .activities: return base
            case .sleep, .hrv, .spo2, .respiration, .readiness, .training: return max(base, 30 * 60)
            case .vo2Max, .weight, .plannedWorkouts: return max(base, 60 * 60)
            case .profile, .devices: return max(base, 24 * 60 * 60)
            }
        }
    }

    struct Stamp: Codable, Equatable {
        var moment: Moment
        var sourceDay: String
    }

    enum GateReason: String, Codable { case transient, rateLimit }
    struct Gate: Codable, Equatable {
        var startedAt: Moment
        var duration: TimeInterval
        var reason: GateReason
    }

    struct GroupFailure: Codable {
        var attempts: Int
        var gate: Gate
    }

    struct Checkpoint: Codable {
        var version = 1
        var sessionState: SessionState = .unavailable
        var successfulGroups: [Group: Stamp] = [:]
        var consecutiveTransientFailures = 0
        var gate: Gate?
        // Additive optional state keeps existing version-1 checkpoints readable.
        var groupFailures: [Group: GroupFailure]?
    }

    struct Request: Equatable {
        let id: UUID
        let groups: Set<Group>
        let sourceDay: String
        let startedAt: Moment
    }

    enum Decision: Equatable {
        case start(Request)
        case coalesced(requestID: UUID)
        case wait(until: Date)
        case needsUserAction(SessionState)
        case idle
    }

    enum Failure {
        case transient
        case rateLimited(retryAfterSeconds: Int?)
        case authenticationExpired
        case sessionUnsupported
        case securityChallenge
        case accessDenied
    }

    var configuration: Configuration
    private(set) var checkpoint: Checkpoint
    private(set) var activeRequest: Request?

    init(configuration: Configuration = Configuration(), checkpoint: Checkpoint = Checkpoint()) {
        self.configuration = configuration
        self.checkpoint = checkpoint.version == 1 ? checkpoint : Checkpoint()
    }

    /// Call after a verified session becomes usable, not on every timer or merely
    /// because a saved token/cookie exists. Token rotations do not require this call.
    mutating func sessionBecameAvailable(clearCadence: Bool = false) {
        checkpoint.sessionState = .available
        checkpoint.consecutiveTransientFailures = 0
        if checkpoint.gate?.reason != .rateLimit { checkpoint.gate = nil }
        if clearCadence { checkpoint.successfulGroups = [:]; checkpoint.groupFailures = nil }
    }

    /// A new account must not inherit the old account's group freshness. A server
    /// rate-limit pause survives disconnection, since signing in is not a bypass.
    mutating func disconnect() {
        activeRequest = nil
        checkpoint.sessionState = .unavailable
        checkpoint.successfulGroups = [:]
        checkpoint.groupFailures = nil
        checkpoint.consecutiveTransientFailures = 0
        if checkpoint.gate?.reason != .rateLimit { checkpoint.gate = nil }
    }

    mutating func begin(groups: Set<Group>, sourceDay: String, trigger: Trigger = .automatic,
                        at now: Moment, requestID: UUID = UUID()) -> Decision {
        if let activeRequest { return .coalesced(requestID: activeRequest.id) }
        guard !groups.isEmpty else { return .idle }
        if let gate = checkpoint.gate {
            let remaining = remainingDelay(gate, at: now)
            if remaining > 0 { return .wait(until: now.wallTime.addingTimeInterval(remaining)) }
            checkpoint.gate = nil
        }
        guard checkpoint.sessionState == .available else { return .needsUserAction(checkpoint.sessionState) }

        var due = Set<Group>()
        var nextDelay = TimeInterval.greatestFiniteMagnitude
        for group in groups {
            let delay = delayUntilDue(group, sourceDay: sourceDay, trigger: trigger, at: now)
            if delay <= 0 { due.insert(group) }
            else { nextDelay = min(nextDelay, delay) }
        }
        guard !due.isEmpty else { return .wait(until: now.wallTime.addingTimeInterval(nextDelay)) }
        let request = Request(id: requestID, groups: due, sourceDay: sourceDay, startedAt: now)
        activeRequest = request
        return .start(request)
    }

    /// Reserve an explicit session verification before any website I/O. Unlike a
    /// normal refresh, this may verify a currently blocked/unavailable session, but
    /// does not mark it usable. The owner must call this only after user sign-in or
    /// once while restoring a previously connected, not-known-expired website.
    mutating func beginSessionVerification(groups: Set<Group>, sourceDay: String,
                                           at now: Moment, requestID: UUID = UUID()) -> Decision {
        if let activeRequest { return .coalesced(requestID: activeRequest.id) }
        if let gate = checkpoint.gate {
            let remaining = remainingDelay(gate, at: now)
            if remaining > 0 { return .wait(until: now.wallTime.addingTimeInterval(remaining)) }
            checkpoint.gate = nil
        }
        let request = Request(id: requestID, groups: groups.union([.profile]), sourceDay: sourceDay, startedAt: now)
        activeRequest = request
        return .start(request)
    }

    /// Returns false for a cancelled, superseded, or already completed request.
    /// Unknown successful group names cannot poison another group's cadence.
    @discardableResult
    mutating func finish(requestID: UUID, successfulGroups: Set<Group>, failure: Failure? = nil,
                         transientFailedGroups: Set<Group> = [], deferredGroups: Set<Group> = [],
                         at now: Moment) -> Bool {
        guard let request = activeRequest, request.id == requestID else { return false }
        activeRequest = nil
        let acceptedGroups = successfulGroups.intersection(request.groups)
        for group in acceptedGroups {
            checkpoint.successfulGroups[group] = Stamp(moment: now, sourceDay: request.sourceDay)
            checkpoint.groupFailures?[group] = nil
        }
        let failed = transientFailedGroups.intersection(request.groups).subtracting(acceptedGroups)
        for group in failed {
            let previous = min(10, max(0, checkpoint.groupFailures?[group]?.attempts ?? 0))
            let seconds = min(30 * 60, 60 * pow(2, Double(previous)))
            if checkpoint.groupFailures == nil { checkpoint.groupFailures = [:] }
            checkpoint.groupFailures?[group] = GroupFailure(attempts: min(10, previous + 1),
                gate: Gate(startedAt: now, duration: seconds, reason: .transient))
        }
        // Budget-deferred groups remain due; they were not failed or refreshed.
        let accounted = acceptedGroups.union(failed).union(deferredGroups.intersection(request.groups))
        let effectiveFailure = failure ?? (accounted == request.groups ? nil : .transient)
        guard let effectiveFailure else {
            checkpoint.consecutiveTransientFailures = 0
            if checkpoint.gate?.reason != .rateLimit { checkpoint.gate = nil }
            return true
        }
        switch effectiveFailure {
        case .transient:
            let previous = min(10, max(0, checkpoint.consecutiveTransientFailures))
            checkpoint.consecutiveTransientFailures = min(10, previous + 1)
            let seconds = min(30 * 60, 60 * pow(2, Double(previous)))
            setGate(seconds: seconds, reason: .transient, at: now)
        case .rateLimited(let retryAfterSeconds):
            let seconds = max(30 * 60, min(7 * 24 * 60 * 60, max(0, retryAfterSeconds ?? 0)))
            setGate(seconds: TimeInterval(seconds), reason: .rateLimit, at: now)
        case .authenticationExpired: checkpoint.sessionState = .expired
        case .sessionUnsupported: checkpoint.sessionState = .unsupported
        case .securityChallenge: checkpoint.sessionState = .securityChallenge
        case .accessDenied: checkpoint.sessionState = .accessDenied
        }
        return true
    }

    @discardableResult
    mutating func cancel(requestID: UUID) -> Bool {
        guard activeRequest?.id == requestID else { return false }
        activeRequest = nil
        return true
    }

    /// Caller must use this same day when building the connector request. The Mac
    /// calendar date and the account's day must never be mixed implicitly.
    static func sourceDay(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    private func delayUntilDue(_ group: Group, sourceDay: String, trigger: Trigger, at now: Moment) -> TimeInterval {
        // Endpoint failures never hold unrelated healthy groups behind a global gate.
        // Manual refresh still respects this bounded pause.
        if let failure = checkpoint.groupFailures?[group] {
            return remainingDelay(failure.gate, at: now)
        }
        guard let stamp = checkpoint.successfulGroups[group] else { return 0 }
        if group.isDaily && stamp.sourceDay != sourceDay { return 0 }
        guard let elapsed = elapsed(since: stamp.moment, at: now) else { return 0 }
        let manualMinimum = configuration.manualMinimumInterval.isFinite ? min(24 * 60 * 60, max(0, configuration.manualMinimumInterval)) : 30
        let interval = trigger == .manual ? manualMinimum : configuration.cadence(for: group)
        return max(0, interval - elapsed)
    }

    private func elapsed(since earlier: Moment, at now: Moment) -> TimeInterval? {
        if earlier.bootID == now.bootID, earlier.monotonicSeconds.isFinite, now.monotonicSeconds.isFinite,
           now.monotonicSeconds >= earlier.monotonicSeconds {
            return now.monotonicSeconds - earlier.monotonicSeconds
        }
        let wallElapsed = now.wallTime.timeIntervalSince(earlier.wallTime)
        return wallElapsed >= 0 && wallElapsed.isFinite ? wallElapsed : nil
    }

    private func remainingDelay(_ gate: Gate, at now: Moment) -> TimeInterval {
        let duration = gate.duration.isFinite ? min(7 * 24 * 60 * 60, max(0, gate.duration)) : 30 * 60
        // Clock rollback after a reboot cannot remove a rate-limit pause. It can
        // restart at most the original bounded delay; a forward clock in the same
        // boot never skips the monotonic deadline.
        return max(0, duration - (elapsed(since: gate.startedAt, at: now) ?? 0))
    }

    private mutating func setGate(seconds: TimeInterval, reason: GateReason, at now: Moment) {
        if let existing = checkpoint.gate, remainingDelay(existing, at: now) >= seconds { return }
        checkpoint.gate = Gate(startedAt: now, duration: seconds, reason: reason)
    }
}
