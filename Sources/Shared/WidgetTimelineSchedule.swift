import Foundation

/// Intermediate display updates consume the saved Garmin trend, not network
/// requests. WidgetKit retains control of when these dated entries are shown.
enum WidgetTimelineSchedule {
    static func dates(data: WidgetData?, slot: WidgetSlot, from now: Date) -> [Date] {
        guard let data, !data.snapshot.isDemo else { return [now] }
        let profile = slot.profile(in: data.preferences)
        guard profile.contentMode.includesMetrics else { return [now] }
        let selection = slot == .overview
            ? WidgetMetricPolicy.summarySelection(preferences: data.preferences, snapshot: data.snapshot)
            : WidgetMetricPolicy.selection(for: profile, snapshot: data.snapshot)
        guard ([selection.primary] + selection.secondary).contains("bodyBattery") else { return [now] }
        var dates = [now]
        // Include a final non-estimated entry so an expired estimate cannot stay
        // on screen until a delayed provider reload. Never exceed 61 future dates.
        for minute in 1...61 {
            let date = now.addingTimeInterval(Double(minute) * 60)
            if data.snapshot.bodyBatteryEstimate(at: date) == nil {
                if dates.count > 1 || data.snapshot.bodyBatteryEstimate(at: now) != nil { dates.append(date) }
                break
            }
            dates.append(date)
        }
        return dates
    }
}
