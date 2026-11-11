import AppKit
import CoreGraphics
import Foundation

/// Tracks connected displays and rebuilds their controllers when the configuration changes.
final class DisplayManager: ObservableObject {
    struct OffDisplay: Identifiable, Codable {
        let id: CGDirectDisplayID
        let name: String
        /// Stable identity for presets (display IDs can change across replugs).
        let key: String
    }

    @Published private(set) var displays: [DisplayController] = []
    /// Displays Nits turned off this session. macOS stops listing them, so Nits remembers them to turn back on.
    /// Settable from Presets.swift, which turns displays on and off as part of applying a preset.
    /// Saved so a Nits that was killed (no chance to turn them back on) still lists them after a restart.
    @Published var offDisplays: [OffDisplay] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(offDisplays) { UserDefaults.standard.set(data, forKey: Self.offDisplaysKey) }
        }
    }
    private static let offDisplaysKey = "offDisplays.v1"
    /// The preset applied last; wins the highlight when several presets match the same setup.
    private var lastAppliedPresetID: UUID?
    @Published var presets: [Preset] = PresetStore.load() {
        didSet { PresetStore.save(presets) }
    }
    /// The preset whose resolutions, rotation, arrangement and on/off state match the screens right now.
    @Published private(set) var activePresetID: UUID?
    @Published var isApplyingPreset = false
    /// Some active display shares no edge with the others, so the cursor can't reach it.
    @Published private(set) var layoutBroken = false
    private var pendingRefresh: DispatchWorkItem?

    init() {
        offDisplays = Self.discoverOffDisplays()
        refresh()
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
        // Never leave a display dark after Nits is gone: nothing would be left to turn it back on.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.turnAllOn()
        }
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
    }

    func refresh() {
        // Failsafe: if the remaining displays were unplugged, bring back the ones Nits turned off.
        if !offDisplays.isEmpty && DisplayPower.activeCount() == 0 {
            turnAllOn()
        }
        let off = Set(offDisplays.map(\.id))
        let services = DDCService.all()
        let ids = DisplayInfo.onlineIDs()
            .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay && !off.contains($0) }
        let ddc = Self.matchDDC(ids, services)
        displays = ids.map { DisplayController(id: $0, ddc: ddc[$0]) }
        layoutBroken = !ArrangementRepair.isConnected()
        updateActivePreset()
    }

    static func matchDDC(_ ids: [CGDirectDisplayID], _ services: [DDCService]) -> [CGDirectDisplayID: DDCService] {
        let external = ids.filter { CGDisplayIsBuiltin($0) == 0 }
            .map { (id: $0, vendor: CGDisplayVendorNumber($0), model: CGDisplayModelNumber($0), serial: CGDisplaySerialNumber($0)) }
        let pairs = DDCService.assign(displays: external, services: services.map { (vendor: $0.vendor, product: $0.product, serial: $0.serial) })
        return pairs.mapValues { services[$0] }
    }

    func updateActivePreset() {
        let now = captureSetup()
        let matching = presets.filter { $0.matches(now) }
        activePresetID = matching.first { $0.id == lastAppliedPresetID }?.id ?? matching.first?.id
    }

    func repairArrangement() {
        ArrangementRepair.repairIfNeeded()
        scheduleRefresh()
    }

    func noteApplied(_ preset: Preset) {
        lastAppliedPresetID = preset.id
    }

    /// Displays that are connected but turned off: macOS drops them from the online list, but still
    /// answers vendor/model queries for their IDs. Combines Nits' saved list with a probe of low IDs
    /// (Apple Silicon numbers displays 1, 2, 3...), so displays turned off by an earlier, killed Nits
    /// or by another app still show up with a Turn on button.
    private static func discoverOffDisplays() -> [OffDisplay] {
        let saved = UserDefaults.standard.data(forKey: offDisplaysKey)
            .flatMap { try? JSONDecoder().decode([OffDisplay].self, from: $0) } ?? []
        let services = DDCService.all()
        var result: [OffDisplay] = []
        for id in Set(saved.map(\.id)).union(1...32).sorted() {
            let vendor = CGDisplayVendorNumber(id)
            guard CGDisplayIsOnline(id) == 0, vendor != 0, vendor != 0xFFFF_FFFF else { continue }
            // A closed lid takes the built-in screen offline too; only list it if Nits turned it off.
            if CGDisplayIsBuiltin(id) != 0 && !saved.contains(where: { $0.id == id }) { continue }
            let model = CGDisplayModelNumber(id)
            let serial = CGDisplaySerialNumber(id)
            let name = saved.first { $0.id == id }?.name
                ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : nil)
                ?? services.first { $0.vendor == vendor && $0.product == model }?.productName
                ?? "Display \(id)"
            result.append(OffDisplay(id: id, name: name, key: DisplayKey.make(vendor: vendor, model: model, serial: serial)))
        }
        return result
    }

    /// Turns a display off, then asks to keep it that way. Doing nothing turns it back on after 15 s:
    /// the remaining screens might be ones you can't actually see (a virtual or dummy display, a
    /// screen in another room), and then nothing else could bring the picture back.
    func turnOff(_ display: DisplayController) {
        guard DisplayPower.desktopCount() > 1 else {
            display.message = "Can't turn off the only active display."
            return
        }
        guard RevertPrompt.begin() else {
            display.message = "Confirm or revert the previous change first."
            return
        }
        let saved = currentModes(except: display.id)
        guard DisplayPower.setEnabled(display.id, false) else {
            RevertPrompt.end()
            display.message = "macOS refused to turn this display off."
            return
        }
        let id = display.id
        offDisplays.append(OffDisplay(id: id, name: display.name, key: display.key))
        restoreModes(saved)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            let keep = RevertPrompt.confirmKeep(title: "Keep \u{201C}\(display.name)\u{201D} turned off?")
            RevertPrompt.end()
            if !keep, let self, let off = self.offDisplays.first(where: { $0.id == id }) {
                self.turnOn(off)
            }
        }
    }

    func turnOn(_ display: OffDisplay) {
        let saved = currentModes(except: display.id)
        // Keep tracking it if macOS refuses; otherwise nothing could turn it back on until logout.
        guard DisplayPower.setEnabled(display.id, true) else {
            // Probably unplugged since: nothing left to turn on.
            if CGDisplayVendorNumber(display.id) == 0xFFFF_FFFF { offDisplays.removeAll { $0.id == display.id } }
            return
        }
        offDisplays.removeAll { $0.id == display.id }
        restoreModes(saved)
    }

    // MARK: Keeping resolutions across on/off

    /// macOS stores display modes per *set* of active displays. Turning one off creates a set it may never
    /// have seen, so it falls back to default modes on the others. Nits notes every other display's mode
    /// before the switch and puts it back once the reconfiguration settles.
    func currentModes(except skipped: CGDirectDisplayID? = nil) -> [CGDirectDisplayID: CGDisplayMode] {
        var result: [CGDirectDisplayID: CGDisplayMode] = [:]
        for id in DisplayInfo.onlineIDs() where id != skipped {
            if let mode = CGDisplayCopyDisplayMode(id) { result[id] = mode }
        }
        return result
    }

    private func restoreModes(_ saved: [CGDirectDisplayID: CGDisplayMode]) {
        // macOS applies its fallback modes asynchronously; wait for that before restoring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            for (id, wanted) in saved {
                guard let now = CGDisplayCopyDisplayMode(id), !Self.sameMode(now, wanted),
                      let match = Self.findMode(like: wanted, on: id) else { continue }
                // Permanently: macOS then remembers it for this display set, so next time needs no fix-up.
                DisplayConfig.apply(match, to: id, option: .permanently)
            }
            // A display that comes back on can land where it touches nothing; reconnect it.
            ArrangementRepair.repairIfNeeded()
            self?.scheduleRefresh()
        }
    }

    static func sameMode(_ a: CGDisplayMode, _ b: CGDisplayMode) -> Bool {
        a.width == b.width && a.height == b.height && a.pixelWidth == b.pixelWidth
            && Int(a.refreshRate.rounded()) == Int(b.refreshRate.rounded())
    }

    /// Mode IDs can change across a reconfiguration, so match by size, pixels and refresh rate.
    static func findMode(like wanted: CGDisplayMode, on id: CGDirectDisplayID) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let all = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
        return all.first { sameMode($0, wanted) }
    }

    func turnAllOn() {
        for display in offDisplays {
            DisplayPower.setEnabled(display.id, true)
        }
        offDisplays = []
    }

    /// Reconfiguration callbacks arrive in bursts (one per display, per change); refresh once they settle.
    fileprivate func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}

private func displayReconfigured(_ id: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ info: UnsafeMutableRawPointer?) {
    guard let info, !flags.contains(.beginConfigurationFlag) else { return }
    let manager = Unmanaged<DisplayManager>.fromOpaque(info).takeUnretainedValue()
    DispatchQueue.main.async { manager.scheduleRefresh() }
}
