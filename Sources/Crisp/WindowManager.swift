import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func axUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

@MainActor
final class WindowManager {
    struct Target {
        let window: AXUIElement
        let windowID: CGWindowID
        let screen: NSScreen
    }

    enum TargetResult {
        case found(Target)
        case failure(String)
    }

    // One runloop turn performs several reads of the screen list, the AX tree and
    // `visibleFrame`. Snapshot them and drop the cache on the next turn, so a burst
    // of shortcuts in the same frame costs one set of queries instead of one each.
    private struct ScreenSnapshot {
        let screens: [NSScreen]
        let primaryTop: CGFloat
        let visibleFrames: [ObjectIdentifier: CGRect]
    }

    private var screens: ScreenSnapshot {
        if let cached = cachedScreens { return cached }
        let list = NSScreen.screens
        let snapshot = ScreenSnapshot(screens: list,
                                      primaryTop: list.first?.frame.maxY ?? 0,
                                      visibleFrames: Dictionary(uniqueKeysWithValues:
                                          list.map { (ObjectIdentifier($0), $0.visibleFrame) }))
        cachedScreens = snapshot
        if !screenCacheInvalidationPending {
            screenCacheInvalidationPending = true
            DispatchQueue.main.async { [weak self] in
                self?.cachedScreens = nil
                self?.screenCacheInvalidationPending = false
            }
        }
        return snapshot
    }
    private var cachedScreens: ScreenSnapshot?
    private var screenCacheInvalidationPending = false

    func focusedTarget() -> TargetResult {
        let snapshot = screens
        guard let app = NSWorkspace.shared.frontmostApplication else { return .failure("No focused application.") }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return .failure("No movable focused window in \(app.localizedName ?? "this app").")
        }
        let window = value as! AXUIElement
        var windowID: CGWindowID = 0
        _ = axUIElementGetWindow(window, &windowID)
        var pointValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pointValue) == .success,
              let pointValue, CFGetTypeID(pointValue) == AXValueGetTypeID() else {
            return .failure("This window doesn't expose its position.")
        }
        var point = CGPoint.zero
        // AX coordinates start at the primary display's top-left, not the
        // desktop's topmost edge. Convert before matching an AppKit screen.
        guard AXValueGetValue(pointValue as! AXValue, .cgPoint, &point),
              let screen = snapshot.screens.first(where: {
                  $0.frame.contains(CGPoint(x: point.x, y: snapshot.primaryTop - point.y))
              }) ?? snapshot.screens.first else {
            return .failure("No display found.")
        }
        return .found(Target(window: window, windowID: windowID, screen: screen))
    }

    func apply(_ layout: Layout, to target: Target) -> String? {
        guard layout.isValid else { return "Invalid layout dimensions." }
        let snapshot = screens
        guard layout.availableScreens.contains(ScreenSize.classify(target.screen.frame)) else {
            return "This layout isn't enabled for this display size."
        }
        guard let visibleFrame = snapshot.visibleFrames[ObjectIdentifier(target.screen)],
              let frame = layout.frame(in: visibleFrame) else {
            return "No usable frame found."
        }

        // Accessibility uses a top-left origin; AppKit frames use bottom-left.
        let position = CGPoint(x: frame.minX, y: snapshot.primaryTop - frame.maxY)
        let size = CGSize(width: frame.width, height: frame.height)
        // Repeating the current layout must not write the same frame again: the write
        // would make macOS re-animate the window for no visible change.
        if let current = currentFrame(of: target.window), current.origin == position, current.size == size {
            return nil
        }
        return setFrame(target.window, position: position, size: size)
    }

    private func currentFrame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func setFrame(_ window: AXUIElement, position: CGPoint, size: CGSize) -> String? {
        var point = position
        var dimensions = size
        guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &dimensions) else {
            return "Could not create accessibility values."
        }
        // Set size first, then position, then size again: some apps clamp on movement.
        let first = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
        let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p)
        let last = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
        return moved == .success && (first == .success || last == .success)
            ? nil : "This window refused to move or resize."
    }
}
