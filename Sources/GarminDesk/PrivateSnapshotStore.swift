import Foundation

/// Account ownership belongs only to the private host cache. The plain
/// GarminSnapshot remains safe to encode into the separate widget payload.
struct GarminPrivateSnapshot: Codable {
    var version = 1
    var accountDisplayName: String?
    var snapshot: GarminSnapshot
}

enum PrivateSnapshotStore {
    static func encode(_ snapshot: GarminSnapshot, accountDisplayName: String?) throws -> Data {
        try AppJSON.encoder.encode(GarminPrivateSnapshot(accountDisplayName: accountDisplayName,
                                                        snapshot: snapshot))
    }

    static func ownersConflict(_ data: Data?, cache: GarminWebCache) -> Bool {
        guard let data, let stored = try? AppJSON.decoder.decode(GarminPrivateSnapshot.self, from: data) else { return false }
        return stored.accountDisplayName != cache.accountDisplayName
    }

    static func restore(_ data: Data?, cache: GarminWebCache, sourceDay: String) -> GarminSnapshot {
        guard let owner = cache.accountDisplayName, !owner.isEmpty else { return .empty }
        if let data, let stored = try? AppJSON.decoder.decode(GarminPrivateSnapshot.self, from: data) {
            // Either file can be the newer successful write. Conflicting owners
            // cannot establish which account is current, so show nothing until
            // the next profile verification resolves ownership.
            guard stored.accountDisplayName == owner else { return .empty }
            if stored.version == 1, !stored.snapshot.isDemo {
                return reconciledCache(cache: cache, snapshot: stored.snapshot, sourceDay: sourceDay)
                    .snapshot(sourceDay: sourceDay, fallback: stored.snapshot, warnings: stored.snapshot.warnings)
            }
        }
        // Legacy/corrupt snapshot bytes never contribute fallback readings.
        // When ownership does not conflict, recover only owned groups.
        return cache.snapshot(sourceDay: sourceDay, fallback: .empty, warnings: [])
    }
    static func restoreCache(_ data: Data?, cache: GarminWebCache, sourceDay: String) -> GarminWebCache {
        guard let owner = cache.accountDisplayName, !owner.isEmpty, let data,
              let stored = try? AppJSON.decoder.decode(GarminPrivateSnapshot.self, from: data),
              stored.version == 1, stored.accountDisplayName == owner, !stored.snapshot.isDemo else { return cache }
        return reconciledCache(cache: cache, snapshot: stored.snapshot, sourceDay: sourceDay)
    }

    /// Snapshot and group files are independently atomic. Reconstruct only the
    /// snapshot groups proven newer than their corresponding owned cache group;
    /// applying either entire file wholesale could roll successful data backwards.
    private static func reconciledCache(cache: GarminWebCache, snapshot: GarminSnapshot, sourceDay: String) -> GarminWebCache {
        var merged = cache
        for (key, stamp) in snapshot.groupUpdatedAt {
            guard let group = SyncPolicy.Group(rawValue: key), GarminPayloadNormalizer.groups.contains(key) else { continue }
            if key == "body_battery", snapshot.metrics["bodyBattery"] != nil,
               (snapshot.bodyBatterySourceGroup ?? "body_battery") != key { continue }
            let cached = merged.groups[key]
            if cached?.sourceDay == sourceDay && snapshot.sourceDate != sourceDay { continue }
            let newerDay = snapshot.sourceDate == sourceDay && cached?.sourceDay != sourceDay
            guard newerDay || cached == nil || stamp > cached!.retrievedAt else { continue }
            let metrics = snapshot.metrics.filter { id, _ in
                if id == "bodyBattery" { return key == (snapshot.bodyBatterySourceGroup ?? "body_battery") }
                return GarminWebAPI.requiredGroups(metricIDs: [id]).contains(group)
            }
            var restored = GarminMetricGroupCache(sourceDay: snapshot.sourceDate, retrievedAt: stamp, metrics: metrics)
            if group == .training || group == .hrv { restored.metricContext = snapshot.metricContext }
            if group == .bodyBattery { restored.bodyBatteryProjection = snapshot.bodyBatteryProjection }
            merged.groups[key] = restored
        }
        if let training = snapshot.trainingTimeline {
            if let stamp = training.pastUpdatedAt, training.pastCoverage == .recentActivities,
               stamp > (merged.pastActivities?.retrievedAt ?? .distantPast) {
                merged.pastActivities = .init(sourceDay: snapshot.sourceDate, retrievedAt: stamp, items: training.past)
                if merged.trainingIssues == nil { merged.trainingIssues = [:] }
                merged.trainingIssues?["activities"] = training.pastIssue
            }
            if let stamp = training.futureUpdatedAt {
                for month in training.futureCoveredMonths ?? [] where stamp > (merged.calendarMonths?[month]?.retrievedAt ?? .distantPast) {
                    if merged.calendarMonths == nil { merged.calendarMonths = [:] }
                    merged.calendarMonths?[month] = .init(sourceDay: snapshot.sourceDate, retrievedAt: stamp,
                        items: training.upcoming.filter { String($0.localDate.prefix(7)) == month })
                    if merged.trainingIssues == nil { merged.trainingIssues = [:] }
                    merged.trainingIssues?["planned_workouts"] = training.futureIssue
                }
            }
        }
        return merged
    }
}
