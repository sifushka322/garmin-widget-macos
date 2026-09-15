import Foundation
import Darwin

/// No network, app lifecycle, wall-clock sleeps, credentials, or Keychain needed.
/// Compile this file with Sources/Shared/SyncPolicy.swift as a standalone executable.
@main
struct SyncPolicyTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var checks = 0
    static let baseline = Date(timeIntervalSince1970: 1_789_459_200)
    static let day = "2026-09-15"

    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        guard try value() else { throw Failure(description: message) }
    }

    static func moment(_ seconds: Double = 0, wallAdjustment: Double = 0, boot: String = "test-boot") -> SyncPolicy.Moment {
        .init(wallTime: baseline.addingTimeInterval(seconds + wallAdjustment), monotonicSeconds: 10_000 + seconds, bootID: boot)
    }

    static func ready() -> SyncPolicy {
        var policy = SyncPolicy()
        policy.sessionBecameAvailable()
        return policy
    }

    static func started(_ decision: SyncPolicy.Decision, _ message: String) throws -> SyncPolicy.Request {
        guard case .start(let request) = decision else { throw Failure(description: message + ": \(decision)") }
        checks += 1
        return request
    }

    static func delay(_ decision: SyncPolicy.Decision, from now: SyncPolicy.Moment) throws -> Double {
        guard case .wait(let until) = decision else { throw Failure(description: "Expected wait, got \(decision)") }
        checks += 1
        return until.timeIntervalSince(now.wallTime)
    }

    static func testPerGroupCadenceAndWake() throws {
        var policy = ready()
        let groups: Set<SyncPolicy.Group> = [.stats, .bodyBattery, .sleep, .weight, .devices]
        let initial = try started(policy.begin(groups: groups, sourceDay: day, at: moment()), "Initial measurements should load")
        try expect(initial.groups == groups, "The first load must cover requested groups")
        policy.finish(requestID: initial.id, successfulGroups: groups, at: moment())

        let freshWake = try delay(policy.begin(groups: groups, sourceDay: day, trigger: .wake, at: moment(10)), from: moment(10))
        try expect(freshWake == 890, "Waking immediately must not repeat a fresh batch")
        let firstDue = try started(policy.begin(groups: groups, sourceDay: day, at: moment(900)), "Fast data should be due after 15 minutes")
        try expect(firstDue.groups == [.stats, .bodyBattery], "Metadata, sleep and weight must not be queried at the fast cadence")
        policy.finish(requestID: firstDue.id, successfulGroups: firstDue.groups, at: moment(900))

        let next = try started(policy.begin(groups: groups, sourceDay: day, at: moment(1800)), "Sleep eventually becomes due")
        try expect(next.groups == [.stats, .bodyBattery, .sleep], "Half-hour refresh should preserve slower weight and device cadence")
        policy.finish(requestID: next.id, successfulGroups: next.groups, at: moment(1800))
        let longWake = try started(policy.begin(groups: groups, sourceDay: day, trigger: .wake, at: moment(12 * 3600)), "Resume after sleep should catch up once")
        try expect(longWake.groups == [.stats, .bodyBattery, .sleep, .weight], "Long sleep must not manufacture multiple catch-up batches or refetch daily metadata")
        try expect(policy.begin(groups: groups, sourceDay: day, trigger: .wake, at: moment(12 * 3600)) == .coalesced(requestID: longWake.id),
                   "Several wake/timer notifications must join the same request")
    }

    static func testCoalescingAndNewProfiles() throws {
        var policy = ready()
        let initial = try started(policy.begin(groups: [.stats], sourceDay: day, at: moment()), "Stats should begin")
        for trigger in [SyncPolicy.Trigger.automatic, .wake, .manual, .profilesChanged] {
            try expect(policy.begin(groups: [.stats, .sleep], sourceDay: day, trigger: trigger, at: moment(1)) == .coalesced(requestID: initial.id),
                       "Concurrent triggers must not start an overlapping request")
        }
        policy.finish(requestID: initial.id, successfulGroups: [.stats], at: moment(2))
        let followUp = try started(policy.begin(groups: [.stats, .sleep], sourceDay: day, trigger: .profilesChanged, at: moment(2)),
                                   "Re-evaluating the current profile after completion should load newly selected groups")
        try expect(followUp.groups == [.sleep], "Profile changes must not reload groups just received")
        policy.finish(requestID: followUp.id, successfulGroups: [.sleep], at: moment(3))
        let manual = try delay(policy.begin(groups: [.stats, .sleep], sourceDay: day, trigger: .manual, at: moment(4)), from: moment(4))
        try expect(manual == 28, "Repeated refresh clicks should have a short coalescing window")
        let forced = try started(policy.begin(groups: [.stats, .sleep], sourceDay: day, trigger: .manual, at: moment(33)), "A later explicit refresh should bypass normal cadence")
        try expect(forced.groups == [.stats, .sleep], "Manual refresh should include the explicitly requested groups")
    }

    static func testCancellationAndLateCompletions() throws {
        var policy = ready()
        let old = try started(policy.begin(groups: [.stats], sourceDay: day, at: moment()), "Initial work should start")
        try expect(policy.cancel(requestID: old.id), "Cancelling the current transport should invalidate it")
        let current = try started(policy.begin(groups: [.stats], sourceDay: day, at: moment(1)), "Wake can create replacement work after cancellation")
        try expect(!policy.finish(requestID: old.id, successfulGroups: [.stats], failure: .authenticationExpired, at: moment(2)),
                   "A cancelled request must not expire the new session or update freshness")
        try expect(policy.activeRequest?.id == current.id, "A late result must not clear the replacement request")
        try expect(policy.checkpoint.sessionState == .available, "A stale auth event must not overwrite current authentication")
        try expect(policy.finish(requestID: current.id, successfulGroups: [.stats, .devices], at: moment(3)), "The current result should be accepted")
        try expect(policy.checkpoint.successfulGroups[.devices] == nil, "A result cannot claim freshness for an unrequested group")
        try expect(!policy.finish(requestID: current.id, successfulGroups: [.stats], at: moment(4)), "Duplicate completion must be ignored")
    }

    static func testPartialFailureAndBackoff() throws {
        var policy = ready()
        let request = try started(policy.begin(groups: [.stats, .sleep], sourceDay: day, at: moment()), "Initial request should begin")
        policy.finish(requestID: request.id, successfulGroups: [.stats], failure: .transient, at: moment())
        try expect(policy.checkpoint.successfulGroups[.stats] != nil && policy.checkpoint.successfulGroups[.sleep] == nil,
                   "Partial failures must preserve successful groups without falsely stamping failed ones")
        let initialWait = try delay(policy.begin(groups: [.stats, .sleep], sourceDay: day, trigger: .manual, at: moment(10)), from: moment(10))
        try expect(initialWait == 50, "Manual refresh must respect transient backoff")
        let retry = try started(policy.begin(groups: [.stats, .sleep], sourceDay: day, at: moment(60)), "The failed group may retry after backoff")
        try expect(retry.groups == [.sleep], "Retrying a partial failure must not reload successful groups")
        policy.finish(requestID: retry.id, successfulGroups: [], failure: .transient, at: moment(60))
        let secondWait = try delay(policy.begin(groups: [.sleep], sourceDay: day, at: moment(60)), from: moment(60))
        try expect(secondWait == 120, "Repeated transient failure must increase the delay")
        let recovered = try started(policy.begin(groups: [.sleep], sourceDay: day, at: moment(180)), "A later retry should be possible")
        policy.finish(requestID: recovered.id, successfulGroups: [.sleep], at: moment(180))
        try expect(policy.checkpoint.consecutiveTransientFailures == 0, "Recovery must reset the transient retry count")

        var capped = ready()
        var seconds = 0.0
        for attempt in 0..<9 {
            let run = try started(capped.begin(groups: [.stats], sourceDay: day, at: moment(seconds)), "Retry should become eligible at its deadline")
            capped.finish(requestID: run.id, successfulGroups: [], failure: .transient, at: moment(seconds))
            let pause = try delay(capped.begin(groups: [.stats], sourceDay: day, at: moment(seconds)), from: moment(seconds))
            try expect(pause == min(1800, 60 * pow(2, Double(attempt))), "Backoff must rise to a finite 30-minute cap")
            seconds += pause
        }
    }

    static func testRetryAfterAndClockChanges() throws {
        for (server, expected) in [(nil, 1800), (-1, 1800), (30, 1800), (3600, 3600), (Int.max, 604800)] as [(Int?, Int)] {
            var policy = ready()
            let request = try started(policy.begin(groups: [.stats], sourceDay: day, at: moment()), "Initial request should start")
            policy.finish(requestID: request.id, successfulGroups: [], failure: .rateLimited(retryAfterSeconds: server), at: moment())
            let wait = try delay(policy.begin(groups: [.stats], sourceDay: day, trigger: .manual, at: moment()), from: moment())
            try expect(wait == Double(expected), "Retry-After must respect the minimum, server delay, and upper bound")
            policy.sessionBecameAvailable()
            let changedWall = moment(60, wallAdjustment: 10 * 86400)
            let remaining = try delay(policy.begin(groups: [.stats], sourceDay: "2026-09-25", trigger: .manual, at: changedWall), from: changedWall)
            try expect(remaining == Double(expected - 60), "Moving the wall clock forward, changing the day, and reauthenticating must not bypass a server pause")
        }

        var policy = ready()
        let request = try started(policy.begin(groups: [.stats], sourceDay: day, at: moment()), "Initial request should start")
        policy.finish(requestID: request.id, successfulGroups: [], failure: .rateLimited(retryAfterSeconds: 3600), at: moment())
        let bytes = try JSONEncoder().encode(policy.checkpoint)
        let restoredCheckpoint = try JSONDecoder().decode(SyncPolicy.Checkpoint.self, from: bytes)
        var restored = SyncPolicy(checkpoint: restoredCheckpoint)
        let backward = moment(120, wallAdjustment: -86400)
        try expect(try delay(restored.begin(groups: [.stats], sourceDay: day, at: backward), from: backward) == 3480,
                   "Clock rollback in the same boot should still use elapsed monotonic time")
        let rebootedBackward = moment(120, wallAdjustment: -86400, boot: "new-boot")
        try expect(try delay(restored.begin(groups: [.stats], sourceDay: day, at: rebootedBackward), from: rebootedBackward) == 3600,
                   "Clock rollback across boots must preserve a bounded original pause")
        restored.disconnect()
        restored.sessionBecameAvailable(clearCadence: true)
        try expect(try delay(restored.begin(groups: [.stats], sourceDay: day, at: moment(120)), from: moment(120)) == 3480,
                   "Disconnect/reconnect must not erase Retry-After")
    }

    static func testExpiredSessionsDoNotLoop() throws {
        for (failure, state) in [(SyncPolicy.Failure.authenticationExpired, SyncPolicy.SessionState.expired),
                                 (.sessionUnsupported, .unsupported), (.securityChallenge, .securityChallenge), (.accessDenied, .accessDenied)] {
            var policy = ready()
            let request = try started(policy.begin(groups: [.stats], sourceDay: day, at: moment()), "Initial request should start")
            policy.finish(requestID: request.id, successfulGroups: [], failure: failure, at: moment())
            for trigger in [SyncPolicy.Trigger.automatic, .wake, .manual] {
                try expect(policy.begin(groups: [.stats], sourceDay: day, trigger: trigger, at: moment(86400)) == .needsUserAction(state),
                           "A rejected session must never trigger an unattended sign-in loop")
            }
            let bytes = try JSONEncoder().encode(policy.checkpoint)
            var restored = SyncPolicy(checkpoint: try JSONDecoder().decode(SyncPolicy.Checkpoint.self, from: bytes))
            try expect(restored.begin(groups: [.stats], sourceDay: day, at: moment(86400)) == .needsUserAction(state),
                       "Restarting the app must not retry a known blocked session")
            restored.sessionBecameAvailable()
            _ = try started(restored.begin(groups: [.stats], sourceDay: day, at: moment(86400)), "Explicit session restoration should allow syncing again")
        }
    }

    static func testCalendarRolloverAndCheckpointPrivacy() throws {
        let instant = ISO8601DateFormatter().date(from: "2026-09-15T22:30:00Z")!
        try expect(SyncPolicy.sourceDay(for: instant, timeZone: TimeZone(secondsFromGMT: 3 * 3600)!) == "2026-09-16", "The source day must follow the chosen timezone")
        try expect(SyncPolicy.sourceDay(for: instant, timeZone: TimeZone(secondsFromGMT: -7 * 3600)!) == "2026-09-15", "The same instant may require a different Garmin calendar day")
        var policy = ready()
        let request = try started(policy.begin(groups: [.stats, .sleep, .devices], sourceDay: day, at: moment()), "Initial request should start")
        policy.finish(requestID: request.id, successfulGroups: request.groups, at: moment())
        let rollover = try started(policy.begin(groups: [.stats, .sleep, .devices], sourceDay: "2026-09-16", at: moment(60)), "Daily measurements should refresh at calendar rollover")
        try expect(rollover.groups == [.stats, .sleep], "A new date must not force another device-list request")
        let bytes = try JSONEncoder().encode(policy.checkpoint)
        let json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        try expect(json["activeRequest"] == nil, "Checkpoints must not persist a busy request")
        try expect(!String(decoding: bytes, as: UTF8.self).contains(rollover.id.uuidString), "A restored policy must not accept a stale in-flight request ID")
        try expect(Set(json.keys).isSubset(of: ["version", "sessionState", "successfulGroups", "consecutiveTransientFailures", "gate"]),
                   "Scheduler checkpoints must contain metadata only")
        let restored = SyncPolicy(checkpoint: try JSONDecoder().decode(SyncPolicy.Checkpoint.self, from: bytes))
        try expect(restored.activeRequest == nil, "A process restart must never restore a permanent busy lock")
        try expect(!SyncPolicy.Group.currentMetrics.contains(.activities) && !SyncPolicy.Group.currentMetrics.contains(.plannedWorkouts),
                   "Future workout endpoints must stay opt-in until the connector supports them")
    }

    static func testUnsupportedCheckpointAndInvalidCadence() throws {
        var checkpoint = SyncPolicy.Checkpoint()
        checkpoint.version = 99
        checkpoint.sessionState = .available
        var policy = SyncPolicy(checkpoint: checkpoint)
        try expect(policy.begin(groups: [.stats], sourceDay: day, at: moment()) == .needsUserAction(.unavailable),
                   "An unsupported checkpoint must not silently claim an available session")
        for value in [-1.0, .infinity, .nan, .greatestFiniteMagnitude] {
            var configuration = SyncPolicy.Configuration()
            configuration.refreshInterval = value
            configuration.cadenceOverrides[.sleep] = value
            for group in SyncPolicy.Group.allCases {
                let seconds = configuration.cadence(for: group)
                try expect(seconds.isFinite && seconds >= 30 && seconds <= 7 * 86400,
                           "Malformed cadence input must not create an invalid or unbounded timer")
            }
        }
    }

    static func testBootstrapVerification() throws {
        var policy = SyncPolicy()
        let first = try started(policy.beginSessionVerification(groups: [.stats], sourceDay: day, at: moment()), "Bootstrap needs a tracked request before network I/O")
        try expect(first.groups == [.profile, .stats], "Verification must include proof from the profile endpoint")
        try expect(policy.checkpoint.sessionState == .unavailable, "Starting verification alone must never claim an available session")
        policy.finish(requestID: first.id, successfulGroups: [], failure: .authenticationExpired, at: moment())
        try expect(policy.begin(groups: [.stats], sourceDay: day, at: moment(10)) == .needsUserAction(.expired), "Bootstrap rejection must block unattended retry")
        let explicit = try started(policy.beginSessionVerification(groups: [.stats], sourceDay: day, at: moment(10)), "A completed user sign-in may verify an expired session")
        policy.finish(requestID: explicit.id, successfulGroups: [], failure: .rateLimited(retryAfterSeconds: 3600), at: moment(10))
        try expect(try delay(policy.beginSessionVerification(groups: [.stats], sourceDay: day, at: moment(11)), from: moment(11)) == 3599,
                   "Explicit verification must still respect a server pause")
    }

    static func main() {
        do {
            try testPerGroupCadenceAndWake()
            try testCoalescingAndNewProfiles()
            try testCancellationAndLateCompletions()
            try testPartialFailureAndBackoff()
            try testRetryAfterAndClockChanges()
            try testExpiredSessionsDoNotLoop()
            try testCalendarRolloverAndCheckpointPrivacy()
            try testUnsupportedCheckpointAndInvalidCadence()
            try testBootstrapVerification()
            print("PASS: \(checks) sync-policy checks")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
