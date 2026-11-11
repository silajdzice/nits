import AppKit
import CoreGraphics

/// One resolution the display can run at. `width`/`height` are points (what "looks like" means),
/// `pixelWidth`/`pixelHeight` are the backing framebuffer. HiDPI means pixels > points.
struct DisplayMode: Identifiable, Equatable {
    let mode: CGDisplayMode

    var id: Int32 { mode.ioDisplayModeID }
    var width: Int { mode.width }
    var height: Int { mode.height }
    var pixelWidth: Int { mode.pixelWidth }
    var pixelHeight: Int { mode.pixelHeight }
    var refreshRate: Double { mode.refreshRate }
    var isHiDPI: Bool { pixelWidth > width }

    var label: String {
        let hz = refreshRate > 0 ? " · " + ModeLogic.hzLabel(refreshRate) : ""
        return "\(width) × \(height)\(hz)"
    }

    var logic: ModeLogic.Mode {
        ModeLogic.Mode(id: id, width: width, height: height, pixelWidth: pixelWidth, refreshRate: refreshRate)
    }

    static func == (a: DisplayMode, b: DisplayMode) -> Bool { a.id == b.id }
}

enum DisplayInfo {
    /// IOKit flag marking the panel's native timing.
    private static let nativeFlag: UInt32 = 0x0200_0000

    static func onlineIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func name(of id: CGDirectDisplayID) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }
        return screen?.localizedName ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)")
    }

    private static func allModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
    }

    /// Desktop modes, one per (size, HiDPI) pair, preferring the current refresh rate, largest first.
    static func modes(_ id: CGDirectDisplayID) -> [DisplayMode] {
        let currentRate = CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0
        func score(_ m: CGDisplayMode) -> Double { (m.refreshRate == currentRate ? 1000 : 0) + m.refreshRate }

        var best: [String: CGDisplayMode] = [:]
        for m in allModes(id) where m.isUsableForDesktopGUI() {
            let key = "\(m.width)x\(m.height)-\(m.pixelWidth > m.width)"
            if let existing = best[key], score(existing) >= score(m) { continue }
            best[key] = m
        }
        return best.values.map(DisplayMode.init).sorted {
            ($0.width * $0.height, $0.isHiDPI ? 1 : 0) > ($1.width * $1.height, $1.isHiDPI ? 1 : 0)
        }
    }

    /// The same resolution at each refresh rate the display offers, fastest first.
    static func refreshVariants(_ id: CGDirectDisplayID, of mode: DisplayMode) -> [DisplayMode] {
        let sameSize = allModes(id).filter {
            $0.isUsableForDesktopGUI() && $0.width == mode.width && $0.height == mode.height && $0.pixelWidth == mode.pixelWidth
        }.map(DisplayMode.init)
        let ids = ModeLogic.refreshVariants(of: sameSize.map(\.logic), current: mode.logic).map(\.id)
        return ids.compactMap { id in sameSize.first { $0.id == id } }
    }

    static func currentMode(_ id: CGDirectDisplayID) -> DisplayMode? {
        CGDisplayCopyDisplayMode(id).map(DisplayMode.init)
    }

    /// Native panel resolution in pixels, in the panel's unrotated (landscape) orientation.
    static func nativePixelSize(_ id: CGDirectDisplayID) -> (width: Int, height: Int)? {
        let modes = allModes(id)
        let native = modes.first { $0.ioFlags & nativeFlag != 0 && $0.pixelWidth == $0.width }
            ?? modes.filter { $0.pixelWidth == $0.width }.max { $0.width * $0.height < $1.width * $1.height }
        guard let native else { return nil }
        // Panels are landscape; a rotated display may list its modes portrait. Normalise instead of
        // guessing whether macOS already swapped them.
        return (max(native.width, native.height), min(native.width, native.height))
    }
}

enum DisplayConfig {
    @discardableResult
    static func apply(_ mode: CGDisplayMode, to id: CGDirectDisplayID, option: CGConfigureOption) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, id, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, option) == .success
    }
}

/// The "Keep this resolution?" countdown macOS shows, so a bad mode can't strand you on a black screen.
/// Return (the default button) reverts; only an explicit click on Keep keeps it.
enum RevertPrompt {
    /// One reversible change at a time. A second change started while a prompt is pending would nest a
    /// second prompt, and the countdowns would then revert to the wrong mode or stop counting.
    private(set) static var isBusy = false

    /// Claims the lock; false if another change is still waiting for Keep/Revert. Main thread only.
    static func begin() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    static func end() { isBusy = false }

    static func confirmKeep(title: String = "Keep this resolution?", seconds: Int = 15) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Reverting in \(seconds) seconds."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Keep")

        var remaining = seconds
        let timer = Timer(timeInterval: 1, repeats: true) { timer in
            remaining -= 1
            alert.informativeText = "Reverting in \(remaining) seconds."
            if remaining <= 0 {
                timer.invalidate()
                // Only end our own alert, never some other modal session.
                if NSApp.modalWindow === alert.window { NSApp.abortModal() }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        return alert.runModal() == .alertSecondButtonReturn
    }
}
