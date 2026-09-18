import Foundation
import WidgetKit

/// One bounded display schedule shared by the app and widgets. It is anchored to
/// Garmin's measurement minute, never to a fetch or a window-opening timestamp.
enum BodyBatteryDisplaySchedule {
    static func dates(snapshot: GarminSnapshot, metricID: String = "bodyBattery",
                      isVisible: Bool = true, from now: Date,
                      timeZone: TimeZone = .autoupdatingCurrent) -> [Date] {
        guard isVisible, metricID == "bodyBattery", !snapshot.isDemo,
              let projection = snapshot.bodyBatteryProjection,
              let anchor = projection.anchor.measuredAt, now >= anchor, now <= projection.validUntil,
              snapshot.metrics["bodyBattery"] == projection.anchor,
              snapshot.sourceDate == SyncPolicy.sourceDay(for: now, timeZone: timeZone),
              snapshot.sourceDate == SyncPolicy.sourceDay(for: anchor, timeZone: timeZone) else { return [now] }
        let elapsedMinutes = floor(now.timeIntervalSince(anchor) / 60)
        guard elapsedMinutes.isFinite, elapsedMinutes <= 60 else { return [now] }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        var dates = [now]
        // Include one final actual-reading entry when the projection expires.
        // No repeating timer survives the final entry or the source-day boundary.
        for minute in max(1, Int(elapsedMinutes) + 1)...61 {
            let tick = anchor.addingTimeInterval(Double(minute) * 60)
            // value(at:) accepts the endpoint itself. The first invalid instant
            // must restore the actual value instead of retaining it another minute.
            let expiry = projection.validUntil.addingTimeInterval(0.001)
            let boundedTick = min(tick, expiry)
            let date = midnight.map { min(boundedTick, $0) } ?? boundedTick
            if snapshot.bodyBatteryEstimate(at: date, timeZone: timeZone) == nil {
                if dates.count > 1 || snapshot.bodyBatteryEstimate(at: now, timeZone: timeZone) != nil { dates.append(date) }
                break
            }
            dates.append(date)
        }
        return dates
    }
}

/// Only metrics actually rendered in this family require intermediate entries.
/// WidgetKit retains control of when these dated entries are shown.
enum WidgetTimelineSchedule {
    static func visibleMetricIDs(data: WidgetData, slot: WidgetSlot, family: WidgetFamily) -> [String] {
        let profile = slot.profile(in: data.preferences)
        guard profile.contentMode.includesMetrics else { return [] }
        let selection = slot == .overview
            ? WidgetMetricPolicy.summarySelection(preferences: data.preferences, snapshot: data.snapshot)
            : WidgetMetricPolicy.selection(for: profile, snapshot: data.snapshot)
        let secondaryCount: Int
        if slot == .overview {
            // SummaryWidgetView renders 1 / 2 / 6 secondary metrics.
            secondaryCount = family == .systemSmall ? 1 : (family == .systemMedium ? 2 : 6)
        } else {
            // GarminWidgetView uses these exact family/density limits.
            switch family {
            case .systemSmall: secondaryCount = 0
            case .systemMedium: secondaryCount = profile.density == .compact ? 3 : 2
            default: secondaryCount = profile.density == .compact ? 8 : 6
            }
        }
        return [selection.primary] + Array(selection.secondary.prefix(secondaryCount))
    }

    static func dates(data: WidgetData?, slot: WidgetSlot, family: WidgetFamily = .systemLarge,
                      from now: Date) -> [Date] {
        guard let data, !data.snapshot.isDemo,
              visibleMetricIDs(data: data, slot: slot, family: family).contains("bodyBattery") else { return [now] }
        return BodyBatteryDisplaySchedule.dates(snapshot: data.snapshot, from: now)
    }
}
