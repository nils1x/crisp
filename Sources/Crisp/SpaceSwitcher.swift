import ApplicationServices
import CoreGraphics
import Foundation

// Undocumented DockSwipe protocol adapted from Tahul/space-rabbit (MPL-2.0),
// App/SpaceSwitching.swift at commit 54d6eb4; packed fields cross-checked
// against mgbowen/FasterSwiper (Apache-2.0), src/gesture-serialization.cc.
// No private framework or SIP change. Dock acceptance still needs physical testing.
enum SpaceGesture {
    enum Direction { case previous, next }
    enum Phase: Int64, CaseIterable { case began = 1, changed = 2, ended = 4 }
    static let velocity = 9999.0
    static let epsilon = 1.0 / 65536.0

    static func progress(phase: Phase, sign: Double) -> Double {
        sign * (phase == .began ? epsilon : 1)
    }

    static func sign(direction: Direction, augmented: Bool, naturalScrolling: Bool) -> Double {
        (direction == .next ? 1 : -1) * (augmented && naturalScrolling ? -1 : 1)
    }

    static func fixed(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        let scaled = min(max((value * 65536).rounded(.towardZero), Double(Int32.min)), Double(Int32.max))
        let result = Int32(scaled)
        return result == 0 && value != 0 ? (value > 0 ? 1 : -1) : result
    }

    static func payload(phase: Phase, sign: Double, timestamp: UInt64) -> Data {
        var data = Data()
        data.add(timestamp)
        data.add(UInt64(0)) // sender
        data.add(UInt32(0)) // options
        data.add(UInt32(0)) // attribute length
        data.add(UInt32(phase == .ended ? 2 : 1))
        data.add(UInt32(40)) // fluid gesture event length
        data.add(UInt32(23)) // fluid gesture HID type
        data.add(UInt32(phase.rawValue << 24))
        data.append(contentsOf: [0, 0, 0, 0]) // depth + reserved
        data.add(fixed(0.1)) // X
        data.add(Int32(0)) // Y
        data.add(Int32(0)) // Z
        data.add(UInt32(0)) // swipe mask
        data.add(UInt16(1)) // horizontal motion
        data.add(UInt16(3)) // Dock primary flavor
        data.add(fixed(progress(phase: phase, sign: sign))) // progress
        if phase == .ended {
            data.add(UInt32(28)) // velocity event length
            data.add(UInt32(9))  // velocity HID type
            data.add(UInt32(0))
            data.append(contentsOf: [1, 0, 0, 0]) // depth + reserved
            data.add(fixed(sign * velocity))
            data.add(Int32(0))
            data.add(Int32(0))
        }
        return data
    }

    static func augment(_ event: CGEvent, payload: Data) -> CGEvent? {
        guard var bytes = event.__data(allocator: nil) as Data?, bytes.starts(with: [0, 0, 0, 2]),
              payload.count < 65536 else { return nil }
        bytes.append(UInt8(payload.count >> 8))
        bytes.append(UInt8(payload.count & 255))
        bytes.append(contentsOf: [0x10, 0x6d]) // big-endian 4205
        bytes.append(payload)
        return CGEvent(withDataAllocator: nil, data: bytes as CFData)
    }
}

private extension Data {
    mutating func add<T: FixedWidthInteger>(_ number: T) {
        Swift.withUnsafeBytes(of: number.littleEndian) { append(contentsOf: $0) }
    }
}

enum SpaceBoundary {
    // Nil means the private Space state was incomplete or ambiguous; callers must fail closed.
    static func canMove(spaceLists: [[UInt64]], activeSpaceID: UInt64,
                        direction: SpaceGesture.Direction) -> Bool? {
        guard let spaceIDs = spaceLists.first, spaceLists.allSatisfy({ $0 == spaceIDs }) else { return nil }
        return canMove(spaceIDs: spaceIDs, activeSpaceID: activeSpaceID, direction: direction)
    }

    static func canMove(spaceIDs: [UInt64], activeSpaceID: UInt64,
                        direction: SpaceGesture.Direction) -> Bool? {
        guard !spaceIDs.isEmpty else { return nil }
        let matches = spaceIDs.indices.filter { spaceIDs[$0] == activeSpaceID }
        guard matches.count == 1, let index = matches.first else { return nil }
        switch direction {
        case .previous: return index > 0
        case .next: return index < spaceIDs.count - 1
        }
    }
}

struct SpaceLocation {
    let spaceID: UInt64
    let displayID: CGDirectDisplayID
    let spaceIDs: [UInt64]
    let currentSpaceID: UInt64
    let targetIndex: Int
    let currentIndex: Int
}

private final class SpaceBoundaryReader {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias ActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias ManagedSpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias ManagedDisplaySpace = @convention(c) (Int32, CFString) -> UInt64
    private typealias SpacesForWindow = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private let library: UnsafeMutableRawPointer?
    private let mainConnection: MainConnection?
    private let activeSpace: ActiveSpace?
    private let managedSpaces: ManagedSpaces?
    private let managedDisplaySpace: ManagedDisplaySpace?
    private let spacesForWindow: SpacesForWindow?

    init() {
        library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        if let library {
            mainConnection = dlsym(library, "CGSMainConnectionID").map { unsafeBitCast($0, to: MainConnection.self) }
            activeSpace = dlsym(library, "CGSGetActiveSpace").map { unsafeBitCast($0, to: ActiveSpace.self) }
            managedSpaces = dlsym(library, "CGSCopyManagedDisplaySpaces").map { unsafeBitCast($0, to: ManagedSpaces.self) }
            managedDisplaySpace = (dlsym(library, "CGSManagedDisplayGetCurrentSpace")
                ?? dlsym(library, "SLSManagedDisplayGetCurrentSpace"))
                .map { unsafeBitCast($0, to: ManagedDisplaySpace.self) }
            spacesForWindow = dlsym(library, "SLSCopySpacesForWindows")
                .map { unsafeBitCast($0, to: SpacesForWindow.self) }
        } else {
            mainConnection = nil
            activeSpace = nil
            managedSpaces = nil
            managedDisplaySpace = nil
            spacesForWindow = nil
        }
    }

    func currentSpaces() -> [UInt64]? {
        guard let mainConnection, let managedSpaces, let managedDisplaySpace else { return nil }
        let connection = mainConnection()
        guard connection != 0, let result = managedSpaces(connection) else { return nil }
        let displays = result.takeRetainedValue() as NSArray
        var spaces: [UInt64] = []
        for case let display as NSDictionary in displays {
            guard let identifier = display["Display Identifier"] as? String else { return nil }
            spaces.append(managedDisplaySpace(connection, identifier as CFString))
        }
        return spaces.isEmpty ? nil : spaces
    }

    func location(ofWindow windowID: UInt32) -> SpaceLocation? {
        guard let mainConnection, let spacesForWindow else { return nil }
        let connection = mainConnection()
        guard connection != 0 else { return nil }
        let windowList = [NSNumber(value: windowID)] as CFArray
        guard let windowSpaces = spacesForWindow(connection, 0x7, windowList)?.takeRetainedValue() as? [NSNumber],
              let targetSpaceID = windowSpaces.first?.uint64Value else { return nil }
        return location(ofSpaceID: targetSpaceID)
    }

    func location(ofSpaceID targetSpaceID: UInt64) -> SpaceLocation? {
        guard let mainConnection, let managedSpaces, let managedDisplaySpace else { return nil }
        let connection = mainConnection()
        guard connection != 0, let result = managedSpaces(connection) else { return nil }
        let displays = result.takeRetainedValue() as NSArray
        var matches: [SpaceLocation] = []
        for case let display as NSDictionary in displays {
            guard let identifier = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [NSDictionary] else { return nil }
            let spaceIDs = spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
            guard spaceIDs.count == spaces.count else { return nil }
            guard let targetIndex = spaceIDs.firstIndex(of: targetSpaceID) else { continue }
            let currentSpaceID = managedDisplaySpace(connection, identifier as CFString)
            guard let currentIndex = spaceIDs.firstIndex(of: currentSpaceID),
                  let displayID = displayID(for: identifier) else { return nil }
            matches.append(SpaceLocation(spaceID: targetSpaceID, displayID: displayID,
                                         spaceIDs: spaceIDs, currentSpaceID: currentSpaceID,
                                         targetIndex: targetIndex, currentIndex: currentIndex))
        }
        return matches.first
    }

    private func displayID(for identifier: String) -> CGDirectDisplayID? {
        if identifier == "Main" { return CGMainDisplayID() }
        guard let uuid = CFUUIDCreateFromString(kCFAllocatorDefault, identifier as CFString) else { return nil }
        let displayID = CGDisplayGetDisplayIDFromUUID(uuid)
        return displayID == kCGNullDirectDisplay ? nil : displayID
    }

    func canMove(_ direction: SpaceGesture.Direction) -> Bool? {
        guard let mainConnection, let activeSpace, let managedSpaces else { return nil }
        let connection = mainConnection()
        guard connection != 0, let result = managedSpaces(connection) else { return nil }
        let activeID = activeSpace(connection)
        guard activeID != 0 else { return nil }

        let displays = result.takeRetainedValue() as NSArray
        var candidateLists: [[UInt64]] = []
        for case let display as NSDictionary in displays {
            guard let spaces = display["Spaces"] as? [NSDictionary] else { continue }
            let ids = spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
            guard ids.count == spaces.count else { return nil }
            if ids.contains(activeID) { candidateLists.append(ids) }
        }
        return SpaceBoundary.canMove(spaceLists: candidateLists, activeSpaceID: activeID,
                                     direction: direction)
    }
}

@MainActor
final class SpaceSwitcher {
    enum Result { case switched, blockedAtBoundary, cannotDetermineBoundary, gestureUnavailable }

    private let augmented = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    private let boundaryReader = SpaceBoundaryReader()
    private let eventSource = CGEventSource(stateID: .combinedSessionState)

    func currentSpaces() -> [UInt64]? {
        boundaryReader.currentSpaces()
    }

    func location(forWindowID windowID: UInt32) -> SpaceLocation? {
        boundaryReader.location(ofWindow: windowID)
    }

    // Check the actual ordered Space list before synthesizing the Dock swipe.
    // Build all phases before posting: an incomplete swipe could strand Dock's gesture state.
    func switchTo(_ direction: SpaceGesture.Direction) -> Result {
        guard let canMove = boundaryReader.canMove(direction) else { return .cannotDetermineBoundary }
        guard canMove else { return .blockedAtBoundary }
        guard AXIsProcessTrusted() else { return .gestureUnavailable }
        // The preference lives in the global domain, not Crisp's UserDefaults.
        // Read its cached current value here; synchronizing disk from the key event
        // path can add avoidable latency to every Space shortcut.
        let natural = CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString,
                                                kCFPreferencesAnyApplication) as? Bool ?? true
        return postSwipe(direction, naturalScrolling: natural) ? .switched : .gestureUnavailable
    }

    // Jump to an app's Space by posting one fast swipe for each intervening Space.
    // The Dock handles these gestures on the display under the pointer.
    func switchToSpace(_ spaceID: UInt64) -> Result {
        guard let location = boundaryReader.location(ofSpaceID: spaceID) else {
            return .cannotDetermineBoundary
        }
        return switchToSpace(location: location)
    }

    func switchToSpace(location: SpaceLocation) -> Result {
        guard location.targetIndex != location.currentIndex else { return .switched }
        guard AXIsProcessTrusted() else { return .gestureUnavailable }
        guard let pointerEvent = CGEvent(source: nil) else { return .gestureUnavailable }

        let originalPointer = pointerEvent.location
        let bounds = CGDisplayBounds(location.displayID)
        let shouldWarp = !bounds.contains(originalPointer)
        if shouldWarp {
            eventSource?.localEventsSuppressionInterval = 0
            CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        defer {
            if shouldWarp {
                CGWarpMouseCursorPosition(originalPointer)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }

        let direction: SpaceGesture.Direction = location.targetIndex > location.currentIndex ? .next : .previous
        let steps = abs(location.targetIndex - location.currentIndex)
        let natural = naturalScrolling
        let sign = SpaceGesture.sign(direction: direction, augmented: augmented,
                                     naturalScrolling: natural)
        for step in 0..<steps {
            guard postSwipe(direction, naturalScrolling: natural, sign: sign) else { return .gestureUnavailable }
            if shouldWarp || step < steps - 1 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            }
        }
        return .switched
    }

    private var naturalScrolling: Bool {
        CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString,
                                  kCFPreferencesAnyApplication) as? Bool ?? true
    }

    private func postSwipe(_ direction: SpaceGesture.Direction, naturalScrolling: Bool,
                           sign explicitSign: Double? = nil) -> Bool {
        guard let type = CGEventField(rawValue: 55) else { return false }
        let sign = explicitSign ?? SpaceGesture.sign(direction: direction, augmented: augmented,
                                                      naturalScrolling: naturalScrolling)
        let phases: [SpaceGesture.Phase] = augmented ? [.began, .changed, .ended] : [.began, .ended]
        var pairs: [(CGEvent, CGEvent)] = []
        for phase in phases {
            guard let dock = makeEvent(phase: phase, sign: sign, direction: direction),
                  let envelope = CGEvent(source: eventSource) else { return false }
            envelope.setIntegerValueField(type, value: 29)
            pairs.append((dock, envelope))
        }
        for (dock, envelope) in pairs {
            dock.post(tap: .cgSessionEventTap)
            envelope.post(tap: .cgSessionEventTap)
        }
        return true
    }

    private func makeEvent(phase: SpaceGesture.Phase, sign: Double,
                           direction: SpaceGesture.Direction) -> CGEvent? {
        guard let event = CGEvent(source: eventSource) else { return nil }
        for (field, value) in [(55, Int64(30)), (110, 23), (132, phase.rawValue), (123, 1)] {
            guard let key = CGEventField(rawValue: UInt32(field)) else { return nil }
            event.setIntegerValueField(key, value: value)
        }
        if augmented {
            guard let phaseAlias = CGEventField(rawValue: 134) else { return nil }
            event.setIntegerValueField(phaseAlias, value: phase.rawValue)
            let doubles: [(UInt32, Double)] = [
                (124, SpaceGesture.progress(phase: phase, sign: sign)),
                (138, 3), (169, Double(mach_absolute_time())), (125, 0.1),
                (129, phase == .ended ? sign * SpaceGesture.velocity : 0)
            ]
            for (field, value) in doubles {
                guard let key = CGEventField(rawValue: field) else { return nil }
                event.setDoubleValueField(key, value: value)
            }
            let timestamp = event.timestamp != 0 ? UInt64(event.timestamp) : mach_absolute_time()
            return SpaceGesture.augment(event, payload: SpaceGesture.payload(
                phase: phase, sign: sign, timestamp: timestamp))
        }
        guard let flag = CGEventField(rawValue: 135),
              let zoom = CGEventField(rawValue: 139),
              let progress = CGEventField(rawValue: 124),
              let velocity = CGEventField(rawValue: 129) else { return nil }
        event.setIntegerValueField(flag, value: direction == .next ? 1 : 0)
        event.setDoubleValueField(zoom, value: Double(Float.leastNonzeroMagnitude))
        event.setDoubleValueField(progress, value: phase == .ended ? sign * 2 : 0)
        event.setDoubleValueField(velocity, value: phase == .ended ? sign * 400 : 0)
        return event
    }
}
