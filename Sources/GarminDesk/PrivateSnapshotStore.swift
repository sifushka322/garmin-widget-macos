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
            if stored.version == 1, !stored.snapshot.isDemo { return stored.snapshot }
        }
        // Legacy/corrupt snapshot bytes never contribute fallback readings.
        // When ownership does not conflict, recover only owned groups.
        return cache.snapshot(sourceDay: sourceDay, fallback: .empty, warnings: [])
    }
}
