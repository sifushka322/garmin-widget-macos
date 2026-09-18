import Foundation

@main
struct BodyBatteryProjectionTests {
    static var checks = 0
    enum Failure: Error { case expectation(String) }
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !value() { throw Failure.expectation(message) }
    }
    static let start = Date(timeIntervalSince1970: 1_789_473_600)
    static func sample(_ minute: Double, _ value: Double) -> MetricReading {
        .init(value: value, measuredAt: start.addingTimeInterval(minute * 60))
    }
    static func main() throws {
        let samples = [sample(0, 80), sample(10, 78), sample(20, 76), sample(30, 74)]
        let anchor = samples.last!
        let date = anchor.measuredAt!
        let projection = BodyBatteryProjection.make(samples: samples, asOf: date)!
        try expect(projection.pointsPerHour == -12, "Linear slope uses Garmin point values and real sample times")
        try expect(projection.value(at: date.addingTimeInterval(300)) == 73, "Five-minute straight-line estimate")
        try expect(projection.value(at: date.addingTimeInterval(359)) == 73, "Estimate advances only once per minute")
        try expect(projection.value(at: date.addingTimeInterval(3601)) == nil, "Expired trend never estimates indefinitely")
        try expect(projection.value(at: date.addingTimeInterval(-1)) == nil, "Clock rollback cannot project backwards")
        try expect(BodyBatteryProjection.make(samples: [sample(0, 80), sample(60, 70)], asOf: start.addingTimeInterval(3600)) == nil, "Sparse report gaps cannot support a current trend")
        try expect(BodyBatteryProjection.make(samples: [sample(0, 80), sample(10, 50)], asOf: start.addingTimeInterval(600)) == nil, "Implausibly steep trend is unavailable")
        try expect(BodyBatteryProjection.make(samples: samples, asOf: date.addingTimeInterval(3601)) == nil, "Polling old samples cannot restart the horizon")
        try expect(BodyBatteryProjection.make(samples: [sample(0, 80), sample(0, 30), sample(10, 78)], asOf: date) == nil, "Conflicting duplicate sample instants are rejected")
        let rising = BodyBatteryProjection.make(samples: [sample(0, 94), sample(10, 96)], asOf: start.addingTimeInterval(600))!
        try expect(rising.value(at: start.addingTimeInterval(4200)) == 100, "Projection clips at the top of Body Battery scale")
        let falling = BodyBatteryProjection.make(samples: [sample(0, 4), sample(10, 2)], asOf: start.addingTimeInterval(600))!
        try expect(falling.value(at: start.addingTimeInterval(4200)) == 0, "Projection clips at zero")
        var snapshot = GarminSnapshot(fetchedAt: date, sourceDate: "2026-09-15", devices: [], metrics: ["bodyBattery": anchor])
        snapshot.bodyBatteryProjection = projection
        let now = date.addingTimeInterval(300)
        try expect(snapshot.bodyBatteryEstimate(at: now, timeZone: TimeZone(secondsFromGMT: 0)!) == 73, "Current actual anchor enables local estimate")
        try expect(snapshot.metrics["bodyBattery"] == anchor, "Estimate does not rewrite actual reading or measuredAt")
        snapshot.metrics["bodyBattery"] = sample(31, 70)
        try expect(snapshot.bodyBatteryEstimate(at: now) == nil, "New Garmin sample invalidates previous trend")
        snapshot.metrics = [:]
        try expect(snapshot.bodyBatteryEstimate(at: now) == nil, "Retained/missing current samples cannot estimate")
        snapshot.metrics = ["bodyBattery": anchor]; snapshot.isDemo = true
        try expect(snapshot.bodyBatteryEstimate(at: now) == nil, "Demo does not imply live projection")
        snapshot.isDemo = false; snapshot.sourceDate = "2026-09-14"
        try expect(snapshot.bodyBatteryEstimate(at: now) == nil, "Previous day cannot estimate today")
        snapshot.sourceDate = "2026-09-15"
        var midnight = snapshot
        let oldAnchor = MetricReading(value: 40, measuredAt: ISO8601DateFormatter().date(from: "2026-09-15T23:50:00Z")!)
        midnight.sourceDate = "2026-09-16"
        midnight.metrics["bodyBattery"] = oldAnchor
        midnight.bodyBatteryProjection = .init(anchor: oldAnchor, pointsPerHour: -6,
            validUntil: oldAnchor.measuredAt!.addingTimeInterval(3600))
        try expect(midnight.bodyBatteryEstimate(at: oldAnchor.measuredAt!.addingTimeInterval(1200),
            timeZone: TimeZone(secondsFromGMT: 0)!) == nil,
            "A previous-day sample cannot be projected even if an endpoint labels its envelope with today")
        let roundTrip = try AppJSON.decoder.decode(GarminSnapshot.self, from: AppJSON.encoder.encode(snapshot))
        try expect(roundTrip.bodyBatteryProjection == projection, "Projection survives cache without rewriting actual value")
        let payload: [[String: Any]] = [["bodyBatteryValuesArray": samples.map { [$0.measuredAt!.timeIntervalSince1970 * 1000, $0.value] }]]
        let normalized = GarminPayloadNormalizer.normalize(group: "body_battery", payload: payload, asOf: date.addingTimeInterval(-1))
        try expect(normalized["bodyBattery"] == sample(20, 76), "Future report points never become actual readings")
        try expect(GarminPayloadNormalizer.bodyBatteryProjection(payload: payload, asOf: date) == projection, "Parser supplies the same bounded series trend")
        let summary = GarminPayloadNormalizer.normalize(group: "stats", payload: ["bodyBatteryMostRecentValue": 60])
        try expect(summary["bodyBattery"] == .init(value: 60), "Summary latest scalar is supported with no invented measurement time")
        for invalid: Any in [true, "70", -1, 101, NSNull()] {
            try expect(GarminPayloadNormalizer.normalize(group: "stats", payload: ["bodyBatteryMostRecentValue": invalid]).isEmpty, "Invalid scalar stays absent")
        }
        var cache = GarminWebCache()
        cache.groups["body_battery"] = .init(sourceDay: "2026-09-15", retrievedAt: now, metrics: ["bodyBattery": anchor], bodyBatteryProjection: projection)
        cache.groups["stats"] = .init(sourceDay: "2026-09-15", retrievedAt: date.addingTimeInterval(1800), metrics: summary)
        let latest = cache.snapshot(sourceDay: "2026-09-15", warnings: [])
        try expect(latest.metrics["bodyBattery"]?.value == 60 && latest.bodyBatterySourceGroup == "stats", "Current summary scalar advances sparse daily series")
        try expect(latest.metrics["bodyBattery"]?.measuredAt == nil && latest.bodyBatteryProjection == nil, "Summary cannot borrow the old report time or trend")
        cache.groups["stats"]?.retrievedAt = now
        let freshReport = cache.snapshot(sourceDay: "2026-09-15", warnings: [])
        try expect(freshReport.metrics["bodyBattery"] == anchor, "A fresh timed sample wins over a conflicting undated summary even fetched later")
        cache.groups["stats"]?.metrics["bodyBattery"] = .init(value: 74)
        let agreeing = cache.snapshot(sourceDay: "2026-09-15", warnings: [])
        try expect(agreeing.metrics["bodyBattery"] == anchor && agreeing.bodyBatteryProjection == projection, "Agreeing scalar preserves actual report and its trend")
        cache.groups["stats"]?.metrics["bodyBattery"] = .init(value: 60)
        cache.groups["stats"]?.retrievedAt = start
        let newerReport = cache.snapshot(sourceDay: "2026-09-15", warnings: [])
        try expect(newerReport.metrics["bodyBattery"] == anchor, "Later measured report wins over older summary observation")
        cache.groups["body_battery"]?.sourceDay = "2026-09-14"
        try expect(cache.snapshot(sourceDay: "2026-09-15", warnings: []).metrics["bodyBattery"]?.value == 60, "Current summary is fallback when daily series is absent")
        print("PASS: \(checks) Body Battery refresh and projection checks")
    }
}
