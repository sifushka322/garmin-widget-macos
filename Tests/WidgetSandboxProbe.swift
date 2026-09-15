import Foundation
import Darwin

/// Run preparation/cleanup in an ordinary ad-hoc CLI and verification in a
/// separate copy signed with Widgets.entitlements. Never reads the user's snapshot.
@main
struct WidgetSandboxProbe {
    struct ProbeFailure: Error { let step: String }

    static func require(_ condition: Bool, _ step: String) throws {
        guard condition else { throw ProbeFailure(step: step) }
    }

    static func main() {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 3, UUID(uuidString: arguments[2]) != nil,
                  let directory = WidgetDataStore.localCacheURL else {
                throw ProbeFailure(step: "arguments_or_user_home")
            }
            let probeName = "sandbox-probe-" + arguments[2]
            let allowed = directory.appendingPathComponent(probeName, isDirectory: true)
            let denied = directory.deletingLastPathComponent().appendingPathComponent(probeName + ".txt")
            switch arguments[1] {
            case "prepare":
                try require(!FileManager.default.fileExists(atPath: allowed.path), "fixture_already_exists")
                try require(!FileManager.default.fileExists(atPath: denied.path), "outside_fixture_already_exists")
                try WidgetDataStore.write(.preview, to: allowed)
                try Data("GarminDesk synthetic sandbox fixture".utf8).write(to: denied, options: .withoutOverwriting)
                print("PASS: synthetic_fixtures_created")
            case "verify":
                let data = WidgetDataStore.read(from: allowed)
                try require(data?.snapshot.isDemo == true && data?.version == 1, "allowed_snapshot_read")
                print("PASS: allowed_snapshot_read")

                let deniedRead = (try? Data(contentsOf: denied)) == nil
                try require(deniedRead, "neighbor_file_read_not_denied")
                print("PASS: neighbor_file_read_denied")

                let writeTarget = allowed.appendingPathComponent("must-not-create.txt")
                var writeDenied = false
                do { try Data("synthetic".utf8).write(to: writeTarget) }
                catch { writeDenied = true }
                try require(writeDenied, "allowed_directory_write_not_denied")
                print("PASS: allowed_directory_write_denied")

                var storeWriteDenied = false
                do { try WidgetDataStore.write(.preview, to: allowed) }
                catch { storeWriteDenied = true }
                try require(storeWriteDenied, "shared_store_write_not_denied")
                print("PASS: shared_store_write_denied")

                try require(WidgetDataStore.storageMode == .localReadOnlyCache, "storage_mode")
                print("PASS: no_app_group_required")
            case "cleanup":
                // Names are derived only from this run's validated UUID.
                if FileManager.default.fileExists(atPath: allowed.path) { try FileManager.default.removeItem(at: allowed) }
                if FileManager.default.fileExists(atPath: denied.path) { try FileManager.default.removeItem(at: denied) }
                print("PASS: synthetic_fixtures_removed")
            default:
                throw ProbeFailure(step: "unknown_mode")
            }
        } catch let failure as ProbeFailure {
            fputs("FAIL: \(failure.step)\n", stderr)
            exit(1)
        } catch {
            // Keep paths, contents, and user-specific context out of test output.
            fputs("FAIL: fixture_or_sandbox_operation\n", stderr)
            exit(1)
        }
    }
}
