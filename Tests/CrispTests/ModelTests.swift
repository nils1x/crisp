import XCTest
@testable import Crisp

final class ModelTests: XCTestCase {
    func testInitialAppBindingsAndSpaces() {
        let config = CrispConfig.initial
        XCTAssertEqual(config.apps.count, 7)
        XCTAssertEqual(config.apps.first?.bundleID, "com.mitchellh.ghostty")
        XCTAssertEqual(config.apps.first?.shortcut, Shortcut(modifiers: Shortcut.option, key: 5))
        XCTAssertFalse(config.instantSpaces)
        XCTAssertEqual(config.hyperSource, .off)
        XCTAssertEqual(config.layouts.count, 17)
        XCTAssertEqual(config.layouts[1].name, "Right Half")
        XCTAssertEqual(config.layouts[2].name, "Right Third")
        XCTAssertEqual(config.layouts[1].shortcut, config.layouts[2].shortcut)
        XCTAssertTrue(config.layouts.allSatisfy(\.isValid))
        XCTAssertTrue(config.layouts.allSatisfy { $0.availableScreens == Set(ScreenSize.allCases) })
        XCTAssertEqual(config.layouts[12].name, "Left Fourth")
        XCTAssertEqual(config.layouts[13].name, "Middle Half")
        XCTAssertEqual(config.layouts[14].name, "Right Fourth")
        XCTAssertEqual(Set(config.layouts.map(\.shortcut)).count, config.layouts.count - 1)
        XCTAssertTrue(config.layouts.allSatisfy { $0.shortcut.isValid })
        XCTAssertTrue(config.apps.allSatisfy { $0.shortcut.isValid })
        XCTAssertEqual(config.apps.first(where: { $0.name == "Zed" })?.shortcut.key, 16)
    }

    func testLayoutUsesTopLeftOrigin() {
        let visible = CGRect(x: 10, y: 20, width: 800, height: 600)
        let left = Layout(name: "Top left", x: 0, y: 0, width: 0.5, height: 0.5,
                          shortcut: Shortcut(modifiers: Shortcut.hyper, key: 123))
        XCTAssertEqual(left.frame(in: visible), CGRect(x: 10, y: 320, width: 400, height: 300))
    }

    func testInvalidLayoutsAreRejected() {
        let layout = Layout(name: "Offscreen", x: 0.7, y: 0, width: 0.5, height: 1,
                            shortcut: Shortcut(modifiers: Shortcut.hyper, key: 123))
        XCTAssertNil(layout.frame(in: CGRect(x: 0, y: 0, width: 500, height: 500)))
    }

    func testScreenSizeClassification() {
        XCTAssertEqual(ScreenSize.classify(CGRect(x: 0, y: 0, width: 1600, height: 1000)), .macBook)
        XCTAssertEqual(ScreenSize.classify(CGRect(x: 0, y: 0, width: 1920, height: 1080)), .wide)
        XCTAssertEqual(ScreenSize.classify(CGRect(x: 0, y: 0, width: 3440, height: 1440)), .ultrawide)
        XCTAssertEqual(ScreenSize.classify(CGRect(x: 0, y: 0, width: 5120, height: 1440)), .superUltrawide)
        XCTAssertEqual(ScreenSize.classify(CGRect(x: 0, y: 0, width: 1080, height: 1920)), .vertical)
    }

    func testLayoutRequiresAtLeastOneScreenSize() {
        var layout = CrispConfig.initial.layouts[0]
        layout.availableScreens.removeAll()
        XCTAssertFalse(layout.isValid)
    }

    func testInvalidNumericLayouts() {
        var layout = CrispConfig.initial.layouts[0]
        layout.x = .nan
        XCTAssertFalse(layout.isValid)
        layout.x = .infinity
        XCTAssertFalse(layout.isValid)
    }

    func testLayoutDimensionParserAcceptsBothDecimalSeparators() {
        XCTAssertEqual(LayoutDimensions.parseValue("0.6"), 0.6)
        XCTAssertEqual(LayoutDimensions.parseValue("0,6"), 0.6)
        XCTAssertEqual(LayoutDimensions.parseValue(".25"), 0.25)
        XCTAssertEqual(LayoutDimensions.parseValue("1."), 1)
        XCTAssertNil(LayoutDimensions.parseValue("1,234.5"))
        XCTAssertNil(LayoutDimensions.parseValue("NaN"))
        XCTAssertNil(LayoutDimensions.parseValue("1.2"))
        XCTAssertNil(LayoutDimensions.parseValue("-0.1"))
    }

    func testLayoutDimensionsCanPassThroughInvalidIntermediateGeometry() {
        let layout = Layout(name: "Right Half", x: 0.5, y: 0, width: 0.5, height: 1,
                            shortcut: Shortcut(modifiers: Shortcut.hyper, key: 124))
        var draft = LayoutDimensions(layout)
        draft[.width] = 0.9
        XCTAssertFalse(draft.applying(to: layout).isValid)

        draft[.x] = 0.1
        let updated = draft.applying(to: layout)
        XCTAssertTrue(updated.isValid)
        XCTAssertEqual(updated.x, 0.1)
        XCTAssertEqual(updated.width, 0.9)
        XCTAssertEqual(updated.height, 1)
    }

    func testRecordedShortcutSupportsDeleteAndRejectsModifierOnlyKeys() {
        let center = Shortcut(modifiers: Shortcut.hyper, key: 51)
        XCTAssertTrue(center.isValid)
        XCTAssertEqual(center.label, "Hyper + Delete")
        XCTAssertEqual(Shortcut.recorded(keyCode: 51, flags: CGEventFlags(rawValue: Shortcut.hyper)), center)
        XCTAssertNil(Shortcut.recorded(keyCode: 51, flags: []))
        XCTAssertTrue(center.matches(keyCode: 51, flags: CGEventFlags(rawValue: Shortcut.hyper)))
        XCTAssertFalse(Shortcut(modifiers: 0, key: 51).isValid)
        XCTAssertFalse(Shortcut(modifiers: Shortcut.hyper, key: -1).isValid)
        XCTAssertFalse(Shortcut(modifiers: Shortcut.hyper, key: 128).isValid)
        XCTAssertFalse(Shortcut(modifiers: Shortcut.hyper, key: 56).isValid) // Shift alone
        XCTAssertTrue(Shortcut(modifiers: Shortcut.option, key: 0).isValid)
    }

    func testSharedLayoutShortcutCyclesInOrderAndResetsForAnotherWindow() {
        let resolver = ShortcutResolver(CrispConfig.initial)
        let shortcut = Shortcut(modifiers: Shortcut.hyper, key: 124)
        let layouts = resolver.layouts(for: shortcut, screen: .macBook)
        var cycle = LayoutCycle()
        let first = cycle.next(in: layouts, for: shortcut, sameWindow: false)
        XCTAssertEqual(first?.name, "Right Half")
        cycle.didApply(first!, for: shortcut)
        let second = cycle.next(in: layouts, for: shortcut, sameWindow: true)
        XCTAssertEqual(second?.name, "Right Third")
        cycle.didApply(second!, for: shortcut)
        XCTAssertEqual(cycle.next(in: layouts, for: shortcut, sameWindow: true)?.name, "Right Half")
        XCTAssertEqual(cycle.next(in: layouts, for: shortcut, sameWindow: false)?.name, "Right Half")
        cycle.reset()
        XCTAssertEqual(cycle.next(in: layouts, for: shortcut, sameWindow: true)?.name, "Right Half")
    }

    func testCycleSkipsLayoutsUnavailableOnTheDisplayAndDoesNotAdvanceOnFailure() {
        let shortcut = Shortcut(modifiers: Shortcut.hyper, key: 124)
        var config = CrispConfig.initial
        config.layouts[3].shortcut = shortcut               // Top Half joins the group
        config.layouts[3].availableScreens = [.wide]       // but only on this display
        var cycle = LayoutCycle()
        cycle.didApply(config.layouts[1], for: shortcut)    // Right Half was applied last
        let resolver = ShortcutResolver(config)
        // macBook cannot offer Top Half, so the cycle continues Right Half -> Right Third.
        XCTAssertEqual(cycle.next(in: resolver.layouts(for: shortcut, screen: .macBook), for: shortcut,
                                  sameWindow: true)?.name, "Right Third")
        // Wide adds Top Half at the end of the list; the stored position decides the next step.
        XCTAssertEqual(cycle.next(in: resolver.layouts(for: shortcut, screen: .wide), for: shortcut,
                                  sameWindow: true)?.name, "Right Third")
        config.layouts[3].enabled = false
        let narrowed = ShortcutResolver(config)
        XCTAssertEqual(cycle.next(in: narrowed.layouts(for: shortcut, screen: .wide), for: shortcut,
                                  sameWindow: true)?.name, "Right Third")
    }

    func testLayoutsMayShareAnyBindingWhileAppsRemainExclusive() {
        var config = CrispConfig.initial
        XCTAssertNil(config.validationError)
        config.layouts[1].shortcut = config.apps[0].shortcut
        XCTAssertNil(config.validationError) // Layout wins over app on collision.
        config.layouts[2].shortcut = Shortcut(modifiers: Shortcut.control, key: 124)
        config.instantSpaces = true
        XCTAssertNil(config.validationError) // Layout wins over instant Spaces.
        config.apps[0].shortcut = config.apps[1].shortcut
        XCTAssertNotNil(config.validationError)
        config.apps[0].shortcut = Shortcut(modifiers: Shortcut.control, key: 124)
        XCTAssertNil(config.validationError) // A layout may share an app and Spaces binding.
    }

    func testRawCapsLockIsSwallowedOnlyForActiveCapsLockHyper() {
        XCTAssertTrue(HyperSource.capsLock.suppressesRawCapsLock(keyCode: 57, isActive: true))
        XCTAssertFalse(HyperSource.capsLock.suppressesRawCapsLock(keyCode: 57, isActive: false))
        XCTAssertFalse(HyperSource.f18.suppressesRawCapsLock(keyCode: 57, isActive: true))
        XCTAssertFalse(HyperSource.capsLock.suppressesRawCapsLock(keyCode: 50, isActive: true))
    }

    func testCapsLockMappingStateRecognizesOwnedDesiredAndConflictingMappings() {
        let source = NSNumber(value: 0x700000039)
        let f18 = NSNumber(value: 0x70000006D)
        let f19 = NSNumber(value: 0x70000006E)
        let capsLock = "HIDKeyboardModifierMappingSrc"
        let destination = "HIDKeyboardModifierMappingDst"

        XCTAssertEqual(HyperRemap.mappingState(in: []), .missing)
        XCTAssertEqual(HyperRemap.mappingState(in: [[capsLock: source, destination: f18]]), .desired)
        XCTAssertEqual(HyperRemap.mappingState(in: [[capsLock: source, destination: f19]]), .conflict)
        XCTAssertEqual(HyperRemap.mappingState(in: [[capsLock: source, destination: f18],
                                                    [capsLock: source, destination: f19]]), .conflict)
        XCTAssertEqual(HyperRemap.mappingState(in: [["HIDKeyboardModifierMappingSrc": NSNumber(value: 0x700000038),
                                                    destination: f19]]), .missing)
    }

    func testCapsLockCleanupRemovesOnlyOneCrispMappingAndPreservesOthers() {
        let caps = "HIDKeyboardModifierMappingSrc"
        let destination = "HIDKeyboardModifierMappingDst"
        let source = NSNumber(value: 0x700000039)
        let f18 = NSNumber(value: 0x70000006D)
        let f19 = NSNumber(value: 0x70000006E)
        let shift = NSNumber(value: 0x7000000E1)
        let capsToF18: [String: NSNumber] = [caps: source, destination: f18]
        let capsToF18WithVendorField: [String: NSNumber] = [caps: source, destination: f18,
                                                           "VendorMetadata": NSNumber(value: 7)]
        let capsToF19: [String: NSNumber] = [caps: source, destination: f19]
        let shiftToF18: [String: NSNumber] = [caps: shift, destination: f18]
        let mappings = [capsToF18, shiftToF18, capsToF19, capsToF18WithVendorField]

        XCTAssertEqual(HyperRemap.removingCrispMapping(from: mappings), [capsToF18, shiftToF18, capsToF19])
        XCTAssertEqual(HyperRemap.removingCrispMapping(from: [capsToF18WithVendorField]), [])
        XCTAssertEqual(HyperRemap.removingCrispMapping(from: [capsToF18]), [])
        XCTAssertEqual(HyperRemap.removingCrispMapping(from: [shiftToF18, capsToF19]), [shiftToF18, capsToF19])
    }

    func testAppFocusPlanCoversRunningAndWindowStates() {
        XCTAssertEqual(AppFocusPlan.make(isRunning: false, minimizedWindows: nil), .launch)
        XCTAssertEqual(AppFocusPlan.make(isRunning: true, minimizedWindows: [false]), .activate)
        XCTAssertEqual(AppFocusPlan.make(isRunning: true, minimizedWindows: [false, true]), .activate)
        XCTAssertEqual(AppFocusPlan.make(isRunning: true, minimizedWindows: [true, true]), .restoreMinimizedWindow)
        XCTAssertEqual(AppFocusPlan.make(isRunning: true, minimizedWindows: []), .reopenWindow)
        XCTAssertEqual(AppFocusPlan.make(isRunning: true, minimizedWindows: nil), .reopenWindow)
    }

    func testFinderShortcutRoutesToConfiguredFinderBinding() {
        var config = CrispConfig.initial
        let finderShortcut = Shortcut(modifiers: Shortcut.option, key: 3)
        guard let finder = config.apps.first(where: { $0.bundleID == "com.apple.finder" }) else {
            return XCTFail("Finder binding should be configured")
        }
        XCTAssertEqual(finder.shortcut, finderShortcut)
        if case .app(let routed)? = config.action(for: finderShortcut) {
            XCTAssertEqual(routed.bundleID, "com.apple.finder")
        } else {
            XCTFail("Finder shortcut should route to its app action")
        }

        config.layouts.append(Layout(name: "Collision", x: 0, y: 0, width: 1, height: 1,
                                     shortcut: finderShortcut))
        if case .layout? = config.action(for: finderShortcut) {} else {
            XCTFail("An explicitly overlapping layout should keep its documented priority")
        }
    }

    func testDisablingWindowManagementPreservesLayoutsAndFallsThroughToAppOrSpace() {
        var config = CrispConfig.initial
        config.instantSpaces = true
        let originalLayouts = config.layouts
        let shortcut = Shortcut(modifiers: Shortcut.control, key: 124)
        config.layouts[1].shortcut = shortcut
        config.windowManagementEnabled = false
        XCTAssertEqual(config.layouts.count, originalLayouts.count)
        XCTAssertEqual(config.layouts[0], originalLayouts[0])
        XCTAssertEqual(config.layouts[1].shortcut, shortcut)
        if case .space(.next)? = config.action(for: shortcut) {} else {
            XCTFail("Disabling window management should allow the matching Space action")
        }

        config.apps[0].shortcut = shortcut
        if case .app(let app)? = config.action(for: shortcut) {
            XCTAssertEqual(app.id, config.apps[0].id)
        } else {
            XCTFail("Apps should remain available when window management is disabled")
        }
    }

    func testShortcutRoutePrefersLayoutsThenAppsThenSpaces() {
        var config = CrispConfig.initial
        config.instantSpaces = true
        let appShortcut = config.apps[0].shortcut
        let spaceShortcut = Shortcut(modifiers: Shortcut.control, key: 124)
        config.layouts[1].shortcut = appShortcut
        if case .layout? = config.action(for: appShortcut) {} else { XCTFail("Layout must win over app") }
        config.layouts[1].enabled = false
        if case .app(let app)? = config.action(for: appShortcut) {
            XCTAssertEqual(app.id, config.apps[0].id)
        } else { XCTFail("App must win when matching layout is disabled") }
        config.apps[0].shortcut = spaceShortcut
        if case .app? = config.action(for: spaceShortcut) {} else { XCTFail("App must win over Spaces") }
        config.layouts[2].shortcut = spaceShortcut
        if case .layout? = config.action(for: spaceShortcut) {} else { XCTFail("Layout must win over Spaces") }
        config.layouts[2].enabled = false
        if case .app? = config.action(for: spaceShortcut) {} else { XCTFail("App must win over Spaces without a layout") }
        config.apps[0].enabled = false
        if case .space(.next)? = config.action(for: spaceShortcut) {} else { XCTFail("Spaces must work without a collision") }
        config.instantSpaces = false
        XCTAssertNil(config.action(for: spaceShortcut))
    }

    func testShortcutResolverMatchesConfigRouteForEveryShortcut() {
        var config = CrispConfig.initial
        config.instantSpaces = true
        config.layouts[3].shortcut = config.apps[2].shortcut // deliberate collision
        let resolver = ShortcutResolver(config)
        let candidates = config.layouts.map(\.shortcut) + config.apps.map(\.shortcut)
            + [Shortcut(modifiers: Shortcut.control, key: 123), Shortcut(modifiers: Shortcut.control, key: 124),
               Shortcut(modifiers: Shortcut.hyper, key: 999)]
        for shortcut in candidates {
            switch (config.action(for: shortcut), resolver[shortcut]) {
            case (nil, nil):
                continue
            case (.layout, .layout?):
                break
            case (.app(let left), .app(let right)):
                XCTAssertEqual(left.id, right.id)
            case (.space(let left), .space(let right)):
                XCTAssertEqual(left, right)
            case (.layout, nil), (.app, nil), (.space, nil):
                XCTFail("Resolver lost a route")
            default:
                XCTFail("Resolver disagrees with the config route for \(shortcut.label)")
            }
        }
    }

    func testShortcutResolverRebuildPicksUpConfigChanges() {
        let shortcut = Shortcut(modifiers: Shortcut.hyper, key: 51)
        var config = CrispConfig.initial
        for index in config.layouts.indices { config.layouts[index].enabled = false }
        XCTAssertNil(ShortcutResolver(config)[shortcut])
        config.layouts[6].enabled = true
        config.layouts[6].shortcut = shortcut
        if case .layout? = ShortcutResolver(config)[shortcut] {} else {
            XCTFail("Rebuilt resolver must expose the newly enabled layout")
        }
    }

    func testArbitraryNumberOfLayoutsCycleInCurrentListOrder() {
        let shortcut = Shortcut(modifiers: Shortcut.hyper, key: 124)
        var layouts = (0..<5).map { index in
            Layout(name: "Layout \(index)", x: 0, y: 0, width: 0.5, height: 1,
                   shortcut: shortcut)
        }
        var cycle = LayoutCycle()
        for index in 0..<11 {
            let layout = cycle.next(in: layouts, for: shortcut, sameWindow: true)
            XCTAssertEqual(layout?.name, "Layout \(index % 5)")
            cycle.didApply(layout!, for: shortcut)
        }
        layouts.swapAt(1, 4)
        cycle.reset() // Config changes reset the active cycle.
        let names = ["Layout 0", "Layout 4", "Layout 2", "Layout 3", "Layout 1", "Layout 0"]
        for name in names {
            let layout = cycle.next(in: layouts, for: shortcut, sameWindow: true)
            XCTAssertEqual(layout?.name, name)
            cycle.didApply(layout!, for: shortcut)
        }
    }

    func testResolverLayoutListsArePreFilteredPerShortcutAndDisplay() {
        let shortcut = Shortcut(modifiers: Shortcut.hyper, key: 124)
        var config = CrispConfig.initial
        config.layouts[1].availableScreens = [.macBook]             // Right Half: this display only
        config.layouts[2].availableScreens = [.macBook]             // Right Third: this display only
        config.layouts[3].shortcut = shortcut                       // Top Half joins the group
        config.layouts[3].availableScreens = [.vertical]            // but not on this display
        let resolver = ShortcutResolver(config)
        let macBook = resolver.layouts(for: shortcut, screen: .macBook)
        XCTAssertEqual(macBook.map(\.name), ["Right Half", "Right Third"])
        XCTAssertEqual(resolver.layouts(for: shortcut, screen: .vertical).map(\.name), ["Top Half"])
        XCTAssertTrue(resolver.layouts(for: Shortcut(modifiers: Shortcut.hyper, key: 999), screen: .macBook).isEmpty)
    }

    func testRecordedShortcutPreservesPhysicalKeycodeAndIgnoresNonModifierFlags() {
        let flags = CGEventFlags(rawValue: Shortcut.hyper | CGEventFlags.maskNumericPad.rawValue)
        XCTAssertEqual(Shortcut.recorded(keyCode: 124, flags: flags),
                       Shortcut(modifiers: Shortcut.hyper, key: 124))
        XCTAssertEqual(Shortcut.recorded(keyCode: 123, flags: [.maskControl]),
                       Shortcut(modifiers: Shortcut.control, key: 123))
    }

    func testExistingConfigAddsRightThirdAndUpdatesOnlyDefaultCenter() {
        var old = CrispConfig.initial
        old.layouts.remove(at: 2)
        old.layouts[1].shortcut = Shortcut(modifiers: Shortcut.hyper, key: 30)
        let center = old.layouts.firstIndex(where: { $0.name == "Centered" })!
        old.layouts[center].shortcut = Shortcut(modifiers: Shortcut.hyper, key: 8)
        let migrated = old.upgradingLayouts()
        XCTAssertEqual(migrated.layouts[2].name, "Right Third")
        XCTAssertEqual(migrated.layouts[2].shortcut, old.layouts[1].shortcut)
        XCTAssertEqual(migrated.layouts[1], old.layouts[1])
        XCTAssertEqual(migrated.layouts.first(where: { $0.name == "Centered" })?.shortcut.key, 51)
        XCTAssertEqual(migrated.upgradingLayouts().layouts, migrated.layouts)
    }

    func testUpgradePreservesCustomCenterAndConflictingDelete() {
        var old = CrispConfig.initial
        old.layouts.remove(at: 2)
        let center = old.layouts.firstIndex(where: { $0.name == "Centered" })!
        old.layouts[center].shortcut = Shortcut(modifiers: Shortcut.hyper, key: 39)
        XCTAssertEqual(old.upgradingLayouts().layouts.first(where: { $0.name == "Centered" })?.shortcut.key, 39)
        old.layouts[center].shortcut = Shortcut(modifiers: Shortcut.hyper, key: 8)
        old.apps[0].shortcut = Shortcut(modifiers: Shortcut.hyper, key: 51)
        XCTAssertEqual(old.upgradingLayouts().layouts.first(where: { $0.name == "Centered" })?.shortcut.key, 8)
    }

    @MainActor
    func testAssigningAShortcutAfterTheRowIsGoneChangesNothing() throws {
        let controller = CrispController()
        var config = controller.config
        config.apps.append(AppBinding(name: "Doomed", bundleID: "com.example.doomed",
                                      shortcut: Shortcut(modifiers: Shortcut.option, key: 0), enabled: false))
        controller.update(config)
        let doomed = try XCTUnwrap(config.apps.last?.id)

        // The row disappears (user pressed the minus button mid-recording)…
        var afterRemoval = controller.config
        afterRemoval.apps.removeAll { $0.id == doomed }
        controller.update(afterRemoval)
        // …and the pending keystroke arrives afterwards.
        controller.assignShortcut(Shortcut(modifiers: Shortcut.hyper, key: 42), to: doomed, kind: .app)
        XCTAssertEqual(controller.config.apps.count, afterRemoval.apps.count)
        XCTAssertTrue(controller.config.apps.allSatisfy { $0.shortcut != Shortcut(modifiers: Shortcut.hyper, key: 42) })
    }

    @MainActor
    func testAssigningAShortcutUpdatesTheMatchingRowOnly() {
        let controller = CrispController()
        let untouched = controller.config.apps.dropFirst().map(\.shortcut)
        let target = controller.config.apps[0].id
        controller.assignShortcut(Shortcut(modifiers: Shortcut.hyper, key: 42), to: target, kind: .app)
        XCTAssertEqual(controller.config.apps[0].shortcut, Shortcut(modifiers: Shortcut.hyper, key: 42))
        XCTAssertEqual(controller.config.apps.dropFirst().map(\.shortcut), untouched)
    }

    func testMenuBarIconDefaultsToSupraAndSurvivesOldConfigs() throws {
        XCTAssertEqual(CrispConfig.initial.menuBarIcon, .supra)
        var config = CrispConfig.initial
        config.menuBarIcon = .rabbit
        let restored = try JSONDecoder().decode(CrispConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.menuBarIcon, .rabbit)

        // A config saved before the icon option existed must still decode.
        let legacy = """
        {"apps":[],"layouts":[],"hyperSource":"off","instantSpaces":false}
        """
        let decoded = try JSONDecoder().decode(CrispConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.menuBarIcon, .supra)
        XCTAssertNil(decoded.validationError)
    }

    func testConfigRoundTrip() throws {
        let original = CrispConfig.initial
        let result = try JSONDecoder().decode(CrispConfig.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(result.apps, original.apps)
        XCTAssertEqual(result.layouts, original.layouts)
        XCTAssertTrue(result.windowManagementEnabled)
    }

    func testOlderConfigDefaultsWindowManagementToEnabled() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(CrispConfig.initial)) as? [String: Any]
        )
        object.removeValue(forKey: "windowManagementEnabled")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CrispConfig.self, from: data)
        XCTAssertTrue(decoded.windowManagementEnabled)
        XCTAssertEqual(decoded.layouts, CrispConfig.initial.layouts)
    }

    func testConfigIgnoresRetiredFastCmdTabSetting() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(CrispConfig.initial)) as? [String: Any]
        )
        object["followAppActivation"] = true
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(CrispConfig.self, from: legacyData)
        let savedAgain = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        )

        XCTAssertEqual(decoded.apps, CrispConfig.initial.apps)
        XCTAssertNil(savedAgain["followAppActivation"])
    }

    func testOldLayoutsWithoutScreenSizesRemainAvailableEverywhere() throws {
        let old = """
        {"id":"5F8FFCCC-15DF-4AB5-B56C-F3A5C77C0F54","name":"Left",\
        "x":0,"y":0,"width":0.5,"height":1,"enabled":true,\
        "shortcut":{"modifiers":524288,"key":123}}
        """
        let layout = try JSONDecoder().decode(Layout.self, from: Data(old.utf8))
        XCTAssertEqual(layout.availableScreens, Set(ScreenSize.allCases))
        XCTAssertTrue(layout.isValid)
    }

    func testSpacePayloadLengthsAndPhase() {
        let begin = SpaceGesture.payload(phase: .began, sign: 1, timestamp: 123)
        let end = SpaceGesture.payload(phase: .ended, sign: -1, timestamp: 123)
        XCTAssertEqual(begin.count, 68)
        XCTAssertEqual(end.count, 96)
        XCTAssertEqual(begin[24], 1)
        XCTAssertEqual(end[24], 2)
        XCTAssertEqual(begin[39], 1) // phase is the high byte of options at offsets 36–39
        XCTAssertEqual(end[39], 4)
        XCTAssertEqual(begin[64], 1) // began uses one 16.16 unit of progress
        XCTAssertEqual(end[64], 0) // -1.0 is encoded at offsets 64–67
        XCTAssertEqual(end[67], 255)
        XCTAssertEqual(end[88], 0) // terminal Y velocity is zero
        let changed = SpaceGesture.payload(phase: .changed, sign: 1, timestamp: 123)
        XCTAssertEqual(changed.count, 68)
        XCTAssertEqual(changed[39], 2)
        XCTAssertEqual(changed[66], 1) // +1.0 progress is 0x00010000
        XCTAssertEqual(SpaceGesture.progress(phase: .began, sign: -1), -SpaceGesture.epsilon)
        XCTAssertEqual(SpaceGesture.progress(phase: .ended, sign: -1), -1)
    }

    func testAugmentedEventCanBeConstructed() throws {
        let base = try XCTUnwrap(CGEvent(source: nil))
        let payload = SpaceGesture.payload(phase: .ended, sign: 1, timestamp: 123)
        let augmented = try XCTUnwrap(SpaceGesture.augment(base, payload: payload))
        XCTAssertNotNil(augmented.__data(allocator: nil))
        // CGEventCreateData need not preserve private field 4205 when reserializing.
        // Posting to Dock still needs a physical, permission-granted test.
    }

    func testSpaceBoundaryBlocksMissingAdjacentSpaces() {
        let spaces: [UInt64] = [10, 20, 30]
        XCTAssertEqual(SpaceBoundary.canMove(spaceIDs: spaces, activeSpaceID: 10, direction: .previous), false)
        XCTAssertEqual(SpaceBoundary.canMove(spaceIDs: spaces, activeSpaceID: 10, direction: .next), true)
        XCTAssertEqual(SpaceBoundary.canMove(spaceIDs: spaces, activeSpaceID: 20, direction: .previous), true)
        XCTAssertEqual(SpaceBoundary.canMove(spaceIDs: spaces, activeSpaceID: 20, direction: .next), true)
        XCTAssertEqual(SpaceBoundary.canMove(spaceIDs: spaces, activeSpaceID: 30, direction: .previous), true)
        XCTAssertEqual(SpaceBoundary.canMove(spaceIDs: spaces, activeSpaceID: 30, direction: .next), false)
    }

    func testSpaceBoundaryFailsClosedForAmbiguousDisplays() {
        XCTAssertNil(SpaceBoundary.canMove(spaceLists: [], activeSpaceID: 10, direction: .next))
        XCTAssertNil(SpaceBoundary.canMove(spaceLists: [[10, 20], [10, 20, 30]], activeSpaceID: 10, direction: .next))
        XCTAssertEqual(SpaceBoundary.canMove(spaceLists: [[10, 20], [10, 20]], activeSpaceID: 10, direction: .next), true)
    }

    func testSpaceBoundaryFailsClosedForInvalidSpaceState() {
        XCTAssertNil(SpaceBoundary.canMove(spaceIDs: [], activeSpaceID: 10, direction: .next))
        XCTAssertNil(SpaceBoundary.canMove(spaceIDs: [10], activeSpaceID: 20, direction: .next))
        XCTAssertNil(SpaceBoundary.canMove(spaceIDs: [10, 10], activeSpaceID: 10, direction: .next))
        XCTAssertEqual(SpaceBoundary.canMove(spaceIDs: [10], activeSpaceID: 10, direction: .previous), false)
        XCTAssertEqual(SpaceBoundary.canMove(spaceIDs: [10], activeSpaceID: 10, direction: .next), false)
    }

    func testSpaceDirectionWithNaturalScrolling() {
        XCTAssertEqual(SpaceGesture.sign(direction: .next, augmented: true, naturalScrolling: true), -1)
        XCTAssertEqual(SpaceGesture.sign(direction: .previous, augmented: true, naturalScrolling: true), 1)
        XCTAssertEqual(SpaceGesture.sign(direction: .next, augmented: true, naturalScrolling: false), 1)
        XCTAssertEqual(SpaceGesture.sign(direction: .previous, augmented: true, naturalScrolling: false), -1)
        XCTAssertEqual(SpaceGesture.sign(direction: .next, augmented: false, naturalScrolling: true), 1)
    }

    func testSpacePayloadFixedPointNonzero() {
        XCTAssertEqual(SpaceGesture.fixed(0.000016), 1)
        XCTAssertEqual(SpaceGesture.fixed(-0.000016), -1)
        XCTAssertEqual(SpaceGesture.fixed(.nan), 0)
        XCTAssertEqual(SpaceGesture.fixed(.infinity), 0)
    }
}
