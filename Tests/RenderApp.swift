import AppKit
import SwiftUI

/// CI-only visual fixtures. No real account, WebKit instance or widget publishing.
@MainActor private final class PreviewTransport: GarminWebTransport {
    var onConnectPageReady: (() -> Void)?
    var onSignInClosed: (() -> Void)?
    var onDiagnostic: ((BridgeDiagnostic) -> Void)?
    func openSignIn(title: String) { fatalError("Rendering must never open sign-in") }
    func closeSignIn() {}
    func prepare(forceReload: Bool) async throws { fatalError("Rendering must never request data") }
    func get(path: String, stage: String) async throws -> Any { fatalError("Rendering must never request data") }
    func beginBatch() {}
    func cancel() {}
    func disconnect() async {}
}

@main struct RenderApp {
    @MainActor static func main() throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {
            fatalError("Render fixtures only on the CI machine")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let domain = "GarminDesk.Render." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(supportDirectory: directory, webSession: PreviewTransport(), defaults: defaults,
                             automaticScheduling: false, writesWidgetData: false, initialWidgetSharingAvailable: true)
        let navigation = MainWindowNavigation()
        for language in [AppLanguage.ru, .en] {
            store.preferences.language = language
            for dark in [false, true] {
                for size in [CGSize(width: 780, height: 620), CGSize(width: 1100, height: 800)] {
                    for section in MainWindowSection.allCases {
                        navigation.section = section
                        try render(store, navigation: navigation, dark: dark, size: size,
                                   name: "\(section.rawValue)-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(size.width))", output: output)
                    }
                }
            }
        }
        let now = Date()
        navigation.section = .dashboard
        for language in [AppLanguage.ru, .en] {
            store.preferences.language = language
            for dark in [false, true] {
                for state in ["waiting", "retained", "unchanged", "network", "checking", "fresh", "stable-records"] {
                    store.preferences.profiles = [WidgetProfile()]
                    store.hasSession = true
                    store.isSyncing = state == "checking"
                    store.lastErrorKey = state == "network" ? "error.network" : nil
                    var snapshot = GarminSnapshot.empty
                    if state != "waiting" {
                        snapshot = .demo // Synthetic fixtures only; never a runtime source.
                        snapshot.isDemo = false
                        snapshot.sourceDate = SyncPolicy.sourceDay(for: now, timeZone: .current)
                        snapshot.fetchedAt = now
                        snapshot.groupUpdatedAt = ["stats": now, "body_battery": now, "sleep": now]
                        snapshot.metricChangedAt = snapshot.metrics.mapValues { _ in now.addingTimeInterval(state == "unchanged" ? -7200 : 0) }
                    }
                    if state == "retained" || state == "network" {
                        let old = now.addingTimeInterval(-86400)
                        snapshot.retainedMetrics = snapshot.metrics.mapValues {
                            RetainedMetricReading(reading: $0, sourceDate: SyncPolicy.sourceDay(for: old, timeZone: .current), retrievedAt: old, changedAt: old)
                        }
                        snapshot.metrics = [:]
                        snapshot.metricChangedAt = [:]
                    }
                    if state == "stable-records" {
                        store.preferences.profiles[0].primaryMetric = "sleepDuration"
                        store.preferences.profiles[0].metricIDs = ["sleepDuration", "sleepScore", "hrv", "respiration", "restingHeartRate"]
                        let old = now.addingTimeInterval(-86400)
                        snapshot.retainedMetrics = snapshot.metrics.filter { store.preferences.profiles[0].metricIDs.contains($0.key) }.mapValues {
                            .init(reading: $0, sourceDate: SyncPolicy.sourceDay(for: old, timeZone: .current), retrievedAt: old, changedAt: old)
                        }
                        snapshot.metrics = [:]; snapshot.metricChangedAt = [:]
                    }
                    if state == "network" { snapshot.warnings = ["network.connection"] }
                    store.snapshot = snapshot
                    try render(store, navigation: navigation, dark: dark, size: CGSize(width: 780, height: 760),
                               name: "state-\(state)-\(language.rawValue)-\(dark ? "dark" : "light")", output: output)
                }
            }
        }
        store.isSyncing = false
        store.cancelLogin(resumeAutomatic: false)
        print("PASS: 60 synthetic app renders; no website or system-widget access")
    }
    @MainActor private static func render(_ store: AppStore, navigation: MainWindowNavigation,
                                          dark: Bool, size: CGSize, name: String, output: URL) throws {
        let view = MainWindowView(store: store, navigation: navigation)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try bytes.write(to: output.appendingPathComponent(name + ".png"))
        window.close()
    }

}
