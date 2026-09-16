import AppKit
import SwiftUI

/// Synthetic visual fixtures. No real account, WebKit instance or widget publishing.
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
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
            || ProcessInfo.processInfo.environment["GARMIN_ALLOW_LOCAL_TESTS"] == "1" else {
            fatalError("Run visual fixtures in CI; local rendering requires explicit opt-in")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let summaryOptions = CommandLine.arguments.contains("--summary-options")
        let widgetsOnly = summaryOptions || CommandLine.arguments.contains("--widgets-only") || CommandLine.arguments.contains("--profiles-only")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let domain = "GarminDesk.Render." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(supportDirectory: directory, webSession: PreviewTransport(), defaults: defaults,
                             automaticScheduling: false, writesWidgetData: false, initialWidgetSharingAvailable: true)
        let navigation = MainWindowNavigation()
        navigation.summaryMeasurementsExpanded = summaryOptions
        let languages: [AppLanguage] = summaryOptions ? [.en, .ru, .de, .ja] : AppLanguage.supported
        for language in languages {
            store.preferences.language = language
            for dark in [false, true] {
                let sizes = !widgetsOnly && [AppLanguage.ru, .en].contains(language)
                    ? [CGSize(width: 780, height: 620), CGSize(width: 1100, height: 800)]
                    : [CGSize(width: 780, height: 620)]
                for size in sizes {
                    let sections: [MainWindowSection] = widgetsOnly ? [.widgets] : MainWindowSection.allCases
                    for section in sections {
                        navigation.section = section
                        let appearances: [WidgetAppearance] = widgetsOnly && !summaryOptions ? [.colorful, .light, .dark] : [.colorful]
                        for appearance in appearances {
                            store.preferences.widgetAppearance = appearance
                            let suffix = (appearance == .colorful ? "" : "-widget-" + appearance.rawValue)
                                + (summaryOptions ? "-summary-options" : "")
                            let name = "\(section.rawValue)-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(size.width))" + suffix
                            try render(store, navigation: navigation, dark: dark, size: size, name: name, output: output)
                            if summaryOptions {
                                try render(store, navigation: navigation, dark: dark, size: size,
                                           name: name + "-editor", output: output, scrollOffset: 195)
                                try render(store, navigation: navigation, dark: dark, size: size,
                                           name: name + "-editor-bottom", output: output, scrollOffset: .greatestFiniteMagnitude)
                            }
                        }
                    }
                }
            }
        }
        if widgetsOnly {
            store.cancelLogin(resumeAutomatic: false)
            print(summaryOptions
                  ? "PASS: expanded Summary measurement controls rendered in English, Russian, German and Japanese in both app themes"
                  : "PASS: fixed widget controls rendered at minimum width in all languages, both app themes, and all three widget appearances")
            return
        }
        let now = Date()
        navigation.section = .dashboard
        for language in [AppLanguage.ru, .en] {
            store.preferences.language = language
            for dark in [false, true] {
                for state in ["waiting", "retained", "unchanged", "network", "checking", "fresh", "stable-records"] {
                    navigation.widgetSlot = .overview
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
                        navigation.widgetSlot = .sleep
                        let sleepMetrics = WidgetSlot.sleep.profile(in: store.preferences).metricIDs
                        let old = now.addingTimeInterval(-86400)
                        snapshot.retainedMetrics = snapshot.metrics.filter { sleepMetrics.contains($0.key) }.mapValues {
                            .init(reading: $0, sourceDate: SyncPolicy.sourceDay(for: old, timeZone: .current), retrievedAt: old, changedAt: old)
                        }
                        snapshot.metrics = [:]; snapshot.metricChangedAt = [:]
                        // An unrelated old progress value from another widget type
                        // must not warn that the sleep widget is out of date.
                        snapshot.retainedMetrics["bodyBattery"] = .init(reading: .init(value: 40), sourceDate: "2026-09-13", retrievedAt: old, changedAt: old)
                    }
                    if state == "network" { snapshot.warnings = ["network.connection"] }
                    store.snapshot = snapshot
                    try render(store, navigation: navigation, dark: dark, size: CGSize(width: 780, height: 760),
                               name: "state-\(state)-\(language.rawValue)-\(dark ? "dark" : "light")", output: output)
                    if state == "fresh" || state == "stable-records" {
                        try render(store, navigation: navigation, dark: dark, size: CGSize(width: 1100, height: 800),
                                   name: "wide-\(state)-\(language.rawValue)-\(dark ? "dark" : "light")", output: output)
                    }
                }
            }
        }
        store.isSyncing = false
        store.cancelLogin(resumeAutomatic: false)
        print("PASS: synthetic app renders cover all supported languages; no website or system-widget access")
    }
    @MainActor private static func render(_ store: AppStore, navigation: MainWindowNavigation,
                                          dark: Bool, size: CGSize, name: String, output: URL,
                                          scrollOffset: CGFloat = 0) throws {
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
        if scrollOffset > 0 {
            let candidates = descendants(of: host).compactMap { $0 as? NSScrollView }
            guard let scroll = candidates.max(by: { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }),
                  let document = scroll.documentView else { fatalError("Expanded editor must contain a scroll view") }
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(scrollOffset, maximum)))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try bytes.write(to: output.appendingPathComponent(name + ".png"))
        window.close()
    }

    @MainActor private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
