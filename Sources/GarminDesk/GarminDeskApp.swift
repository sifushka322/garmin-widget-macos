import AppKit
import SwiftUI
import Combine
import Darwin

@main
enum GarminDeskLauncher {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: AppStore!
    private let navigation = MainWindowNavigation()
    private var mainWindow: NSWindow?
    private var subscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var menuLanguage: String?
    private var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = AppStore()
        configureMenu()
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
        } else {
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
            window.setFrameAutosaveName("GarminDeskMainWindow")
            mainWindow = window
        }
        update()
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettings() {
        navigation.section = .general
        showMainWindow()
    }

    private func update() {
        configureMenu()
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
        if url.host == "profile", let identifier = UUID(uuidString: url.lastPathComponent), store.profile(identifier) != nil {
            navigation.profileID = identifier
            navigation.section = .dashboard
        } else {
            navigation.section = store.hasSession ? .profiles : .connection
        }
        showMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) { store?.cancelLogin(resumeAutomatic: false) }

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
    }
}
