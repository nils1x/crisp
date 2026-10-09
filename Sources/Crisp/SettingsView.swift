import AppKit
import ServiceManagement
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case apps, windows, spaces, hyper

    var id: String { rawValue }
    var title: String {
        switch self {
        case .apps: "Apps"
        case .windows: "Windows"
        case .spaces: "Spaces"
        case .hyper: "Hyper Key"
        }
    }
    var symbol: String {
        switch self {
        case .apps: "app.badge"
        case .windows: "rectangle.split.2x1"
        case .spaces: "square.stack.3d.up"
        case .hyper: "capslock"
        }
    }
    /// ⌘1…⌘4 in sidebar order.
    var ordinal: Int { (SettingsSection.allCases.firstIndex(of: self) ?? 0) + 1 }
}

/// Menu bar glyph. The supra is extracted from the app icon by
/// `scripts/extract-menubar-icon.py` and shipped as a template image; the rabbit is the
/// SF Symbol Crisp started with, kept so the change can be reverted from the menu.
/// Which list a recorded shortcut belongs to.
enum BindingTarget: Sendable { case app, layout }

enum MenuBarIcon: String, Codable, CaseIterable {
    case supra, rabbit

    var title: String {
        switch self {
        case .supra: "Supra"
        case .rabbit: "Rabbit"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selection: SettingsSection? = .apps
}

struct SettingsView: View {
    @ObservedObject var controller: CrispController
    @ObservedObject var navigation: SettingsNavigation
    @State private var selectedApp: UUID?
    @State private var selectedLayout: UUID?
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var dimensionDrafts: [UUID: LayoutDimensions] = [:]
    @State private var dimensionTextDrafts: [String: String] = [:]
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selection) {
                Section("Shortcuts") {
                    ForEach(filteredSections) { section in
                        Label(section.title, systemImage: section.symbol)
                            .tag(section)
                            .keyboardShortcut(KeyEquivalent(Character("\(section.ordinal)")), modifiers: .command)
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search settings")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                switch navigation.selection ?? .apps {
                case .apps: appsTab
                case .windows: windowsTab
                case .spaces: spacesTab
                case .hyper: hyperTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 940, minHeight: 620)
        .alert("Crisp", isPresented: Binding(get: { controller.error != nil }, set: { if !$0 { controller.error = nil } })) {
            Button("OK") { controller.error = nil }
        } message: { Text(controller.error ?? "") }
    }

    private var filteredSections: [SettingsSection] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var appsTab: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedApp) {
                    ForEach(controller.config.apps) { app in
                        HStack(spacing: 8) {
                            Text(app.name).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(app.shortcut.label)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .tag(app.id)
                    }
                }
                .listStyle(.inset)
                Divider()
                HStack(spacing: 8) {
                    iconButton("plus", "Add app", action: addApp)
                    iconButton("minus", "Remove app", action: removeApp)
                        .disabled(selectedApp == nil)
                    Spacer()
                    Text("\(controller.config.apps.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
            }
            .frame(width: 250)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    pageHeader("Apps", detail: "Launch or focus apps with a shortcut.")
                    if let app = controller.config.apps.first(where: { $0.id == selectedApp }) {
                        let id = app.id
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                LabeledContent("Name") {
                                    TextField("Name", text: appField(id, \.name, fallback: app.name))
                                        .labelsHidden()
                                        .multilineTextAlignment(.trailing)
                                }
                                LabeledContent("Bundle ID") {
                                    TextField("Bundle ID", text: appField(id, \.bundleID, fallback: app.bundleID))
                                        .labelsHidden()
                                        .multilineTextAlignment(.trailing)
                                }
                                LabeledContent {
                                    Button("Choose Application…") { selectApplication(id: id) }
                                } label: {
                                    Text("Application")
                                }
                            }
                            .padding(.vertical, 4)
                        } label: {
                            Label("Application", systemImage: "app")
                        }

                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("Enabled", isOn: appField(id, \.enabled, fallback: app.enabled))
                                ShortcutEditor(shortcut: app.shortcut,
                                                controller: controller, id: id, kind: .app)
                            }
                            .padding(.vertical, 4)
                        } label: {
                            Label("Shortcut", systemImage: "keyboard")
                        }
                    } else {
                        ContentUnavailableView("Select an app", systemImage: "app.badge",
                                               description: Text("Pick an app on the left to edit its binding."))
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var spacesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader("Spaces", detail: "Switch between native macOS desktops.")
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Fast Space Switching", isOn: configField(\.instantSpaces))
                            .toggleStyle(.switch)
                        LabeledContent("Shortcut") {
                            Text("⌃ ← / ⌃ →")
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text("Switches to the adjacent Space. Trackpad gestures stay with macOS.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Instant switching", systemImage: "square.stack.3d.up")
                }
                Label("Uses a synthetic Dock gesture. The undocumented format may change with a macOS update.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var hyperTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader("Hyper Key", detail: "Turn one key into ⌃⌥⇧⌘ for shortcuts.")
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Source key", selection: configField(\.hyperSource)) {
                            ForEach(HyperSource.allCases) { source in Text(source.label).tag(source) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                        Text("Hold the source key for ⌃⌥⇧⌘. A quick tap does nothing.")
                            .font(.callout).foregroundStyle(.secondary)
                        if controller.config.hyperSource == .capsLock {
                            Text("Crisp maps Caps Lock to F18 on connected keyboards and checks new ones. An existing Caps Lock→F18 mapping is reused; a different remap is left untouched. Test your keyboard's lock light after enabling.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else if controller.config.hyperSource != .off {
                            Text("Choose F18/F19/F20 only if the key is available on your keyboard or already remapped. Crisp won't reconfigure those keys.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Hyper source", systemImage: "capslock")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(controller.keyboardReady ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(controller.keyboardReady ? "Keyboard monitoring active"
                                                          : "Keyboard monitoring needs Accessibility and Input Monitoring")
                            Spacer()
                            Button("Request Permissions…") { controller.requestPermission() }
                        }
                        Divider()
                        Toggle("Launch Crisp at login", isOn: Binding(
                            get: { loginEnabled },
                            set: { enabled in
                                do {
                                    if enabled { try SMAppService.mainApp.register() }
                                    else { try SMAppService.mainApp.unregister() }
                                    loginEnabled = SMAppService.mainApp.status == .enabled
                                } catch { controller.error = error.localizedDescription }
                            }))
                        Text("Only Crisp needs to run. Turn off other shortcut/Hyper/Space tools after testing Crisp.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } label: {
                    Label("Permissions and startup", systemImage: "lock.shield")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var windowsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                pageHeader("Windows", detail: "Arrange the focused window with saved layouts.")
                Spacer()
                Toggle("Window management", isOn: configField(\.windowManagementEnabled))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Text("Press the same shortcut again to cycle layouts on the focused window.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            Divider().padding(.vertical, 12)

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selectedLayout) {
                        ForEach(controller.config.layouts) { layout in
                            HStack(spacing: 8) {
                                Text(layout.name).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(layout.shortcut.label)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .tag(layout.id)
                        }
                    }
                    .listStyle(.inset)
                    Divider()
                    HStack(spacing: 8) {
                        iconButton("plus", "Add layout", action: addLayout)
                        iconButton("minus", "Remove layout", action: removeLayout)
                            .disabled(selectedLayout == nil)
                        Spacer()
                        iconButton("arrow.up", "Move layout up") { moveLayout(by: -1) }
                            .disabled(!canMoveLayout(by: -1))
                        iconButton("arrow.down", "Move layout down") { moveLayout(by: 1) }
                            .disabled(!canMoveLayout(by: 1))
                    }
                    .padding(10)
                }
                .frame(width: 250)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let layout = controller.config.layouts.first(where: { $0.id == selectedLayout }) {
                            let id = layout.id
                            let draftLayout = (dimensionDrafts[id] ?? LayoutDimensions(layout)).applying(to: layout)

                            LayoutPreview(layout: draftLayout)
                                .frame(height: 170)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            GroupBox {
                                VStack(alignment: .leading, spacing: 12) {
                                    Toggle("Enabled", isOn: layoutField(id, \.enabled, fallback: layout.enabled))
                                    Divider()
                                    LabeledContent("Name") {
                                        TextField("Layout name", text: layoutField(id, \.name, fallback: layout.name))
                                            .labelsHidden()
                                            .multilineTextAlignment(.trailing)
                                    }
                                    ShortcutEditor(shortcut: layout.shortcut,
                                                   controller: controller, id: id, kind: .layout)
                                }
                                .padding(.vertical, 4)
                            } label: {
                                Label("Layout", systemImage: "rectangle.split.2x1")
                            }

                            GroupBox {
                                VStack(alignment: .leading, spacing: 12) {
                                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                                        GridRow { dimensionField("X", id, .x); dimensionField("Y", id, .y) }
                                        GridRow { dimensionField("Width", id, .width); dimensionField("Height", id, .height) }
                                    }
                                    Text("Values from 0 to 1, measured from the screen's top-left.")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !draftLayout.isValid {
                                        Text("Doesn't fit the display yet. Adjust X/Y or width/height until the whole rectangle is inside the screen.")
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                .padding(.vertical, 4)
                            } label: {
                                Label("Position and size", systemImage: "arrow.up.left.and.arrow.down.right")
                            }

                            GroupBox {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(ScreenSize.allCases) { size in
                                        Toggle(size.label, isOn: screenSizeField(id, size))
                                    }
                                }
                                .padding(.vertical, 4)
                            } label: {
                                Label("Available on screen sizes", systemImage: "display")
                            }
                        } else {
                            ContentUnavailableView("Select a layout", systemImage: "rectangle.dashed",
                                                   description: Text("Pick a layout on the left, or add one."))
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func pageHeader(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(.title2, design: .rounded).weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Compact square icon button for list toolbars; the label doubles as tooltip and
    /// accessibility name so the toolbar stays clean.
    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(label)
        .accessibilityLabel(label)
    }

    /// Geometry cell with the label above the field, for the two-column grid.
    private func dimensionField(_ label: String, _ id: UUID, _ dimension: LayoutDimension) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            numericField(label, id, dimension)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numericField(_ label: String, _ id: UUID, _ dimension: LayoutDimension) -> some View {
        let key = "\(id.uuidString):\(dimension)"
        return TextField(label, text: Binding(
            get: {
                // The row may already be gone: a removed layout reads as 0, never traps.
                let current = controller.config.layouts.first { $0.id == id }.map { LayoutDimensions($0) }
                let value = (dimensionDrafts[id] ?? current)?[dimension] ?? 0
                return dimensionTextDrafts[key] ?? formattedDimension(value)
            },
            set: { text in
                dimensionTextDrafts[key] = text
                guard let value = LayoutDimensions.parseValue(text),
                      let index = controller.config.layouts.firstIndex(where: { $0.id == id }) else { return }
                var updated = dimensionDrafts[id] ?? LayoutDimensions(controller.config.layouts[index])
                updated[dimension] = value
                dimensionDrafts[id] = updated
                let candidate = updated.applying(to: controller.config.layouts[index])
                guard candidate.isValid else { return }
                var config = controller.config
                config.layouts[index] = candidate
                controller.update(config)
                dimensionDrafts[id] = LayoutDimensions(candidate)
            }))
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .onSubmit { commitDimensionText(key, id: id, dimension: dimension) }
    }

    private func formattedDimension(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)))
    }

    private func commitDimensionText(_ key: String, id: UUID, dimension: LayoutDimension) {
        guard let text = dimensionTextDrafts[key] else { return }
        guard let index = controller.config.layouts.firstIndex(where: { $0.id == id }) else {
            dimensionTextDrafts.removeValue(forKey: key)
            return
        }
        guard let value = LayoutDimensions.parseValue(text) else {
            dimensionTextDrafts.removeValue(forKey: key)
            if dimensionDrafts[id] == nil {
                dimensionDrafts[id] = LayoutDimensions(controller.config.layouts[index])
            }
            return
        }

        var updated = dimensionDrafts[id] ?? LayoutDimensions(controller.config.layouts[index])
        updated[dimension] = value
        let candidate = updated.applying(to: controller.config.layouts[index])
        if candidate.isValid {
            var config = controller.config
            config.layouts[index] = candidate
            controller.update(config)
            dimensionDrafts[id] = LayoutDimensions(candidate)
        } else {
            // Keep valid partial geometry edits visible without saving an invalid layout.
            dimensionDrafts[id] = updated
        }
        dimensionTextDrafts.removeValue(forKey: key)
    }

    private func screenSizeField(_ id: UUID, _ size: ScreenSize) -> Binding<Bool> {
        Binding(get: {
            controller.config.layouts.first { $0.id == id }?.availableScreens.contains(size) ?? false
        }, set: { selected in
            var config = controller.config
            guard let index = config.layouts.firstIndex(where: { $0.id == id }) else { return }
            if selected { config.layouts[index].availableScreens.insert(size) }
            else { config.layouts[index].availableScreens.remove(size) }
            guard !config.layouts[index].availableScreens.isEmpty else { return }
            controller.update(config)
        })
    }

    private func configField<T>(_ key: WritableKeyPath<CrispConfig, T>) -> Binding<T> {
        Binding(get: { controller.config[keyPath: key] }, set: { value in
            var config = controller.config
            config[keyPath: key] = value
            controller.update(config)
        })
    }
    /// Bindings resolve the row by id on **every** read and write. Capturing an index is
    /// fatal: SwiftUI can evaluate a binding from the previous frame during the layout
    /// pass that follows the removal, and `apps[index]` traps on the shortened array.
    private func appField<T>(_ id: UUID, _ key: WritableKeyPath<AppBinding, T>,
                              fallback: T) -> Binding<T> {
        Binding(get: {
            controller.config.apps.first { $0.id == id }?[keyPath: key] ?? fallback
        }, set: { value in
            var config = controller.config
            guard let index = config.apps.firstIndex(where: { $0.id == id }) else { return }
            config.apps[index][keyPath: key] = value
            controller.update(config)
        })
    }
    private func layoutField<T>(_ id: UUID, _ key: WritableKeyPath<Layout, T>,
                                fallback: T) -> Binding<T> {
        Binding(get: {
            controller.config.layouts.first { $0.id == id }?[keyPath: key] ?? fallback
        }, set: { value in
            var config = controller.config
            guard let index = config.layouts.firstIndex(where: { $0.id == id }) else { return }
            config.layouts[index][keyPath: key] = value
            controller.update(config)
        })
    }

    private func addApp() {
        var config = controller.config
        let item = AppBinding(name: "New App", bundleID: "", shortcut: Shortcut(modifiers: Shortcut.option, key: 0), enabled: false)
        config.apps.append(item)
        controller.update(config)
        selectedApp = item.id
    }
    private func removeApp() {
        guard let removedApp = selectedApp else { return }
        // Deselect and stop recording before shrinking the array: a selection or record
        // callback still pointing at the removed row crashes SwiftUI's AppKit List bridge.
        selectedApp = nil
        controller.cancelRecording(id: removedApp)
        var config = controller.config
        config.apps.removeAll { $0.id == removedApp }
        controller.update(config)
    }
    private func addLayout() {
        var config = controller.config
        let item = Layout(name: "New Layout", x: 0.25, y: 0.25, width: 0.5, height: 0.5,
                          shortcut: Shortcut(modifiers: Shortcut.hyper, key: 0), enabled: false)
        config.layouts.append(item)
        controller.update(config)
        selectedLayout = item.id
    }
    private func removeLayout() {
        guard let removedLayout = selectedLayout else { return }
        // Same ordering as removeApp: selection cleared before the list shrinks.
        selectedLayout = nil
        controller.cancelRecording(id: removedLayout)
        var config = controller.config
        config.layouts.removeAll { $0.id == removedLayout }
        controller.update(config)
    }
    private func canMoveLayout(by offset: Int) -> Bool {
        guard let index = controller.config.layouts.firstIndex(where: { $0.id == selectedLayout }) else { return false }
        return controller.config.layouts.indices.contains(index + offset)
    }
    private func moveLayout(by offset: Int) {
        guard canMoveLayout(by: offset),
              let index = controller.config.layouts.firstIndex(where: { $0.id == selectedLayout }) else { return }
        var config = controller.config
        config.layouts.swapAt(index, index + offset)
        controller.update(config)
    }
    private func selectApplication(id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsOtherFileTypes = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url,
           let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier {
            var config = controller.config
            guard let index = config.apps.firstIndex(where: { $0.id == id }) else { return }
            config.apps[index].bundleID = bundleID
            config.apps[index].name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
            controller.update(config)
        }
    }
}

private struct ShortcutEditor: View {
    let shortcut: Shortcut
    @ObservedObject var controller: CrispController
    let id: UUID
    let kind: BindingTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ShortcutRecordField(shortcut: shortcut, controller: controller, id: id, kind: kind)
                .frame(height: 22)
            Text("Click the field, then press a key with modifiers (e.g. Hyper + Delete). Esc cancels.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ShortcutRecordField: NSViewRepresentable {
    let shortcut: Shortcut
    @ObservedObject var controller: CrispController
    let id: UUID
    let kind: BindingTarget

    func makeNSView(context: Context) -> RecordingTextField {
        let field = RecordingTextField()
        field.isEditable = false
        field.isSelectable = false
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.alignment = .right
        field.focusRingType = .exterior
        field.toolTip = "Click to record a keyboard shortcut"
        return field
    }

    func updateNSView(_ field: RecordingTextField, context: Context) {
        field.stringValue = controller.recordingID == id ? "Press shortcut…" : shortcut.label
        // The recorder writes through the controller by id. It must never capture the
        // row's Binding: that closure outlives the view and could outlive the row,
        // which is how removing a row while recording used to kill the app.
        field.onFocus = { [controller, id, kind] in
            controller.beginRecording(id: id) { controller.assignShortcut($0, to: id, kind: kind) }
        }
        field.onBlur = { [controller, id] in controller.cancelRecording(id: id) }
    }

    static func dismantleNSView(_ field: RecordingTextField, coordinator: ()) {
        field.onBlur?()
        field.onFocus = nil
        field.onBlur = nil
    }
}

private final class RecordingTextField: NSTextField {
    var onFocus: (() -> Void)?
    var onBlur: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if window?.makeFirstResponder(self) == true {
            onFocus?() // Clicking again restarts capture after Esc.
        }
    }

    override func resignFirstResponder() -> Bool {
        onBlur?()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        // The app's HID event tap handles recording before keys reach this field.
    }
}

private struct LayoutPreview: View {
    let layout: Layout

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .underPageBackgroundColor))
                Canvas { context, size in
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height / 2))
                    path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    path.move(to: CGPoint(x: size.width / 2, y: 0))
                    path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                    context.stroke(path, with: .color(.primary.opacity(0.08)), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                if layout.isValid {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.35))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.5)
                        )
                        .frame(width: max(2, width * layout.width), height: max(2, height * layout.height))
                        .offset(x: width * layout.x, y: height * layout.y)
                        .animation(.snappy(duration: 0.12), value: layout)
                } else {
                    Label("Doesn't fit the display", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
    }
}
