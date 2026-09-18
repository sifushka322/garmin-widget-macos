import Foundation

/// A bounded, local straight-line estimate from Garmin's recorded samples.
/// This is not a Garmin forecast, and never replaces the recorded reading.
struct BodyBatteryProjection: Codable, Equatable {
    var anchor: MetricReading
    var pointsPerHour: Double
    var validUntil: Date

    func value(at now: Date) -> Double? {
        guard let date = anchor.measuredAt, anchor.value.isFinite,
              (0...100).contains(anchor.value), pointsPerHour.isFinite,
              abs(pointsPerHour) <= 60, now >= date,
              validUntil > date, validUntil.timeIntervalSince(date) <= 3600,
              now <= validUntil else { return nil }
        // A minute tick needs no request and does not change the measurement time.
        let minutes = floor(now.timeIntervalSince(date) / 60)
        guard minutes >= 1 else { return nil }
        return min(100, max(0, anchor.value + pointsPerHour * minutes / 60))
    }

    static func make(samples: [MetricReading], asOf now: Date) -> BodyBatteryProjection? {
        let ordered = samples.filter {
            $0.value.isFinite && (0...100).contains($0.value) && $0.measuredAt.map { $0 <= now } == true
        }.sorted { $0.measuredAt! < $1.measuredAt! }
        guard let last = ordered.last, let date = last.measuredAt,
              now.timeIntervalSince(date) <= 3600 else { return nil }
        let recent = ordered.filter { date.timeIntervalSince($0.measuredAt!) <= 3600 }
        guard let first = recent.first, let start = first.measuredAt,
              date.timeIntervalSince(start) >= 600 else { return nil }
        // Do not bridge long recording gaps or conflicting points at one instant.
        for (lhs, rhs) in zip(recent, recent.dropFirst()) {
            let gap = rhs.measuredAt!.timeIntervalSince(lhs.measuredAt!)
            guard gap <= 1200, gap > 0 || lhs.value == rhs.value else { return nil }
        }
        let slope = (last.value - first.value) / date.timeIntervalSince(start) * 3600
        guard slope.isFinite, abs(slope) <= 60 else { return nil }
        return .init(anchor: last, pointsPerHour: slope, validUntil: date.addingTimeInterval(3600))
    }
}

extension GarminSnapshot {
    func bodyBatteryEstimate(at now: Date, timeZone: TimeZone = .autoupdatingCurrent) -> Double? {
        guard !isDemo, sourceDate == SyncPolicy.sourceDay(for: now, timeZone: timeZone),
              let projection = bodyBatteryProjection,
              let measuredAt = projection.anchor.measuredAt,
              sourceDate == SyncPolicy.sourceDay(for: measuredAt, timeZone: timeZone),
              metrics["bodyBattery"] == projection.anchor else { return nil }
        return projection.value(at: now)
    }
}
