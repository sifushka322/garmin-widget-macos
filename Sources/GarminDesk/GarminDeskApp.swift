import AppKit
import SwiftUI
import Combine
import CoreServices
import Darwin

#if !GARMIN_LIFECYCLE_TEST
@main
enum GarminDeskLauncher {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Keep settings and Garmin's sign-in windows usable without adding a
        // Dock icon. LSUIElement also prevents a Dock flash during launch.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let storeFactory: @MainActor () -> AppStore
    private var store: AppStore!
    private let navigation = MainWindowNavigation()
    private var mainWindow: NSWindow?
    private var subscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var menuLanguage: String?
    private var pendingURL: URL?
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private let statusTextItem = NSMenuItem()
    private let lastCheckedItem = NSMenuItem()
    private let nextCheckItem = NSMenuItem()
    private let refreshItem = NSMenuItem()
    private let connectItem = NSMenuItem()

    init(storeFactory: @escaping @MainActor () -> AppStore = { AppStore() }) {
        self.storeFactory = storeFactory
        super.init()
    }

#if GARMIN_LIFECYCLE_TEST
    // This read-only seam is absent from release builds. The harness runs the
    // real delegate/menu/window code with a fully isolated synthetic AppStore.
    var lifecycleTestState: (store: AppStore?, navigation: MainWindowNavigation, window: NSWindow?, status: NSStatusItem?, menu: NSMenu) {
        (store, navigation, mainWindow, statusItem, statusMenu)
    }
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = launchEvent?.eventID == kAEOpenApplication
            && launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        store = storeFactory()
        configureMenu()
        configureStatusItem()
        subscription = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.store.sync(trigger: .wake) }
        })
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.store.sync(trigger: .wake) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.store.objectWillChange.send(); self?.store.publishWidgetData(); self?.update() }
        })
        if let url = pendingURL {
            pendingURL = nil
            application(NSApp, open: [url])
        } else if !launchedAtLogin {
            showMainWindow()
        }
        if store.hasSession { store.sync(trigger: .automatic) }
    }

    @objc private func showMainWindow() {
        guard store != nil else { return }
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Garmin Desk"
            window.contentMinSize = NSSize(width: 780, height: 620)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MainWindowView(store: store, navigation: navigation))
            window.center()
#if !GARMIN_LIFECYCLE_TEST
            window.setFrameAutosaveName("GarminDeskMainWindow")
#endif
            mainWindow = window
        }
        update()
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        NSApp.unhide(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettings() {
        navigation.section = .general
        showMainWindow()
    }

    @objc private func refresh() { store.sync(trigger: .manual) }

    @objc private func connect() { store.connectGarmin() }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    private func update() {
        configureMenu()
        updateStatusMenu()
        switch store.preferences.appearance {
        case .system: mainWindow?.appearance = nil
        case .light: mainWindow?.appearance = NSAppearance(named: .aqua)
        case .dark: mainWindow?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme == "garmindesk" }) else { return }
        guard store != nil else { pendingURL = url; return }
        if let link = WidgetLink(url: url) {
            navigation.widgetSlot = link.slot
            navigation.section = .dashboard
        } else {
            navigation.widgetSlot = nil
            navigation.section = store.hasSession ? .widgets : .connection
        }
        showMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        subscription?.cancel()
        store?.cancelLogin(resumeAutomatic: false)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(GarminDeskBrandGeometry.path(in: rect))
            context.fillPath()
            return true
        }
        image.isTemplate = true
        item.button?.image = image
        item.button?.setAccessibilityLabel("Garmin Desk")
        item.menu = statusMenu
        statusMenu.delegate = self
        // State is owned by AppStore; automatic validation would re-enable
        // Refresh during a request merely because its target implements it.
        statusMenu.autoenablesItems = false
        statusItem = item
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        statusMenu.removeAllItems()
        for item in [statusTextItem, lastCheckedItem, nextCheckItem] {
            item.isEnabled = false
            statusMenu.addItem(item)
        }
        statusMenu.addItem(.separator())
        func action(_ title: String, _ selector: Selector, _ key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            statusMenu.addItem(item)
            return item
        }
        _ = action(store.text("widget.openApp"), #selector(showMainWindow), "0")
        _ = action(store.text("action.settings") + "…", #selector(showSettings), ",")
        refreshItem.action = #selector(refresh)
        refreshItem.target = self
        refreshItem.keyEquivalent = "r"
        statusMenu.addItem(refreshItem)
        connectItem.action = #selector(connect)
        connectItem.target = self
        statusMenu.addItem(connectItem)
        statusMenu.addItem(.separator())
        _ = action(store.text("menu.about"), #selector(showAbout))
        let quit = NSMenuItem(title: store.text("action.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        statusMenu.addItem(quit)
        updateStatusMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusMenu { updateStatusMenu() }
    }

    private func updateStatusMenu() {
        guard store != nil, statusItem != nil else { return }
        let statusKey: String
        if store.isSyncing { statusKey = "data.syncing" }
        else if store.needsWebSignIn { statusKey = "status.signInRequired" }
        else if ["error.network", "error.timeout", "error.protocol", "error.partial", "error.rate_limit"].contains(store.lastErrorKey ?? "") {
            statusKey = "data.checkFailed"
        }
        else if !store.hasSession { statusKey = "status.notConnected" }
        else if !store.snapshot.hasMeasurements { statusKey = "data.waiting" }
        else if store.isStale { statusKey = "widget.notice.waiting" }
        else { statusKey = "status.connected" }
        statusTextItem.title = store.text(statusKey)
        statusTextItem.toolTip = store.lastErrorKey.map { store.text($0) }
        lastCheckedItem.title = store.updatedText
        lastCheckedItem.isHidden = store.snapshot.fetchedAt == .distantPast
        if let nextSyncAt = store.nextSyncAt, nextSyncAt > Date(), !store.isSyncing {
            let formatter = DateFormatter()
            formatter.locale = store.preferences.language.locale
            formatter.dateStyle = Calendar.autoupdatingCurrent.isDateInToday(nextSyncAt) ? .none : .short
            formatter.timeStyle = .short
            nextCheckItem.title = store.text("connection.nextSync") + " " + formatter.string(from: nextSyncAt)
            nextCheckItem.isHidden = false
        } else { nextCheckItem.isHidden = true }
        refreshItem.title = store.text(store.isSyncing ? "data.syncing" : "action.sync")
        refreshItem.isEnabled = store.hasSession && !store.isSyncing
        connectItem.title = store.text(store.needsWebSignIn ? "connection.reconnect" : "connection.webSignIn") + "…"
        connectItem.isHidden = store.hasSession
        connectItem.isEnabled = !store.isSyncing
        statusItem?.button?.toolTip = "Garmin Desk — " + statusTextItem.title
        statusItem?.button?.setAccessibilityValue(statusTextItem.title)
    }

    private func configureMenu() {
        let language = store.preferences.language.effectiveCode
        guard menuLanguage != language else { return }
        menuLanguage = language
        let menu = NSMenu()
        let appMenu = NSMenu(title: "Garmin Desk")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)
        appMenu.addItem(NSMenuItem(title: store.text("menu.about"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: store.text("action.settings") + "…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: store.text("menu.hideApp"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: store.text("menu.hideOthers"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: store.text("menu.showAll"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: store.text("action.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let fileMenu = NSMenu(title: store.text("menu.file"))
        let fileItem = NSMenuItem(); fileItem.submenu = fileMenu; menu.addItem(fileItem)
        fileMenu.addItem(NSMenuItem(title: store.text("menu.closeWindow"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        let editMenu = NSMenu(title: store.text("menu.edit"))
        let editItem = NSMenuItem(); editItem.submenu = editMenu; menu.addItem(editItem)
        for (key, action, shortcut) in [
            ("menu.cut", #selector(NSText.cut(_:)), "x"),
            ("menu.copy", #selector(NSText.copy(_:)), "c"),
            ("menu.paste", #selector(NSText.paste(_:)), "v"),
            ("menu.selectAll", #selector(NSText.selectAll(_:)), "a")
        ] {
            editMenu.addItem(NSMenuItem(title: store.text(key), action: action, keyEquivalent: shortcut))
        }
        let windowMenu = NSMenu(title: store.text("menu.window"))
        let windowItem = NSMenuItem(); windowItem.submenu = windowMenu; menu.addItem(windowItem)
        let openWindow = NSMenuItem(title: store.text("menu.mainWindow"), action: #selector(showMainWindow), keyEquivalent: "0")
        openWindow.target = self
        windowMenu.addItem(openWindow)
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: store.text("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: store.text("menu.zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
        if statusItem != nil { rebuildStatusMenu() }
    }
}
