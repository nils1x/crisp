import Foundation
import IOKit.hid
import IOKit.hidsystem

enum CapsLockMappingState: Equatable {
    case missing
    case desired
    case conflict
}

/// Remap Caps Lock before the keyboard driver toggles its state. Only touch
/// keyboard services without a mapping for Caps Lock; restore only our entry.
final class HyperRemap {
    private static let source: UInt64 = 0x700000039
    private static let destination: UInt64 = 0x70000006D // F18
    private let source = HyperRemap.source
    private let destination = HyperRemap.destination
    private let key = "UserKeyMapping" as CFString
    private let sourceKey = "HIDKeyboardModifierMappingSrc"
    private let destinationKey = "HIDKeyboardModifierMappingDst"

    static func mappingState(in mappings: [[String: NSNumber]]) -> CapsLockMappingState {
        let capsLockMappings = mappings.filter { $0["HIDKeyboardModifierMappingSrc"]?.uint64Value == HyperRemap.source }
        guard !capsLockMappings.isEmpty else { return .missing }
        return capsLockMappings.allSatisfy {
            $0["HIDKeyboardModifierMappingDst"]?.uint64Value == HyperRemap.destination
        } ? .desired : .conflict
    }

    static func removingCrispMapping(from mappings: [[String: NSNumber]]) -> [[String: NSNumber]] {
        guard let index = mappings.lastIndex(where: {
            $0["HIDKeyboardModifierMappingSrc"]?.uint64Value == source
                && $0["HIDKeyboardModifierMappingDst"]?.uint64Value == destination
        }) else { return mappings }
        var remaining = mappings
        remaining.remove(at: index)
        return remaining
    }

    // Registry IDs identify services for the lifetime of a connection. Never
    // retain a service/client snapshot across keyboard reconnects.
    private var owned: Set<UInt64> = []
    private var manager: IOHIDManager?
    private var active = false
    var onKeyboardChange: (() -> Void)?

    func enable() -> String? {
        if active { return nil }
        guard owned.isEmpty else {
            return "A previous Caps Lock mapping could not be removed. Check it before retrying."
        }
        active = true
        if let failure = refresh() {
            disable()
            return failure
        }
        watchKeyboards()
        return nil
    }

    // Mapping is per keyboard service, not global. Bluetooth keyboards can arrive
    // after launch (or get a new service on reconnection).
    func refresh() -> String? {
        guard active else { return nil }
        // A retained event-system client can miss a new Bluetooth keyboard service.
        // Create a fresh snapshot on every refresh, including the periodic fallback.
        let system = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let services = IOHIDEventSystemClientCopyServices(system) as? [IOHIDServiceClient] else {
            return "Could not inspect connected keyboards."
        }
        let keyboards = services.filter { IOHIDServiceClientConformsTo($0, 1, 6) != 0 }
        guard !keyboards.isEmpty else { return "No keyboard service found; Caps Lock was not changed." }
        let entry: [String: NSNumber] = [sourceKey: NSNumber(value: source),
                                          destinationKey: NSNumber(value: destination)]
        // Read and inspect every service before writing any newly discovered one.
        // Keep each registry ID from this pass; the eight-second watchdog must not
        // query the same service IDs once to prune ownership and again to map.
        var snapshots: [(service: IOHIDServiceClient, id: UInt64, mappings: [[String: NSNumber]])] = []
        for service in keyboards {
            guard let id = serviceID(service), let current = mappings(for: service) else {
                return "Could not read a keyboard mapping."
            }
            if Self.mappingState(in: current) == .conflict {
                return "Caps Lock is already mapped to a different key. Disable that remap or choose another Hyper source."
            }
            snapshots.append((service, id, current))
        }
        owned.formIntersection(Set(snapshots.map(\.id)))
        for (service, id, current) in snapshots {
            switch Self.mappingState(in: current) {
            case .desired:
                // An existing Caps Lock→F18 mapping already provides Hyper. Do
                // not claim or remove a mapping that this Crisp session did not create.
                continue
            case .conflict:
                return "Caps Lock is already mapped to a different key. Disable that remap or choose another Hyper source."
            case .missing:
                break
            }
            // If the mapping vanished while connected, reclaim it on the live service.
            owned.remove(id)
            guard IOHIDServiceClientSetProperty(service, key, (current + [entry]) as CFArray) else {
                return "Couldn't remap a connected keyboard's Caps Lock."
            }
            owned.insert(id) // Retain ownership for normal Quit, even if verification fails.
            guard let applied = mappings(for: service), applied.contains(where: {
                $0[sourceKey]?.uint64Value == source && $0[destinationKey]?.uint64Value == destination
            }) else { return "Caps Lock remap was not confirmed on a connected keyboard." }
        }
        return nil
    }

    // Only correct a *reported raw Caps Lock event*. Never change the user's
    // existing lock state on startup or when Hyper is disabled.
    func clearCapsLockState() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connection) }
        var locked = false
        if IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &locked) == KERN_SUCCESS, locked {
            _ = IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), false)
        }
    }

    private func serviceID(_ service: IOHIDServiceClient) -> UInt64? {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value
    }

    private func watchKeyboards() {
        guard manager == nil else { return }
        let monitor = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(monitor, [kIOHIDDeviceUsagePageKey: 1,
                                                kIOHIDDeviceUsageKey: 6] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(monitor, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<HyperRemap>.fromOpaque(context).takeUnretainedValue().onKeyboardChange?()
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(monitor, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        if IOHIDManagerOpen(monitor, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
            manager = monitor
        } else {
            IOHIDManagerUnscheduleFromRunLoop(monitor, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
    }

    func disable() {
        active = false
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            self.manager = nil
        }
        let system = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let services = IOHIDEventSystemClientCopyServices(system) as? [IOHIDServiceClient] else { return }
        let keyboards = services.filter { IOHIDServiceClientConformsTo($0, 1, 6) != 0 }
        let liveIDs = Set(keyboards.compactMap { serviceID($0) })
        owned.formIntersection(liveIDs) // A disconnected service has nothing to restore.
        for service in keyboards {
            guard let id = serviceID(service), owned.contains(id), let current = mappings(for: service) else { continue }
            // Remove the mapping Crisp installed. An identical mapping that was
            // already present was never added to `owned` and is left untouched.
            let withoutOurs = Self.removingCrispMapping(from: current)
            if current.count == withoutOurs.count { owned.remove(id); continue }
            if IOHIDServiceClientSetProperty(service, key, withoutOurs as CFArray),
               let applied = mappings(for: service), applied == withoutOurs {
                owned.remove(id)
            }
        }
    }

    private func mappings(for service: IOHIDServiceClient) -> [[String: NSNumber]]? {
        guard let property = IOHIDServiceClientCopyProperty(service, key) else { return [] }
        return property as? [[String: NSNumber]]
    }

    deinit { disable() }
}
