//
//  AppDelegate.swift
//  GlassTerm
//
//  App lifecycle, the whole menu bar (built in code), window bookkeeping and
//  the app-level actions the menu forwards into the focused terminal.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    /// Strong ownership of every live terminal window. Closed controllers are
    /// pruned on window close (deferred one run-loop turn) and again on every
    /// `newWindow`, so nothing here can be freed twice.
    private var windows: [TerminalWindowController] = []

    /// Windows we registered a `willCloseNotification` observer for, so we can
    /// detach exactly once.
    private var observedWindows: Set<ObjectIdentifier> = []

    private static let settingsWindowTitle = "GlassTerm Settings"
    private static let displayName = "GlassTerm"
    private static let displayVersion = "1.0.0"

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        ConfigStore.shared.reload()
        buildMenu()

        pruneClosedWindows()
        let first = TerminalWindowController(configStore: ConfigStore.shared)
        register(first)
        first.showWindowAndStart()
        NSApp.activate(ignoringOtherApps: true)

        // Headless build verification: prove the whole launch path ran, then bail
        // out without entering the run loop.
        if ProcessInfo.processInfo.environment["GT_SMOKE"] == "1" {
            ConfigStore.shared.save()
            print("SMOKE_OK")
            fflush(stdout)
            exit(0)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ConfigStore.shared.save()
    }

    /// GlassTerm quits with its last terminal window — unless Settings is still
    /// open, because closing the last terminal must not kill the preferences
    /// window (and then bounce the user out of the app).
    ///
    /// AppKit sends this whenever the last *visible* window closes. The settings
    /// window is a plain titled `NSWindow` (not an `NSPanel`), so panels such as
    /// the About panel / alerts never keep the app alive. Once Settings itself is
    /// closed this is called again, Settings is gone, and we return `true`.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return !isSettingsWindowOpen
    }

    private var isSettingsWindowOpen: Bool {
        return NSApp.windows.contains { window in
            // `!(window is NSPanel)` keeps About/alerts from counting as Settings.
            !(window is NSPanel)
                && window.isVisible
                && window.title == AppDelegate.settingsWindowTitle
        }
    }

    // MARK: - Window bookkeeping

    private func register(_ controller: TerminalWindowController) {
        windows.append(controller)
        if let window = controller.window,
           observedWindows.insert(ObjectIdentifier(window)).inserted {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(terminalWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }
    }

    @objc private func terminalWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: window
        )
        observedWindows.remove(ObjectIdentifier(window))

        // Defer the actual release: dropping the last strong reference to an
        // NSWindowController from inside its own window's close notification is
        // how you get a use-after-free while AppKit is still tearing the window
        // down. One run-loop turn later the close has finished.
        DispatchQueue.main.async { [weak self] in
            self?.windows.removeAll { $0.window === window }
        }
    }

    /// Drop controllers that no longer own a window. Safe to call at any time.
    private func pruneClosedWindows() {
        windows.removeAll { $0.window == nil }
    }

    private func makeWindowController() -> TerminalWindowController {
        pruneClosedWindows()
        let controller = TerminalWindowController(configStore: ConfigStore.shared)
        register(controller)
        return controller
    }

    // MARK: - Focus resolution

    /// The terminal view that currently owns the keyboard, if any.
    private var keyTerminalView: TerminalView? {
        guard let responder = NSApp.keyWindow?.firstResponder else { return nil }
        return responder as? TerminalView
    }

    /// Best guess at the terminal the user is looking at. Prefers the key window,
    /// then the main window, then any visible terminal window (a Settings window
    /// being key must not stop ⌘C/⌘+ from reaching the terminal behind it).
    private func focusedWindowController() -> TerminalWindowController? {
        if let key = NSApp.keyWindow,
           let match = windows.first(where: { $0.window === key }) {
            return match
        }
        if let main = NSApp.mainWindow,
           let match = windows.first(where: { $0.window === main }) {
            return match
        }
        return windows.first { $0.window?.isVisible == true }
    }

    /// Action target for every terminal command: focused `TerminalView`, else the
    /// focused window's terminal, else nothing (caller beeps).
    private func targetTerminalView() -> TerminalView? {
        if let view = keyTerminalView { return view }
        return focusedWindowController()?.terminalView
    }

    private func routeToTerminal(_ body: (TerminalView) -> Void) {
        guard let view = targetTerminalView() else {
            NSSound.beep()
            return
        }
        body(view)
    }

    // MARK: - App-level actions

    @objc func newWindow(_ sender: Any?) {
        let controller = makeWindowController()
        controller.showWindowAndStart()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettings(_ sender: Any?) {
        // Works with zero terminal windows: the settings controller owns its window.
        SettingsWindowController.shared.show()
    }

    @objc func copyAction(_ sender: Any?) {
        routeToTerminal { $0.copySelection() }
    }

    @objc func pasteAction(_ sender: Any?) {
        routeToTerminal { $0.pasteFromPasteboard() }
    }

    @objc func selectAllAction(_ sender: Any?) {
        routeToTerminal { $0.selectAll() }
    }

    @objc func clearAction(_ sender: Any?) {
        routeToTerminal { $0.clearScreen() }
    }

    @objc func biggerFont(_ sender: Any?) {
        routeToTerminal { $0.increaseFontSize() }
    }

    @objc func smallerFont(_ sender: Any?) {
        routeToTerminal { $0.decreaseFontSize() }
    }

    @objc func actualSize(_ sender: Any?) {
        routeToTerminal { $0.resetFontSize() }
    }

    @objc func toggleFullScreen(_ sender: Any?) {
        if let controller = focusedWindowController() {
            controller.toggleFullScreenAction(sender)
        } else {
            NSApp.keyWindow?.toggleFullScreen(sender)
        }
    }

    @objc func quitGlassTerm(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc func showAboutPanel(_ sender: Any?) {
        let credits = NSAttributedString(string: "A liquid-glass terminal.\nBuilt with AppKit.")
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppDelegate.displayName,
            .applicationVersion: AppDelegate.displayVersion,
            .credits: credits,
        ])
    }

    @objc func showHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "\(AppDelegate.displayName) Keyboard Shortcuts"
        alert.informativeText = """
        ⌘N  New window
        ⌘K  Clear scrollback
        ⌘,  Settings
        ⌘+ / ⌘-  Bigger / smaller font
        ⌘0  Actual size
        ⌘C / ⌘V  Copy / paste
        ⌘A  Select all
        ⌃⌘F  Toggle full screen
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let action = menuItem.action
        if action == #selector(copyAction(_:))
            || action == #selector(pasteAction(_:))
            || action == #selector(selectAllAction(_:))
            || action == #selector(clearAction(_:))
            || action == #selector(biggerFont(_:))
            || action == #selector(smallerFont(_:))
            || action == #selector(actualSize(_:)) {
            // TerminalView exposes no selection state, so Copy stays enabled
            // whenever there is a terminal to copy from.
            return targetTerminalView() != nil
        }
        return true
    }

    // MARK: - Menu bar

    private func buildMenu() {
        let appName = ProcessInfo.processInfo.processName.isEmpty
            ? AppDelegate.displayName
            : ProcessInfo.processInfo.processName

        let mainMenu = NSMenu(title: "MainMenu")
        mainMenu.addItem(buildAppMenuItem(appName: appName))
        mainMenu.addItem(buildShellMenuItem())
        mainMenu.addItem(buildEditMenuItem())
        mainMenu.addItem(buildViewMenuItem())
        mainMenu.addItem(buildWindowMenuItem())
        mainMenu.addItem(buildHelpMenuItem())
        NSApp.mainMenu = mainMenu
    }

    private func makeItem(_ title: String,
                          action: Selector?,
                          key: String = "",
                          modifiers: NSEvent.ModifierFlags = .command,
                          target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private func buildAppMenuItem(appName: String) -> NSMenuItem {
        let menu = NSMenu(title: appName)

        menu.addItem(makeItem("About GlassTerm",
                              action: #selector(showAboutPanel(_:)),
                              target: self))
        menu.addItem(makeItem("Settings…",
                              action: #selector(openSettings(_:)),
                              key: ",",
                              target: self))
        menu.addItem(.separator())

        let servicesMenu = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        menu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu

        menu.addItem(.separator())
        menu.addItem(makeItem("Hide GlassTerm",
                              action: #selector(NSApplication.hide(_:)),
                              key: "h",
                              target: NSApp))
        menu.addItem(makeItem("Hide Others",
                              action: #selector(NSApplication.hideOtherApplications(_:)),
                              key: "h",
                              modifiers: [.command, .option],
                              target: NSApp))
        menu.addItem(makeItem("Show All",
                              action: #selector(NSApplication.unhideAllApplications(_:)),
                              target: NSApp))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit GlassTerm",
                              action: #selector(quitGlassTerm(_:)),
                              key: "q",
                              target: self))

        let holder = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private func buildShellMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Shell")

        menu.addItem(makeItem("New Window",
                              action: #selector(newWindow(_:)),
                              key: "n",
                              target: self))
        menu.addItem(makeItem("Clear Scrollback",
                              action: #selector(clearAction(_:)),
                              key: "k",
                              target: nil))
        menu.addItem(.separator())
        // Responder chain: reaches the key window.
        menu.addItem(makeItem("Close Window",
                              action: #selector(NSWindow.performClose(_:)),
                              key: "w",
                              target: nil))
        menu.addItem(.separator())
        menu.addItem(makeItem("Bigger",
                              action: #selector(biggerFont(_:)),
                              key: "+",
                              target: nil))
        menu.addItem(makeItem("Smaller",
                              action: #selector(smallerFont(_:)),
                              key: "-",
                              target: nil))
        menu.addItem(makeItem("Actual Size",
                              action: #selector(actualSize(_:)),
                              key: "0",
                              target: nil))

        let holder = NSMenuItem(title: "Shell", action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private func buildEditMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")

        // Undo/Redo/Cut go straight down the responder chain; Copy/Paste/Select All
        // use our actions so a non-terminal first responder can never swallow them.
        menu.addItem(makeItem("Undo", action: Selector(("undo:")), key: "z", target: nil))
        menu.addItem(makeItem("Redo",
                              action: Selector(("redo:")),
                              key: "z",
                              modifiers: [.command, .shift],
                              target: nil))
        menu.addItem(.separator())
        menu.addItem(makeItem("Cut", action: #selector(NSText.cut(_:)), key: "x", target: nil))
        menu.addItem(makeItem("Copy", action: #selector(copyAction(_:)), key: "c", target: nil))
        menu.addItem(makeItem("Paste", action: #selector(pasteAction(_:)), key: "v", target: nil))
        menu.addItem(makeItem("Select All",
                              action: #selector(selectAllAction(_:)),
                              key: "a",
                              target: nil))

        let holder = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private func buildViewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "View")
        menu.addItem(makeItem("Toggle Full Screen",
                              action: #selector(toggleFullScreen(_:)),
                              key: "f",
                              modifiers: [.command, .control],
                              target: self))

        let holder = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private func buildWindowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")

        menu.addItem(makeItem("Minimize",
                              action: #selector(NSWindow.performMiniaturize(_:)),
                              key: "m",
                              target: nil))
        menu.addItem(makeItem("Zoom",
                              action: #selector(NSWindow.performZoom(_:)),
                              key: "",
                              target: nil))
        menu.addItem(.separator())
        menu.addItem(makeItem("Bring All to Front",
                              action: #selector(NSApplication.arrangeInFront(_:)),
                              target: NSApp))
        NSApp.windowsMenu = menu

        let holder = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private func buildHelpMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Help")
        menu.addItem(makeItem("GlassTerm Help",
                              action: #selector(showHelp(_:)),
                              target: self))
        NSApp.helpMenu = menu

        let holder = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }
}
