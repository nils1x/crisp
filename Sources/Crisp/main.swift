import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let shared = AppDelegate() // NSApplication.delegate is weak.
    private let controller = CrispController()
    private let settingsNavigation = SettingsNavigation()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var fastSpaceSwitchingItem: NSMenuItem?
    private var hyperSourceItems: [HyperSource: NSMenuItem] = [:]
    private var menuBarIconItems: [MenuBarIcon: NSMenuItem] = [:]
    private var iconObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        applyMenuBarIcon(controller.config.menuBarIcon)
        iconObservation = controller.$config.sink { [weak self] config in
            self?.applyMenuBarIcon(config.menuBarIcon)
        }
        let menu = NSMenu()
        menu.delegate = self

        let fastSpaceSwitching = NSMenuItem(title: "Fast Space Switching", action: #selector(toggleFastSpaceSwitching), keyEquivalent: "")
        fastSpaceSwitching.target = self
        menu.addItem(fastSpaceSwitching)
        fastSpaceSwitchingItem = fastSpaceSwitching

        let hyperItem = NSMenuItem(title: "Hyper Key", action: nil, keyEquivalent: "")
        let hyperMenu = NSMenu()
        hyperMenu.delegate = self
        for source in HyperSource.allCases {
            let item = NSMenuItem(title: source.label, action: #selector(selectHyperSource), keyEquivalent: "")
            item.target = self
            item.representedObject = source.rawValue
            hyperMenu.addItem(item)
            hyperSourceItems[source] = item
        }
        hyperMenu.addItem(.separator())
        let hyperSettings = NSMenuItem(title: "Hyper Key Settings…", action: #selector(showHyperSettings), keyEquivalent: "")
        hyperSettings.target = self
        hyperMenu.addItem(hyperSettings)
        hyperItem.submenu = hyperMenu
        menu.addItem(hyperItem)

        let iconItem = NSMenuItem(title: "Menu Bar Icon", action: nil, keyEquivalent: "")
        let iconMenu = NSMenu()
        iconMenu.delegate = self
        for icon in MenuBarIcon.allCases {
            let entry = NSMenuItem(title: icon.title, action: #selector(selectMenuBarIcon), keyEquivalent: "")
            entry.target = self
            entry.representedObject = icon.rawValue
            iconMenu.addItem(entry)
            menuBarIconItems[icon] = entry
        }
        iconItem.submenu = iconMenu
        menu.addItem(iconItem)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Crisp", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        controller.start()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        fastSpaceSwitchingItem?.state = controller.config.instantSpaces ? .on : .off
        for (source, item) in hyperSourceItems {
            item.state = controller.config.hyperSource == source ? .on : .off
        }
        for (icon, item) in menuBarIconItems {
            item.state = controller.config.menuBarIcon == icon ? .on : .off
        }
    }

    /// The supra ships as a template image in the bundle; the rabbit is an SF Symbol.
    /// Both are templates, so macOS keeps them legible in light and dark menu bars.
    private func applyMenuBarIcon(_ icon: MenuBarIcon) {
        let image: NSImage?
        switch icon {
        case .supra:
            image = NSImage(named: "MenuBarSupra")
        case .rabbit:
            image = NSImage(systemSymbolName: "hare.fill", accessibilityDescription: nil)
        }
        guard let image else { return }
        image.isTemplate = true
        statusItem?.button?.image = image
    }

    @objc private func selectMenuBarIcon(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let icon = MenuBarIcon(rawValue: raw) else { return }
        var config = controller.config
        guard config.menuBarIcon != icon else { return }
        config.menuBarIcon = icon
        controller.update(config)
    }

    @objc private func toggleFastSpaceSwitching() {
        var config = controller.config
        config.instantSpaces.toggle()
        controller.update(config)
    }

    @objc private func selectHyperSource(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let source = HyperSource(rawValue: rawValue) else { return }
        var config = controller.config
        config.hyperSource = source
        controller.update(config)
        if let message = controller.error { showError(message) }
    }

    @objc private func showSettings() {
        presentSettings()
    }

    @objc private func showHyperSettings() {
        presentSettings(section: .hyper)
    }

    private func presentSettings(section: SettingsSection? = nil) {
        if let section { settingsNavigation.selection = section }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(controller: controller, navigation: settingsNavigation))
            let window = NSWindow(contentViewController: host)
            window.title = "Crisp Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 940, height: 620))
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Crisp couldn’t apply that setting"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
        CrashLog.noteCleanExit()
    }
}

MainActor.assumeIsolated {
    CrashLog.install()
    // One Crisp per login session. A second copy (a rebuild that got relaunched, or a
    // second manual launch) would add a competing menu bar item and race the config, so
    // hand over to the running instance and step aside.
    if let running = Bundle.main.bundleIdentifier.flatMap({ identifier in
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first { $0 != NSRunningApplication.current }
    }) {
        running.activate(options: [.activateAllWindows])
        exit(0)
    }
    let app = NSApplication.shared
    app.delegate = AppDelegate.shared
    app.run()
}
