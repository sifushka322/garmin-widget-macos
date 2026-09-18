import Foundation

extension GarminSnapshot {
    var hasMeasurements: Bool {
        Set(metrics.keys).union(retainedMetrics.keys).contains { MetricDefinition.isSupported($0) }
    }

    var hasRetainedTimeSensitiveMetrics: Bool {
        retainedMetrics.keys.contains { MetricDefinition.isSupported($0) && MetricDefinition.find($0).isTimeSensitive }
    }

    func visibleReading(_ id: String) -> MetricReading? { metrics[id] ?? retainedMetrics[id]?.reading }

    var hasUnchangedMeasurements: Bool {
        let ids = Set(metrics.keys).union(retainedMetrics.keys).filter {
            MetricDefinition.isSupported($0) && MetricDefinition.find($0).isTimeSensitive
        }
        guard let checked = ids.compactMap({ metricUpdatedAt($0) }).max(),
              let changed = ids.compactMap({ metricChangedAt[$0] ?? retainedMetrics[$0]?.changedAt }).max() else { return false }
        return checked > changed
    }

    func metricUpdatedAt(_ id: String) -> Date? {
        if metrics[id] == nil { return retainedMetrics[id]?.retrievedAt }
        guard metrics[id] != nil else { return nil }
        if id == "bodyBattery" {
            // Before the source field existed, only the daily report supplied
            // Body Battery. An unrelated older stats fetch must not age it.
            let group = bodyBatterySourceGroup ?? "body_battery"
            return groupUpdatedAt[group] ?? (fetchedAt == .distantPast ? nil : fetchedAt)
        }
        let groups = GarminWebAPI.requiredGroups(metricIDs: [id]).subtracting([.profile, .devices])
        // Daily stats owns resting HR whenever it supplies the value.
        let stamps = groups.compactMap { groupUpdatedAt[$0.rawValue] }
        return stamps.min() ?? (fetchedAt == .distantPast ? nil : fetchedAt)
    }

    func metricIsStale(_ id: String, at now: Date, timeZone: TimeZone = .autoupdatingCurrent,
                       staleInterval: TimeInterval) -> Bool {
        guard !isDemo, MetricDefinition.isSupported(id), MetricDefinition.find(id).isTimeSensitive,
              let updated = metricUpdatedAt(id) else { return false }
        return retainedMetrics[id] != nil || sourceDate != SyncPolicy.sourceDay(for: now, timeZone: timeZone)
            || now.timeIntervalSince(updated) > staleInterval
            // Re-fetching the same old Body Battery sample does not make the
            // watch measurement current. Keep retrieval and sample time distinct.
            || (id == "bodyBattery" && visibleReading(id)?.measuredAt.map { now.timeIntervalSince($0) > staleInterval } == true)
    }
}
