import AppKit
import ApplicationServices
import Combine
import CoreGraphics

@MainActor
final class CrispController: ObservableObject {
    @Published var config: CrispConfig {
        didSet {
            save()
            resolver = ShortcutResolver(config)
            if oldValue.hyperSource != config.hyperSource { updateHyper() }
        }
    }
    @Published var error: String?
    @Published var keyboardReady = false
    @Published private(set) var recordingID: UUID?

    private var resolver = ShortcutResolver(.initial)
    private let remap = HyperRemap()
    private lazy var switcher = SpaceSwitcher()
    private let windows = WindowManager()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var hyperHeld = false
    private var hyperActive = false
    private var consumedKeys: Set<Int> = []
    private var hyperModifiedKeys: Set<Int> = []
    private var retryTimer: Timer?
    private var keyboardRetryTimer: Timer?
    private var pendingSave: DispatchWorkItem?
    private var recordAction: ((Shortcut) -> Void)?
    private var recordMouseMonitor: Any?
    private var recordGlobalMouseMonitor: Any?
    private var recordWindowObserver: NSObjectProtocol?
    private var layoutCycle = LayoutCycle()
    private var lastWindowID: CGWindowID?

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "crisp.config"),
           let decoded = try? JSONDecoder().decode(CrispConfig.self, from: data) {
            if defaults.bool(forKey: "crisp.shortcutMigrationV1") {
                config = decoded
            } else {
                config = decoded.upgradingLayouts()
                if let migrated = try? JSONEncoder().encode(config) {
                    defaults.set(migrated, forKey: "crisp.config")
                    defaults.set(true, forKey: "crisp.shortcutMigrationV1")
                }
            }
        } else {
            config = .initial
            defaults.set(true, forKey: "crisp.shortcutMigrationV1")
        }
    }

    func start() {
        remap.onKeyboardChange = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.hyperActive, self.config.hyperSource == .capsLock else { return }
                if let failure = self.remap.refresh() { self.error = failure }
            }
        }
        checkTap()
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTap() }
        }
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestListenEventAccess()
        installTap()
    }

    func stop() {
        cancelRecording()
        retryTimer?.invalidate()
        retryTimer = nil
        keyboardRetryTimer?.invalidate()
        keyboardRetryTimer = nil
        if let pendingSave {
            pendingSave.cancel()
            self.pendingSave = nil
            persist()
        }
        remap.onKeyboardChange = nil
        remap.disable()
        hyperHeld = false
        hyperActive = false
        consumedKeys.removeAll()
        hyperModifiedKeys.removeAll()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    func update(_ value: CrispConfig) {
        if let failure = value.validationError { report(failure); return }
        error = nil
        config = value
        resetLayoutCycle()
    }

    func beginRecording(id: UUID, action: @escaping (Shortcut) -> Void) {
        guard keyboardReady, let tap, CGEvent.tapIsEnabled(tap: tap) else {
            error = "Allow Accessibility and Input Monitoring before recording shortcuts."
            return
        }
        cancelRecording()
        recordingID = id
        recordAction = action
        recordMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.cancelRecording() }
            return event
        }
        recordGlobalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRecording() }
        }
        recordWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRecording() }
        }
    }

    /// Assign a recorded shortcut by identity. A row deleted while recording simply
    /// no longer matches, so a late keystroke can never write through a stale index.
    func assignShortcut(_ shortcut: Shortcut, to id: UUID, kind: BindingTarget) {
        var config = config
        switch kind {
        case .app:
            guard let index = config.apps.firstIndex(where: { $0.id == id }) else { return }
            config.apps[index].shortcut = shortcut
        case .layout:
            guard let index = config.layouts.firstIndex(where: { $0.id == id }) else { return }
            config.layouts[index].shortcut = shortcut
        }
        update(config)
    }

    func cancelRecording(id: UUID? = nil) {
        guard id == nil || recordingID == id else { return }
        recordingID = nil
        recordAction = nil
        if let recordMouseMonitor { NSEvent.removeMonitor(recordMouseMonitor) }
        recordMouseMonitor = nil
        if let recordGlobalMouseMonitor { NSEvent.removeMonitor(recordGlobalMouseMonitor) }
        recordGlobalMouseMonitor = nil
        if let recordWindowObserver { NotificationCenter.default.removeObserver(recordWindowObserver) }
        recordWindowObserver = nil
    }

    private func save() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSave = nil
            self.persist()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "crisp.config")
        }
    }

    private func installTap() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else { keyboardReady = false; return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let created = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                              options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                              callback: crispEventCallback,
                                              userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            keyboardReady = false
            error = "Could not monitor keys. Allow Crisp in Accessibility and Input Monitoring."
            return
        }
        tap = created
        let loopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        source = loopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        keyboardReady = CGEvent.tapIsEnabled(tap: created)
        if keyboardReady { updateHyper() }
        else { error = "Keyboard monitoring is unavailable. Check Accessibility and Input Monitoring." }
    }

    private func checkTap() {
        if tap == nil { installTap() }
        else if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            keyboardReady = CGEvent.tapIsEnabled(tap: tap)
            if keyboardReady { updateHyper() }
            else {
                cancelRecording()
                hyperActive = false
                hyperHeld = false
                hyperModifiedKeys.removeAll()
                remap.disable()
                stopKeyboardWatchdog()
            }
        }
    }

    private func updateHyper() {
        cancelRecording()
        hyperHeld = false
        hyperActive = false
        hyperModifiedKeys.removeAll()
        if config.hyperSource == .capsLock && keyboardReady {
            if let failure = remap.enable() {
                error = failure
                stopKeyboardWatchdog()
            }
            else {
                hyperActive = true
                startKeyboardWatchdog()
            }
        } else {
            remap.disable()
            hyperActive = config.hyperSource != .off && keyboardReady
            stopKeyboardWatchdog()
        }
    }

    private func startKeyboardWatchdog() {
        guard keyboardRetryTimer == nil else { return }
        // Device-match callbacks handle normal connects immediately. This slower
        // fallback catches Bluetooth replacements that macOS reports silently.
        keyboardRetryTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hyperActive, self.config.hyperSource == .capsLock else { return }
                if let failure = self.remap.refresh() { self.error = failure }
            }
        }
    }

    private func stopKeyboardWatchdog() {
        keyboardRetryTimer?.invalidate()
        keyboardRetryTimer = nil
    }

    fileprivate func handle(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .flagsChanged {
            if config.hyperSource.suppressesRawCapsLock(keyCode: code, isActive: hyperActive) {
                // A just-connected keyboard can report raw Caps Lock before HID maps it.
                // Only undo a transition into the locked state; a pre-existing
                // locked state is not ours to clear on an unlocking keypress.
                let becameLocked = event.flags.contains(.maskAlphaShift)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.hyperActive, self.config.hyperSource == .capsLock else { return }
                    if becameLocked { self.remap.clearCapsLockState() }
                    if let failure = self.remap.refresh() { self.error = failure }
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        if hyperActive, let hyperKey = config.hyperSource.keyCode, code == hyperKey {
            if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { hyperHeld = true }
            if type == .keyUp { hyperHeld = false }
            return nil // tap alone must not type F18 or toggle Caps Lock.
        }
        if config.hyperSource.suppressesRawCapsLock(keyCode: code, isActive: hyperActive),
           type == .keyDown {
            // A competing per-keyboard remap can turn Caps Lock into a printable
            // key such as `~`; swallow its down and matching up as well.
            consumedKeys.insert(code)
            return nil
        }
        if type == .keyUp {
            let wasModified = hyperModifiedKeys.remove(code) != nil
            if consumedKeys.remove(code) != nil { return nil }
            if wasModified { event.flags.insert([.maskCommand, .maskControl, .maskAlternate, .maskShift]) }
            return Unmanaged.passUnretained(event)
        }
        if hyperHeld {
            hyperModifiedKeys.insert(code)
            event.flags.insert([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        }
        let flags = event.flags
        if recordingID != nil {
            consumedKeys.insert(code)
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                if code == 53 && flags.rawValue & Shortcut.hyper == 0 {
                    cancelRecording()
                } else if let shortcut = Shortcut.recorded(keyCode: code, flags: flags),
                          shortcut.key != config.hyperSource.keyCode {
                    let action = recordAction
                    cancelRecording()
                    action?(shortcut)
                }
            }
            return nil
        }
        let modifiers = flags.rawValue & Shortcut.hyper
        guard modifiers != 0 else { return Unmanaged.passUnretained(event) }
        let shortcut = Shortcut(modifiers: modifiers, key: code)
        guard let action = resolver[shortcut] else { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
        switch action {
        case .layout:
            consumedKeys.insert(code)
            DispatchQueue.main.async { [weak self] in self?.applyLayout(for: shortcut) }
        case .app(let binding):
            consumedKeys.insert(code)
            resetLayoutCycle()
            DispatchQueue.main.async { [weak self] in self?.focus(binding) }
        case .space(let direction):
            switch switcher.switchTo(direction) {
            case .switched:
                consumedKeys.insert(code)
                resetLayoutCycle()
            case .blockedAtBoundary:
                consumedKeys.insert(code)
            case .cannotDetermineBoundary:
                // Never pass an unverified edge press to macOS; that can attempt a nonexistent Space.
                consumedKeys.insert(code)
                report("Couldn't inspect the native Space list; this shortcut was suppressed.")
            case .gestureUnavailable:
                // Keep native switching as a fallback when a valid adjacent Space exists.
                return Unmanaged.passUnretained(event)
            }
        }
        return nil
    }

    private func applyLayout(for shortcut: Shortcut) {
        guard config.windowManagementEnabled else { return }
        switch windows.focusedTarget() {
        case .failure(let failure):
            report(failure)
            resetLayoutCycle()
        case .found(let target):
            let sameWindow = target.windowID != 0 && lastWindowID == target.windowID
            let eligible = resolver.layouts(for: shortcut, screen: ScreenSize.classify(target.screen.frame))
            guard let layout = layoutCycle.next(in: eligible, for: shortcut, sameWindow: sameWindow) else {
                report("No layout for this shortcut is available on this display.")
                return
            }
            if let failure = windows.apply(layout, to: target) { report(failure) }
            else {
                layoutCycle.didApply(layout, for: shortcut)
                lastWindowID = target.windowID == 0 ? nil : target.windowID
            }
        }
    }

    /// Publishing an unchanged error would invalidate the settings UI on every failed press.
    private func report(_ message: String) {
        if error != message { error = message }
    }

    private func resetLayoutCycle() {
        layoutCycle.reset()
        lastWindowID = nil
    }

    private func focus(_ binding: AppBinding) {
        if binding.bundleID == "com.apple.finder" {
            focusFinder()
            return
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: binding.bundleID).first
        let plan = AppFocusPlan.make(isRunning: running != nil,
                                     minimizedWindows: running.flatMap { appWindowStates($0.processIdentifier) })
        switch plan {
        case .activate:
            activate(running!, binding: binding, options: [])
        case .restoreMinimizedWindow:
            activate(running!, binding: binding, options: [])
            restoreMinimizedWindow(running!.processIdentifier)
        case .reopenWindow:
            guard let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: binding.bundleID) else {
                error = "App not found: \\(binding.bundleID)"
                return
            }
            openApplication(binding, at: url)
        case .launch:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: binding.bundleID) else {
                error = "App not found: \\(binding.bundleID)"
                return
            }
            openApplication(binding, at: url)
        }
    }

    private func activate(_ application: NSRunningApplication, binding: AppBinding,
                          options: NSApplication.ActivationOptions) {
        guard !application.isTerminated else {
            guard let url = application.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: binding.bundleID) else {
                error = "App not found: \\(binding.bundleID)"
                return
            }
            openApplication(binding, at: url)
            return
        }
        if !application.activate(options: options) {
            error = "Couldn't focus \\(binding.name)."
        }
    }

    private func openApplication(_ binding: AppBinding, at url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] application, failure in
            Task { @MainActor in
                guard let self else { return }
                if let failure { self.error = failure.localizedDescription }
                else if application == nil { self.error = "Couldn't open \\(binding.name)." }
            }
        }
    }

    private func focusFinder() {
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        if let finder {
            let windows = appWindows(finder.processIdentifier)
            let usableWindows = windows?.filter(isUsableWindow) ?? []
            if usableWindows.contains(where: { !isMinimizedWindow($0) }) {
                activate(finder, binding: finderBinding, options: [])
                return
            }
            if !usableWindows.isEmpty {
                activate(finder, binding: finderBinding, options: [])
                restoreMinimizedWindow(finder.processIdentifier)
                return
            }
        }
        // Finder reports desktop/utility AX windows even with no file-browser
        // window. Do not treat those as evidence that Finder has a usable window.
        // Open the home folder to create one, including after closing its last one.
        guard NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: NSHomeDirectory()) else {
            error = "Couldn't open a Finder window."
            return
        }
    }

    private func isUsableWindow(_ window: AXUIElement) -> Bool {
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String, role == (kAXWindowRole as String) else { return false }
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) == .success,
           let subrole = subrole as? String, subrole == (kAXStandardWindowSubrole as String) {
            return true
        }
        var title: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success
            && !(title as? String ?? "").isEmpty
    }

    private func isMinimizedWindow(_ window: AXUIElement) -> Bool {
        var minimized: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success
            && (minimized as? NSNumber)?.boolValue == true
    }

    private var finderBinding: AppBinding {
        config.apps.first(where: { $0.bundleID == "com.apple.finder" })
            ?? AppBinding(name: "Finder", bundleID: "com.apple.finder",
                          shortcut: Shortcut(modifiers: Shortcut.option, key: 3))
    }

    private func appWindows(_ processIdentifier: pid_t) -> [AXUIElement]? {
        let application = AXUIElementCreateApplication(processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows
    }

    private func appWindowStates(_ processIdentifier: pid_t) -> [Bool]? {
        guard let windows = appWindows(processIdentifier) else { return nil }
        var states: [Bool] = []
        for window in windows {
            var minimized: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
                  let minimized, CFGetTypeID(minimized) == CFBooleanGetTypeID() else { return nil }
            states.append((minimized as! NSNumber).boolValue)
        }
        return states
    }

    private func restoreMinimizedWindow(_ processIdentifier: pid_t) {
        guard let windows = appWindows(processIdentifier) else { return }
        for window in windows {
            var minimized: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
                  let minimized, CFGetTypeID(minimized) == CFBooleanGetTypeID(),
                  (minimized as! NSNumber).boolValue else { continue }
            _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return
        }
    }
}

private func crispEventCallback(_ proxy: CGEventTapProxy, _ type: CGEventType,
                                _ event: CGEvent, _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<CrispController>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { controller.cancelRecording() }
        Task { @MainActor in controller.start() }
        return Unmanaged.passUnretained(event)
    }
    return MainActor.assumeIsolated { controller.handle(event, type: type) }
}
