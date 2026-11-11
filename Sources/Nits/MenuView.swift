import CoreGraphics
import ServiceManagement
import SwiftUI

struct MenuView: View {
    @ObservedObject var manager: DisplayManager
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Names of collapsed display cards, comma separated (names survive replugs; display IDs may not).
    @AppStorage("collapsedDisplays") private var collapsedRaw = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if manager.layoutBroken { layoutWarning }
            presetsSection

            ForEach(manager.displays) { display in
                DisplayCard(
                    display: display,
                    canTurnOff: DisplayPower.isAvailable && manager.displays.count > 1,
                    collapsed: collapsedBinding(display.name),
                    turnOff: { manager.turnOff(display) }
                )
                // A preset is mid-way through several steps; manual changes now would fight it.
                .disabled(manager.isApplyingPreset)
            }

            if !manager.offDisplays.isEmpty { offDisplays }

            footer
        }
        .padding(12)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.orange.gradient))
            VStack(alignment: .leading, spacing: 0) {
                Text("Nits").font(.system(size: 13, weight: .semibold))
                Text(displayCountText).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            IconButton(systemImage: "arrow.clockwise", help: "Re-detect displays") { manager.refresh() }
                .disabled(manager.isApplyingPreset)
        }
        .padding(.horizontal, 2)
    }

    private var layoutWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow.motionlines").foregroundStyle(.orange)
            Text("Some screens don't share an edge, so the cursor can't move between them.")
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Fix") { manager.repairArrangement() }
                .disabled(manager.isApplyingPreset)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .help("Moves the stranded screens the shortest distance so they touch the main screen's group.")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.orange.opacity(0.12)))
    }

    // MARK: Presets

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("Presets")
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                if manager.isApplyingPreset {
                    ProgressView().controlSize(.mini)
                    Text("Applying…").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                IconButton(systemImage: "plus", help: "Save the current setup as a preset") {
                    if let name = NamePrompt.ask(title: "Save current setup", message: "Saves each screen's resolution, refresh rate, rotation, arrangement, brightness and whether it's on.",
                                                 defaultName: suggestedPresetName) {
                        manager.savePreset(named: name)
                    }
                }
                .disabled(manager.isApplyingPreset)
            }
            if manager.presets.isEmpty {
                Text("Set your screens up the way you like, then press + to switch back to it in one click.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                    ForEach(manager.presets) { preset in
                        Chip(title: preset.name, selected: preset.id == manager.activePresetID,
                             warning: !manager.connectedNotIn(preset).isEmpty) {
                            manager.apply(preset)
                        }
                        .disabled(manager.isApplyingPreset)
                        .help(presetSummary(preset) + "\nRight-click to update, rename or delete.")
                        .contextMenu {
                            Button("Update to Current Setup", systemImage: "arrow.triangle.2.circlepath") { manager.updatePreset(preset) }
                            Button("Rename…", systemImage: "pencil") {
                                if let name = NamePrompt.ask(title: "Rename preset", message: nil, defaultName: preset.name) {
                                    manager.renamePreset(preset, to: name)
                                }
                            }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) { manager.deletePreset(preset) }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(CardBackground())
    }

    private var suggestedPresetName: String {
        let taken = Set(manager.presets.map(\.name))
        return ["Desk", "Gaming", "Laptop only", "Focus", "Presentation"].first { !taken.contains($0) }
            ?? "Preset \(manager.presets.count + 1)"
    }

    /// Tooltip: "G27U 1920×1080 160 Hz · Built-in off".
    private func presetSummary(_ preset: Preset) -> String {
        var lines = preset.displays.values.sorted { $0.name < $1.name }.map { state in
            guard state.enabled else { return "\(state.name): off" }
            let size = state.width.map { "\($0)×\(state.height ?? 0)" } ?? ""
            let hz = state.refreshRate.map { " \($0) Hz" } ?? ""
            return "\(state.name): \(size)\(hz)\(state.isMain ? " (main)" : "")"
        }
        let missing = manager.connectedNotIn(preset)
        if !missing.isEmpty {
            lines.append("Not in this preset (left as they are): " + missing.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    private var displayCountText: String {
        let n = manager.displays.count
        let off = manager.offDisplays.count
        return "\(n) display\(n == 1 ? "" : "s")" + (off > 0 ? " · \(off) off" : "")
    }

    private var offDisplays: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(manager.offDisplays) { display in
                HStack(spacing: 8) {
                    Image(systemName: CGDisplayIsBuiltin(display.id) != 0 ? "laptopcomputer" : "display")
                        .foregroundStyle(.tertiary)
                        .frame(width: 22)
                    Text(display.name).font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Badge(text: "Off")
                    Spacer()
                    Button("Turn on") { manager.turnOn(display) }
                        .disabled(manager.isApplyingPreset)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(10)
        .background(CardBackground())
    }

    private var footer: some View {
        HStack {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11))
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 2)
    }

    private func collapsedBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { collapsedRaw.split(separator: ",").contains { $0 == name } },
            set: { collapse in
                var names = Set(collapsedRaw.split(separator: ",").map(String.init))
                if collapse { names.insert(name) } else { names.remove(name) }
                collapsedRaw = names.sorted().joined(separator: ",")
            }
        )
    }
}

struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.primary.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.06)))
    }
}

private struct DisplayCard: View {
    @ObservedObject var display: DisplayController
    let canTurnOff: Bool
    @Binding var collapsed: Bool
    let turnOff: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !collapsed {
                if showsHiDPITip { hiDPITip }
                resolutionSection
                controls
                sliders
                if let message = display.message {
                    Label(message, systemImage: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(CardBackground())
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                .font(.system(size: 15))
                .foregroundStyle(display.isMain ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(display.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if display.isMain { Badge(text: "Main", tint: .accentColor) }
                }
                if let mode = display.currentMode {
                    HStack(spacing: 4) {
                        Text(verbatim: "\(mode.width) × \(mode.height)")
                        Text("·")
                        Text(ModeLogic.hzLabel(mode.refreshRate))
                        if mode.isHiDPI { Badge(text: "HiDPI", tint: .green) }
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if canTurnOff {
                IconButton(systemImage: "power", help: "Turn this display off (until you turn it back on or log out)", action: turnOff)
            }
            moreMenu
            IconButton(systemImage: collapsed ? "chevron.down" : "chevron.up", help: collapsed ? "Show controls" : "Hide controls") {
                withAnimation(.snappy(duration: 0.2)) { collapsed.toggle() }
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            if !display.isMain {
                Button("Set as Main Display", systemImage: "menubar.rectangle") { display.makeMain() }
            }
            if display.canRotate {
                Menu("Rotation", systemImage: "rotate.right") {
                    ForEach([0, 90, 180, 270], id: \.self) { degrees in
                        Toggle("\(degrees)°", isOn: Binding(get: { display.rotation == degrees }, set: { _ in display.rotate(to: degrees) }))
                    }
                }
            }
            if !display.isBuiltin {
                Divider()
                Section("HiDPI override") {
                    Button(display.overrideInstalled ? "Reinstall HiDPI Modes…" : "Install HiDPI Modes…", systemImage: "sparkles") {
                        display.installOverride()
                    }
                    if display.overrideInstalled {
                        Button("Remove HiDPI Modes…", systemImage: "trash") { display.removeOverride() }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("More options")
    }

    // MARK: HiDPI tip

    /// An external display running a non-Retina mode with no override yet: the one case where installing helps.
    private var showsHiDPITip: Bool {
        !display.isBuiltin && display.currentMode?.isHiDPI == false && !display.overrideInstalled
            && display.hiDPIModes.count < 2
    }

    private var hiDPITip: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.yellow)
            Text("Text isn't Retina-sharp here. Install HiDPI modes to unlock sharp \"looks like\" sizes.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Install…") { display.installOverride() }
                .controlSize(.small)
                .help("Asks for your admin password. Takes effect after you unplug and replug the display.")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.yellow.opacity(0.08)))
    }

    // MARK: Resolution

    private var resolutionSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Larger text").font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                Text("More space").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                ForEach(display.suggestedModes) { mode in
                    Chip(title: String(mode.width) + "×" + String(mode.height), selected: mode == display.currentMode) {
                        display.select(mode)
                    }
                }
            }
        }
    }

    // MARK: Refresh rate, input, all modes

    private var controls: some View {
        HStack(spacing: 6) {
            allModesMenu
            if display.refreshRates.count > 1 {
                ChipMenu(systemImage: "speedometer",
                         title: ModeLogic.hzLabel(display.currentMode?.refreshRate ?? 0),
                         help: "Refresh rate") {
                    ForEach(display.refreshRates) { mode in
                        Toggle(ModeLogic.hzLabel(mode.refreshRate),
                               isOn: Binding(get: { mode == display.currentMode }, set: { _ in display.select(mode) }))
                    }
                }
            }
            if display.supportsDDC {
                ChipMenu(systemImage: "cable.connector",
                         title: DDCService.inputs.first { $0.code == display.input }?.name ?? "Input",
                         help: "Switch the monitor's input. This Mac loses the display if you pick another port.") {
                    ForEach(DDCService.inputs, id: \.code) { input in
                        Toggle(input.name, isOn: Binding(get: { display.input == input.code }, set: { _ in display.setInput(input.code) }))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var allModesMenu: some View {
        ChipMenu(systemImage: "rectangle.expand.vertical", title: "All", help: "Every resolution this display offers") {
            Section("HiDPI (sharp)") {
                ForEach(display.hiDPIModes) { mode in
                    Toggle(mode.label, isOn: Binding(get: { mode == display.currentMode }, set: { _ in display.select(mode) }))
                }
            }
            Section("Low resolution") {
                ForEach(display.lowResolutionModes) { mode in
                    Toggle(mode.label, isOn: Binding(get: { mode == display.currentMode }, set: { _ in display.select(mode) }))
                }
            }
        }
    }

    // MARK: Sliders

    private var sliders: some View {
        VStack(spacing: 6) {
            if display.supportsDDC {
                PillSlider(title: "Brightness", systemImage: "sun.max.fill", value: display.brightness, range: 0...100, set: display.setBrightness)
                PillSlider(title: "Contrast", systemImage: "circle.lefthalf.filled", value: display.contrast, range: 0...100, set: display.setContrast)
            }
            if display.supportsVolume {
                PillSlider(title: "Volume", systemImage: "speaker.wave.2.fill", value: display.volume, range: 0...100, set: display.setVolume)
            }
            PillSlider(title: "Software brightness", systemImage: "moon.fill", value: display.dimming, range: 0.2...1, set: display.setDimming, tint: .indigo)
            if display.supportsDDC && !display.ddcResponded {
                Label("The monitor doesn't answer DDC reads, so these sliders may not match its real values. Turn on DDC/CI in its on-screen menu.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
