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
                             automaticScheduling: false, writesWidgetData: false)
        let navigation = MainWindowNavigation()
        for language in [AppLanguage.ru, .en] {
            store.preferences.language = language
            for dark in [false, true] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                for size in [CGSize(width: 780, height: 620), CGSize(width: 1100, height: 800)] {
                    for section in MainWindowSection.allCases {
                        navigation.section = section
                        let view = MainWindowView(store: store, navigation: navigation)
                            .environment(\.colorScheme, dark ? .dark : .light)
                        let host = NSHostingView(rootView: view)
                        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.appearance = appearance
                        window.contentView = host
                        host.frame = CGRect(origin: .zero, size: size)
                        // Let AppKit-backed pickers and SwiftUI drawing settle in
                        // the runner's off-screen window before taking the bitmap.
                        window.displayIfNeeded()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                        host.layoutSubtreeIfNeeded()
                        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
                        let name = "\(section.rawValue)-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(size.width)).png"
                        try bytes.write(to: output.appendingPathComponent(name))
                        window.close()
                    }
                }
            }
        }
        store.cancelLogin(resumeAutomatic: false)
        print("PASS: 32 synthetic app renders; no website or system-widget access")
    }
}
