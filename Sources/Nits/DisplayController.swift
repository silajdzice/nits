import AppKit
import CoreGraphics

/// State and actions for one connected display.
final class DisplayController: ObservableObject, Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let isBuiltin: Bool
    let ddc: DDCService?
    /// Vendor, model and serial: survives replugs and reboots, unlike `id`.
    var key: String { DisplayKey.make(vendor: vendor, model: model, serial: serial) }

    @Published private(set) var supportsDDC = false
    /// True once the monitor answered at least one DDC read. Writes can still work without it.
    @Published private(set) var ddcResponded = false
    @Published private(set) var brightness: Double = 50  // percent
    @Published private(set) var contrast: Double = 50    // percent
    @Published private(set) var dimming: Double = 1      // software gamma, 0.2...1
    @Published private(set) var supportsVolume = false
    @Published private(set) var volume: Double = 50      // percent
    @Published private(set) var input: UInt16?
    @Published private(set) var modes: [DisplayMode] = []
    @Published private(set) var currentMode: DisplayMode?
    @Published private(set) var refreshRates: [DisplayMode] = []
    @Published private(set) var rotation = 0
    @Published private(set) var canRotate = false
    @Published private(set) var isMain = false
    @Published private(set) var overrideInstalled = false
    @Published var message: String?

    private var brightnessMax: UInt16 = 100
    private var contrastMax: UInt16 = 100
    private var volumeMax: UInt16 = 100

    init(id: CGDirectDisplayID, ddc: DDCService?, loadDDC: Bool = true) {
        self.id = id
        name = DisplayInfo.name(of: id)
        vendor = CGDisplayVendorNumber(id)
        model = CGDisplayModelNumber(id)
        serial = CGDisplaySerialNumber(id)
        isBuiltin = CGDisplayIsBuiltin(id) != 0
        self.ddc = isBuiltin ? nil : ddc
        canRotate = DisplayRotation.canRotate(id)
        reloadModes()
        if loadDDC { readDDC() }
        // Display controllers are rebuilt on every display change; restore this display's dimming.
        if let level = Self.dimLevels[id], level < 1 { setDimming(level) }
    }

    /// Software dimming per display, kept across controller rebuilds (main thread only).
    private static var dimLevels: [CGDirectDisplayID: Double] = [:]

    var hiDPIModes: [DisplayMode] { modes.filter(\.isHiDPI) }

    /// Up to six one-click choices, like the thumbnails in System Settings: HiDPI modes at the panel's
    /// aspect ratio, spread from largest text to most space, always including the current mode.
    /// Falls back to low-resolution modes on displays with no HiDPI modes.
    @Published private(set) var suggestedModes: [DisplayMode] = []

    private func computeSuggestedModes() -> [DisplayMode] {
        let ids = ModeLogic.suggestions(from: modes.map(\.logic), current: currentMode?.logic).map(\.id)
        // currentMode may not be in `modes` (that list keeps one refresh rate per size).
        let all = modes + (currentMode.map { [$0] } ?? [])
        return ids.compactMap { id in all.first { $0.id == id } }
    }
    var lowResolutionModes: [DisplayMode] { modes.filter { !$0.isHiDPI } }

    func reloadModes() {
        modes = DisplayInfo.modes(id)
        currentMode = DisplayInfo.currentMode(id)
        refreshRates = currentMode.map { DisplayInfo.refreshVariants(id, of: $0) } ?? []
        // Cached here, not computed in the view: it walks every display mode, and sliders re-render per drag event.
        suggestedModes = computeSuggestedModes()
        rotation = Int(CGDisplayRotation(id))
        isMain = CGDisplayIsMain(id) != 0
        overrideInstalled = HiDPIOverride.isInstalled(vendor: vendor, model: model)
    }

    // MARK: Resolution, rotation, arrangement

    func select(_ mode: DisplayMode) {
        guard let previous = CGDisplayCopyDisplayMode(id), previous.ioDisplayModeID != mode.id else { return }
        guard RevertPrompt.begin() else {
            message = "Confirm or revert the previous change first."
            return
        }
        // Session-only until confirmed, so even a crash mid-prompt is undone by logging out.
        guard DisplayConfig.apply(mode.mode, to: id, option: .forSession) else {
            RevertPrompt.end()
            message = "macOS refused \(mode.label)."
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if RevertPrompt.confirmKeep() {
                DisplayConfig.apply(mode.mode, to: self.id, option: .permanently)
            } else {
                DisplayConfig.apply(previous, to: self.id, option: .forSession)
            }
            RevertPrompt.end()
            self.reloadModes()
        }
    }

    func rotate(to degrees: Int) {
        let previous = rotation
        guard degrees != previous else { return }
        guard RevertPrompt.begin() else {
            message = "Confirm or revert the previous change first."
            return
        }
        guard DisplayRotation.set(id, degrees: degrees) else {
            RevertPrompt.end()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if !RevertPrompt.confirmKeep(title: "Keep this rotation?") {
                DisplayRotation.set(self.id, degrees: previous)
            }
            RevertPrompt.end()
            self.reloadModes()
        }
    }

    func makeMain() {
        if !DisplayArrangement.makeMain(id) { message = "macOS refused to make this the main display." }
        reloadModes()
    }

    // MARK: HiDPI override

    func installOverride() {
        guard let native = DisplayInfo.nativePixelSize(id) else {
            message = "Couldn't detect the native resolution."
            return
        }
        do {
            try HiDPIOverride.install(vendor: vendor, model: model, nativeWidth: native.width, nativeHeight: native.height)
            message = "HiDPI modes installed. Unplug and replug the display (or log out) to load them."
        } catch {
            message = error.localizedDescription
        }
        reloadModes()
    }

    func removeOverride() {
        do {
            try HiDPIOverride.remove(vendor: vendor, model: model)
            message = "Override removed. Replug the display (or log out) to drop the extra modes."
        } catch {
            message = error.localizedDescription
        }
        reloadModes()
    }

    // MARK: Brightness

    func readDDC() {
        guard let ddc else { return }
        DDCService.queue.async {
            let brightness = ddc.read(.brightness)
            let contrast = ddc.read(.contrast)
            let volume = ddc.read(.volume)
            let input = ddc.read(.input)
            DispatchQueue.main.async {
                if let volume, volume.max > 0 {
                    self.volumeMax = volume.max
                    self.volume = Double(volume.current) / Double(volume.max) * 100
                    self.supportsVolume = true
                }
                // Many monitors report the input in the low byte only.
                self.input = input.map { $0.current & 0xFF }
                // Writes can work even when reads don't, so a matched service always gets sliders;
                // without a read they start at 50%.
                self.supportsDDC = true
                self.ddcResponded = (brightness?.max ?? 0) > 0 && (contrast?.max ?? 0) > 0
                if let brightness, brightness.max > 0 {
                    self.brightnessMax = brightness.max
                    self.brightness = Double(brightness.current) / Double(brightness.max) * 100
                }
                if let contrast, contrast.max > 0 {
                    self.contrastMax = contrast.max
                    self.contrast = Double(contrast.current) / Double(contrast.max) * 100
                }
            }
        }
    }

    func setBrightness(_ percent: Double) {
        brightness = Self.clampPercent(percent)
        ddc?.enqueue(.brightness, Self.raw(brightness, max: brightnessMax))
    }

    func setContrast(_ percent: Double) {
        contrast = Self.clampPercent(percent)
        ddc?.enqueue(.contrast, Self.raw(contrast, max: contrastMax))
    }

    func setVolume(_ percent: Double) {
        volume = Self.clampPercent(percent)
        ddc?.enqueue(.volume, Self.raw(volume, max: volumeMax))
    }

    /// Values can come from a slider, a saved preset or a monitor's reply; never trust the range.
    static func clampPercent(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 100) : 50 }

    static func raw(_ percent: Double, max: UInt16) -> UInt16 {
        UInt16((clampPercent(percent) / 100 * Double(max)).rounded())
    }

    /// Switching away hands the monitor to another computer/port, so this Mac loses the display.
    func setInput(_ code: UInt16) {
        // Re-sending the current input makes some monitors blank and re-sync.
        guard code != input else { return }
        input = code
        ddc?.enqueue(.input, code)
    }

    /// Scales the display's own gamma table: works on any display, but only darkens (the backlight stays
    /// as bright). The original table, including any ColorSync calibration, is read once and restored at
    /// 100%. macOS also restores it when Nits quits.
    func setDimming(_ level: Double) {
        let level = level.isFinite ? min(max(level, 0.2), 1) : 1
        if level >= 0.999 && (Self.dimLevels[id] ?? 1) >= 0.999 {
            dimming = 1   // nothing to undo: leave the calibrated curve untouched
            return
        }
        // No gamma table (capacity 0 or unreadable): nothing can be dimmed, so don't pretend it was.
        guard let original = Self.originalTable(for: id) else {
            dimming = 1
            return
        }
        dimming = level
        Self.dimLevels[id] = level
        let scale = Float(level)
        var r = original.r.map { $0 * scale }, g = original.g.map { $0 * scale }, b = original.b.map { $0 * scale }
        CGSetDisplayTransferByTable(id, UInt32(r.count), &r, &g, &b)
        if level >= 0.999 {
            // Back to the original curve: forget it, so a profile change made meanwhile is picked up next time.
            Self.dimLevels[id] = nil
            Self.originalTables[id] = nil
        }
    }

    private static var originalTables: [CGDirectDisplayID: (r: [Float], g: [Float], b: [Float])] = [:]

    private static func originalTable(for id: CGDirectDisplayID) -> (r: [Float], g: [Float], b: [Float])? {
        if let saved = originalTables[id] { return saved }
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 0 else { return nil }
        var r = [Float](repeating: 0, count: Int(capacity)), g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &count) == .success, count > 0 else { return nil }
        let table = (Array(r.prefix(Int(count))), Array(g.prefix(Int(count))), Array(b.prefix(Int(count))))
        originalTables[id] = table
        return table
    }
}
