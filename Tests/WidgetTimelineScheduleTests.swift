import Foundation
import WidgetKit

@main
struct WidgetTimelineScheduleTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ description: String) {
            checks += 1
            guard value else { fatalError(description) }
        }
        let now = Date(timeIntervalSince1970: 1_789_812_000)
        let anchor = MetricReading(value: 60, measuredAt: now)
        var snapshot = GarminSnapshot(fetchedAt: now, sourceDate: SyncPolicy.sourceDay(for: now, timeZone: .current),
                                      devices: [], metrics: ["bodyBattery": anchor])
        snapshot.bodyBatteryProjection = .init(anchor: anchor, pointsPerHour: -12, validUntil: now.addingTimeInterval(3600))
        var data = WidgetData(preferences: .init(), snapshot: snapshot, isConnected: true)
        let dates = WidgetTimelineSchedule.dates(data: data, slot: .day, from: now)
        check(dates.count == 62, "One current, 60 minute estimates, and one expiry entry")
        check(dates.first == now && dates.last == now.addingTimeInterval(3660), "Schedule covers the bounded estimate and its expiry")
        check(zip(dates, dates.dropFirst()).allSatisfy { $1.timeIntervalSince($0) == 60 }, "Intermediate entries are one minute apart")
        let midway = MetricFormatter(snapshot: snapshot, language: .en, now: now.addingTimeInterval(1800))
        check(midway.display("bodyBattery") == "≈54", "Widget display changes without replacing the saved Garmin reading")
        check(midway.context("bodyBattery")?.contains("Linear estimate") == true, "Estimate provenance remains explicit")
        check(snapshot.metrics["bodyBattery"] == anchor, "Display calculation preserves actual sample")
        let expired = MetricFormatter(snapshot: snapshot, language: .en, now: dates.last!)
        check(expired.display("bodyBattery") == "60" && !expired.isEstimated("bodyBattery"), "Expired timeline restores last actual value")
        check(WidgetTimelineSchedule.dates(data: data, slot: .training, from: now).count == 1, "Training calendar needs no Body Battery ticks")
        data.preferences.summaryMetrics = ["steps"]
        data.snapshot.metrics["steps"] = .init(value: 1000)
        check(WidgetTimelineSchedule.dates(data: data, slot: .overview, from: now).count == 1, "Summary with no Body Battery has no unnecessary entries")
        data.snapshot.isDemo = true
        check(WidgetTimelineSchedule.dates(data: data, slot: .day, from: now).count == 1, "Gallery/demo stays stable")
        check(WidgetTimelineSchedule.dates(data: nil, slot: .day, from: now) == [now], "No data creates only current entry")
        data.snapshot = snapshot
        data.snapshot.bodyBatteryProjection = nil
        check(WidgetTimelineSchedule.dates(data: data, slot: .day, from: now).count == 1, "No verified trend does not manufacture estimates")
        let halfMinute = now.addingTimeInterval(30)
        let aligned = BodyBatteryDisplaySchedule.dates(snapshot: snapshot, from: halfMinute)
        check(aligned[1] == now.addingTimeInterval(60), "First app/widget tick follows Garmin's actual minute, not opening time")
        check(BodyBatteryDisplaySchedule.dates(snapshot: snapshot, metricID: "steps", from: now) == [now], "Static metrics need no minute clock")
        check(BodyBatteryDisplaySchedule.dates(snapshot: snapshot, isVisible: false, from: now) == [now], "Closed or occluded windows have no future display work")
        let afterExpiry = now.addingTimeInterval(3660)
        check(BodyBatteryDisplaySchedule.dates(snapshot: snapshot, from: afterExpiry) == [afterExpiry], "An expired forecast cannot retain a periodic clock")
        let rollback = now.addingTimeInterval(-30)
        check(BodyBatteryDisplaySchedule.dates(snapshot: snapshot, from: rollback) == [rollback], "Clock rollback cannot project a future anchor")

        var sport = data
        for id in WidgetMetricPolicy.sport where id != "bodyBattery" { sport.snapshot.metrics[id] = .init(value: 50) }
        check(WidgetTimelineSchedule.dates(data: sport, slot: .sport, family: .systemSmall, from: now) == [now], "Small sport displays readiness only, so hidden Body Battery has no timeline")
        check(WidgetTimelineSchedule.dates(data: sport, slot: .sport, family: .systemMedium, from: now) == [now], "Medium sport does not schedule an offscreen fallback")
        sport.snapshot.metrics = ["steps": .init(value: 500), "bodyBattery": anchor]
        check(WidgetTimelineSchedule.dates(data: sport, slot: .sport, family: .systemSmall, from: now).count > 1, "A fallback Body Battery that becomes primary still updates")
        var summary = data
        summary.preferences.summaryMetrics = ["steps", "stress", "sleepScore", "bodyBattery"]
        for id in ["steps", "stress", "sleepScore"] { summary.snapshot.metrics[id] = .init(value: 50) }
        check(WidgetTimelineSchedule.dates(data: summary, slot: .overview, family: .systemSmall, from: now) == [now], "Small summary ignores its hidden fourth metric")
        check(WidgetTimelineSchedule.dates(data: summary, slot: .overview, family: .systemMedium, from: now) == [now], "Medium summary ignores its hidden fourth metric")
        check(WidgetTimelineSchedule.dates(data: summary, slot: .overview, family: .systemLarge, from: now).count > 1, "Large summary updates its visible fourth Body Battery")

        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let lateAnchor = MetricReading(value: 60, measuredAt: midnight.addingTimeInterval(-90))
        var late = snapshot
        late.metrics["bodyBattery"] = lateAnchor
        late.bodyBatteryProjection = .init(anchor: lateAnchor, pointsPerHour: -12, validUntil: lateAnchor.measuredAt!.addingTimeInterval(3600))
        let lateDates = BodyBatteryDisplaySchedule.dates(snapshot: late, from: midnight.addingTimeInterval(-30))
        check(lateDates == [midnight.addingTimeInterval(-30), midnight], "Source-day rollover has one exact midnight expiry, not continued estimates")
        check(late.metrics["bodyBattery"] == lateAnchor, "Scheduling never changes the saved actual source reading")
        let restored = try AppJSON.decoder.decode(WidgetData.self, from: AppJSON.encoder.encode(WidgetData(preferences: .init(), snapshot: snapshot, isConnected: true)))
        check(WidgetTimelineSchedule.dates(data: restored, slot: .day, from: now) == dates, "Widget wire format preserves projected schedule")
        print("PASS: \(checks) projected widget timeline checks")
    }
}
