import Foundation

/// Private, account-owned recovery of yesterday's completed readings. This is
/// a one-shot lookup, not a history poller: at most six GETs per source day.
struct GarminHistoricalRecovery: Codable {
    static let eligibleGroups: [SyncPolicy.Group] = [.sleep, .hrv, .readiness, .respiration, .vo2Max, .training]
    var sourceDay: String
    var startedAt: SyncPolicy.Moment
    var queued: Set<SyncPolicy.Group> = []
    var attempted: Set<SyncPolicy.Group> = []

    static func previousDay(for sourceDay: String) -> String? {
        guard GarminWebAPI.validDay(sourceDay) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: sourceDay),
              let previous = calendar.date(byAdding: .day, value: -1, to: date) else { return nil }
        let result = formatter.string(from: previous)
        return GarminWebAPI.validDay(result) && result < sourceDay ? result : nil
    }

    func pending(sourceDay: String, at now: SyncPolicy.Moment) -> [SyncPolicy.Group] {
        guard self.sourceDay == sourceDay, Self.previousDay(for: sourceDay) != nil else { return [] }
        let elapsed = startedAt.bootID == now.bootID
            ? now.monotonicSeconds - startedAt.monotonicSeconds
            : now.wallTime.timeIntervalSince(startedAt.wallTime)
        guard elapsed.isFinite, elapsed >= 0, elapsed < 60 * 60 else { return [] }
        return Self.eligibleGroups.filter { queued.contains($0) && !attempted.contains($0) }
    }
}
