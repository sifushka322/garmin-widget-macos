import Foundation

extension GarminSnapshot {
    var hasMeasurements: Bool { !metrics.isEmpty || !retainedMetrics.isEmpty }

    func visibleReading(_ id: String) -> MetricReading? { metrics[id] ?? retainedMetrics[id]?.reading }

    var hasUnchangedMeasurements: Bool {
        guard hasMeasurements, let checked = groupUpdatedAt.values.max(),
              let changed = (Array(metricChangedAt.values) + retainedMetrics.values.map(\.changedAt)).max() else { return false }
        return checked > changed
    }

    func metricUpdatedAt(_ id: String) -> Date? {
        if metrics[id] == nil { return retainedMetrics[id]?.retrievedAt }
        guard metrics[id] != nil else { return nil }
        let groups = GarminWebAPI.requiredGroups(metricIDs: [id]).subtracting([.profile, .devices])
        // Daily stats owns resting HR whenever it supplies the value.
        let stamps = groups.compactMap { groupUpdatedAt[$0.rawValue] }
        return stamps.min() ?? (fetchedAt == .distantPast ? nil : fetchedAt)
    }

    func metricIsStale(_ id: String, at now: Date, timeZone: TimeZone = .autoupdatingCurrent,
                       staleInterval: TimeInterval) -> Bool {
        guard !isDemo, let updated = metricUpdatedAt(id) else { return false }
        return retainedMetrics[id] != nil || sourceDate != SyncPolicy.sourceDay(for: now, timeZone: timeZone)
            || now.timeIntervalSince(updated) > staleInterval
    }
}
