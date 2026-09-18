import AppKit
import Foundation
import Darwin

/// Real AppKit event loop and production AppDelegate; synthetic data only.
/// No WebKit instance, network, installed app, real defaults, widget publishing,
/// login-item changes, or window-frame persistence.
private final class LifecycleDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func double(forKey key: String) -> Double { (values[key] as? NSNumber)?.doubleValue ?? 0 }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@MainActor private final class LifecycleClock {
    var now = SyncPolicy.Moment(wallTime: Date(), monotonicSeconds: 1_000, bootID: "lifecycle-fixture")
    func advance(_ seconds: TimeInterval) {
        now.wallTime.addTimeInterval(seconds)
        now.monotonicSeconds += seconds
    }
}

@MainActor private final class LifecycleTransport: GarminWebTransport {
    var onConnectPageReady: (() -> Void)?
    var onSignInClosed: (() -> Void)?
    var onDiagnostic: ((BridgeDiagnostic) -> Void)?
    var requests = 0
    var signInOpens = 0
    private var canProceed = false
    private var pending: CheckedContinuation<Void, Never>?
    func beginBatch() {}
    func openSignIn(title: String) { signInOpens += 1 }
    func closeSignIn() {}
    func prepare(forceReload: Bool) async throws {
        if !canProceed { await withCheckedContinuation { pending = $0 } }
        try Task.checkCancellation()
    }
    func get(path: String, stage: String) async throws -> Any {
        requests += 1
        if stage == "profile" { return ["displayName": "synthetic-lifecycle-account"] }
        if stage == "devices" { return [["productDisplayName": "Synthetic watch"]] }
        if stage == "stats" { return ["totalSteps": 123] }
        return NSNull()
    }
    func release() {
        canProceed = true
        let waiter = pending
        pending = nil
        waiter?.resume()
    }
    func cancel() { release() }
    func disconnect() async {}
}

@main @MainActor
struct MenuBarLifecycleTests {
    private struct Failure: Error, CustomStringConvertible { var description: String }
    private static var checks = 0
    private static var result: Int32 = 1

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw Failure(description: message) }
    }

    private static func item(_ action: String, in menu: NSMenu) throws -> NSMenuItem {
        guard let item = menu.items.first(where: { $0.action == NSSelectorFromString(action) }) else {
            throw Failure(description: "Missing status action: " + action)
        }
        return item
    }

    private static func invoke(_ action: String, in menu: NSMenu) throws {
        let target = try item(action, in: menu)
        try expect(target.isEnabled && !target.isHidden, "Menu action must be available: " + action)
        try expect(NSApp.sendAction(target.action!, to: target.target, from: target), "Menu action must dispatch: " + action)
    }

    private static func pulse() async { try? await Task.sleep(nanoseconds: 100_000_000) }

    private static func settle(_ store: AppStore) async throws {
        for _ in 0..<100 {
            if !store.isSyncing { await pulse(); return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure(description: "Synthetic synchronization did not finish")
    }

    private static func run(delegate: AppDelegate, transport: LifecycleTransport, clock: LifecycleClock) async throws {
        await pulse()
        let state = delegate.lifecycleTestState
        guard let store = state.store, let window = state.window, let status = state.status else {
            throw Failure(description: "Launch must create store, main window, and status item")
        }
        try expect(NSApp.activationPolicy() == .accessory, "Application must stay out of Dock")
        try expect(window.isVisible, "Explicit launch must show its main window")
        try expect(status.isVisible && status.button?.image?.isTemplate == true, "Visible status icon must be a template image")
        try expect(status.menu === state.menu, "Status icon must own the live action menu")
        try expect(!state.menu.autoenablesItems, "AppStore must control refresh availability")
        delegate.menuNeedsUpdate(state.menu)
        try expect(try !item("refresh", in: state.menu).isEnabled, "Disconnected Refresh must be disabled")
        try expect(try !item("connect", in: state.menu).isHidden, "Disconnected Sign In must be visible")
        let quit = try item("terminate:", in: state.menu)
        try expect(quit.target === NSApp && quit.isEnabled, "Quit must target this application")

        window.close()
        await pulse()
        try expect(!window.isVisible && !delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp), "Closing the window must preserve the background application")
        try expect(status.isVisible, "Closing the window must preserve the status item")
        try invoke("showSettings", in: state.menu)
        await pulse()
        try expect(window.isVisible && delegate.lifecycleTestState.navigation.section == .general, "Settings must reopen the window on General")
        try expect(NSApp.activationPolicy() == .accessory, "Settings must not add a Dock icon")

        window.miniaturize(nil)
        await pulse()
        _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        await pulse()
        try expect(window.isVisible && !window.isMiniaturized, "Finder reopen must restore a minimized window")
        window.close()
        try invoke("showMainWindow", in: state.menu)
        await pulse()
        try expect(window.isVisible, "Open must restore a closed window")
        let link = WidgetLink(slot: .sport).url!
        window.close()
        delegate.application(NSApp, open: [link])
        await pulse()
        try expect(window.isVisible && delegate.lifecycleTestState.navigation.widgetSlot == .sport
                   && delegate.lifecycleTestState.navigation.section == .dashboard, "Widget URL must restore its exact dashboard slot")

        try invoke("connect", in: state.menu)
        try expect(transport.signInOpens == 1, "Sign In must use the injected transport")
        transport.onConnectPageReady?()
        await pulse()
        delegate.menuNeedsUpdate(state.menu)
        try expect(store.isSyncing, "Synthetic sign-in must begin a real AppStore verification")
        try expect(try !item("refresh", in: state.menu).isEnabled && !item("connect", in: state.menu).isEnabled,
                   "Actions must remain disabled while verification is active")
        transport.release()
        try await settle(store)
        delegate.menuNeedsUpdate(state.menu)
        try expect(store.hasSession, "Completed verification must update connection state")
        try expect(try item("refresh", in: state.menu).isEnabled && item("connect", in: state.menu).isHidden,
                   "Connected menu must enable Refresh and hide Sign In")
        let before = transport.requests
        clock.advance(31)
        window.close()
        try invoke("refresh", in: state.menu)
        try await settle(store)
        try expect(transport.requests > before && !window.isVisible, "Menu refresh must work with all windows closed")
        try expect(store.nextSyncAt != nil, "Background refresh cadence must survive closing windows")

        store.preferences.language = .ru
        await pulse()
        delegate.menuNeedsUpdate(state.menu)
        try expect(try item("showSettings", in: state.menu).title == store.text("action.settings") + "…", "Language changes must rebuild menu labels")
        try expect(NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).contains(where: { $0.action == #selector(NSText.paste(_:)) }) == true,
                   "Main menu must retain native editing shortcuts for sign-in fields")
        try expect(NSApp.activationPolicy() == .accessory, "All menu operations must preserve accessory policy")
    }

    static func main() throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
                || ProcessInfo.processInfo.environment["GARMIN_ALLOW_LOCAL_TESTS"] == "1" else {
            throw Failure(description: "GUI lifecycle tests require explicit local opt-in or CI")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GarminDeskLifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = LifecycleTransport()
        let clock = LifecycleClock()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(storeFactory: {
            AppStore(supportDirectory: directory, webSession: transport, defaults: LifecycleDefaults(),
                     clock: { clock.now }, automaticScheduling: false, writesWidgetData: false)
        })
        app.delegate = delegate
        DispatchQueue.main.async {
            Task { @MainActor in
                do {
                    try await run(delegate: delegate, transport: transport, clock: clock)
                    print("PASS: \(checks) isolated AppKit menu/window lifecycle checks")
                    result = 0
                } catch { fputs("FAIL: \(error)\n", stderr) }
                delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                for window in app.windows { window.orderOut(nil) }
                app.stop(nil)
                // Wake run() after stop, without terminating the runner before
                // its temporary fixture directory has been removed.
                if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                    app.postEvent(event, atStart: true)
                }
            }
        }
        withExtendedLifetime(delegate) { app.run() }
        try? FileManager.default.removeItem(at: directory)
        exit(result)
    }
}
