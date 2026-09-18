# Menu-bar lifecycle validation

`Tests/MenuBarLifecycleTests.swift` runs the production `AppDelegate`, native
status item, main window, and action dispatch inside a real `NSApplication` event
loop. Compile it with `-D GARMIN_LIFECYCLE_TEST`; that build replaces only the
executable entry point and disables window-frame autosaving. A constructor
injection supplies an `AppStore` backed by an in-memory `UserDefaults` subclass,
a UUID-scoped temporary directory, and a synthetic `GarminWebTransport`.

The harness does not instantiate WebKit, request network data, open the installed
application, change login items, persist user defaults, or publish widget data.
Only the test process's windows and status item appear briefly. The temporary
fixture directory is removed before exit.

Coverage includes accessory activation policy (no Dock application icon), template
status artwork, localized action labels, disconnected/busy/connected Refresh and
Sign In availability, Settings navigation, closing and reopening windows, Finder
reopen from a minimized window, widget deep links, refresh with all windows
closed, preserved next-refresh scheduling, native editing menu actions, and Quit's
application target. Compilation uses the actual host/shared source files; no
source rewriting or alternate delegate implementation is used.

This test does not claim verification of Garmin's live login UI, login-item
launch at macOS sign-in, left-menu shortcut key delivery, menu-bar contrast on
every display, installed-app upgrade, or WidgetKit gallery/desktop hosting.
Those require the corresponding manual checks. A passing lifecycle harness is
not a normal-upgrade validation report.
