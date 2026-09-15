import Foundation

extension GarminSnapshot {
    func metricUpdatedAt(_ id: String) -> Date? {
        guard metrics[id] != nil else { return nil }
        let groups = GarminWebAPI.requiredGroups(metricIDs: [id]).subtracting([.profile, .devices])
        // Daily stats owns resting HR whenever it supplies the value.
        let stamps = groups.compactMap { groupUpdatedAt[$0.rawValue] }
        return stamps.min() ?? (fetchedAt == .distantPast ? nil : fetchedAt)
    }

    func metricIsStale(_ id: String, at now: Date, timeZone: TimeZone = .autoupdatingCurrent,
                       staleInterval: TimeInterval) -> Bool {
        guard !isDemo, let updated = metricUpdatedAt(id) else { return false }
        return sourceDate != SyncPolicy.sourceDay(for: now, timeZone: timeZone)
            || now.timeIntervalSince(updated) > staleInterval
    }
}
