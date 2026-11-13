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
    /// When Nits turned each display off. macOS takes a moment to mark it inactive; during that moment
    /// the self-heal in `refresh()` must not drop it (the Keep/Revert fallback needs the entry).
    private var turnedOffAt: [CGDirectDisplayID: Date] = [:]
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

    // MARK: Remembered modes
    /// Each display's last mode while the set of screens was stable, keyed by `presetKeys()`.
    /// When screens come or go, macOS often falls back to a default mode (e.g. a 4K monitor jumping to
    /// "looks like 3360×1890" after an HDMI replug); Nits puts the remembered mode back.
    private var rememberedModes: [String: ModeRecord] = ModeRecord.load() {
        didSet { ModeRecord.save(rememberedModes) }
    }
    private var lastDisplaySet: Set<CGDirectDisplayID>?
    /// A display was added, removed, enabled or disabled since the last refresh. Catches an unplug and
    /// replug that land inside one refresh debounce, where the set of IDs looks unchanged.
    fileprivate var topologyChanged = false
    /// While settling after a change, modes are restored and never learned (they may be macOS fallbacks).
    private var restoreAttemptsLeft = 0
    private var pendingRestore: DispatchWorkItem?
    /// Displays whose modes a preset just set; the settling restore leaves them alone.
    private var restoreExclusions: Set<String> = []
    private var isSettling: Bool { restoreAttemptsLeft > 0 }
    private var refreshCount = 0

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
        refreshCount += 1
        // Failsafe: if the remaining displays were unplugged, bring back the ones Nits turned off.
        if !offDisplays.isEmpty && DisplayPower.activeCount() == 0 {
            turnAllOn()
        }
        // Self-heal: a display listed as off that macOS reports active (or whose ID was reused by another
        // monitor) isn't off; listing it would hide a working screen.
        let fresh = Set(turnedOffAt.filter { Date().timeIntervalSince($0.value) < 10 }.keys)
        let healed = Self.stillOff(offDisplays.filter { !fresh.contains($0.id) }) + offDisplays.filter { fresh.contains($0.id) }
        if healed.count != offDisplays.count {
            Log.displays.notice("Dropped \(self.offDisplays.count - healed.count, privacy: .public) stale off entries")
            offDisplays = healed
        }
        let off = Set(offDisplays.map(\.id))
        let services = DDCService.all()
        let ids = DisplayInfo.onlineIDs()
            .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay && !off.contains($0) }
        let ddc = Self.matchDDC(ids, services)
        displays = ids.map { DisplayController(id: $0, ddc: ddc[$0]) }
        layoutBroken = !ArrangementRepair.isConnected()
        updateActivePreset()
        Log.displays.notice("Refresh #\(self.refreshCount, privacy: .public): \(ids.count, privacy: .public) on, \(self.offDisplays.count, privacy: .public) off")
        trackModes(Set(ids))
    }

    /// Re-reads monitor values (brightness etc.) without rebuilding anything. Cheap: called when the menu opens.
    /// Re-reads monitor values when the menu opens. Re-matches DDC first if a monitor's DDC connection
    /// showed up after its display did (common right after a replug).
    func refreshMonitorValues() {
        let externalWithoutDDC = displays.filter { !$0.isBuiltin && $0.ddc == nil }.count
        if externalWithoutDDC > 0, DDCService.all().count > displays.filter({ $0.ddc != nil }).count {
            refresh()
            return
        }
        for display in displays { display.readDDC() }
    }

    /// A preset decides the modes of the displays it names; a settling restore must not undo those.
    /// Other displays (say, one replugged while the preset's prompt was open) are still restored.
    func excludeFromRestore(_ preset: Preset) {
        // Only matters for the current settling period; cleared when it ends.
        if isSettling { restoreExclusions.formUnion(preset.displays.keys) }
    }

    // MARK: Remembering and restoring modes

    private func trackModes(_ now: Set<CGDirectDisplayID>) {
        defer { lastDisplaySet = now }
        guard let previous = lastDisplaySet else { return }   // first refresh after launch: just observe

        if previous != now || topologyChanged {
            // Screens came or went. macOS applies its fallback modes over the next seconds, sometimes late,
            // and HiDPI modes can appear late too: restore several times while settling.
            Log.displays.notice("Display set changed: \(previous.count, privacy: .public) -> \(now.count, privacy: .public)")
            topologyChanged = false
            restoreAttemptsLeft = 4
            scheduleRestore(after: 2)
            return
        }
        learnModes()
    }

    private func scheduleRestore(after seconds: Double) {
        pendingRestore?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restoreAttempt() }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func restoreAttempt() {
        guard isSettling else { return }
        if isApplyingPreset || RevertPrompt.isBusy {
            // Someone else is changing modes; keep settling (no learning) and try again shortly.
            scheduleRestore(after: 2)
            return
        }
        restoreRememberedModes()
        restoreAttemptsLeft -= 1
        if isSettling {
            scheduleRestore(after: 2)
        } else {
            restoreExclusions = []
            Log.displays.notice("Settled")
        }
    }

    /// Records each display's current mode, unless the layout is settling or a change awaits Keep/Revert.
    func learnModes() {
        guard !isSettling, !isApplyingPreset, !RevertPrompt.isBusy else { return }
        let keys = presetKeys()
        for display in displays {
            guard let key = keys[display.id], let mode = CGDisplayCopyDisplayMode(display.id) else { continue }
            let record = ModeRecord(mode)
            if rememberedModes[key] != record { rememberedModes[key] = record }
        }
    }

    private func restoreRememberedModes() {
        let keys = presetKeys()
        var changed = false
        for display in displays {
            guard let key = keys[display.id], !restoreExclusions.contains(key), let want = rememberedModes[key],
                  let now = CGDisplayCopyDisplayMode(display.id), ModeRecord(now) != want,
                  let match = want.find(on: display.id) else { continue }
            Log.displays.notice("Restoring \(display.name, privacy: .public) to \(want.width, privacy: .public)x\(want.height, privacy: .public) from \(now.width, privacy: .public)x\(now.height, privacy: .public)")
            // Permanently: macOS then remembers it for this set of screens too.
            changed = DisplayConfig.apply(match, to: display.id, option: .permanently) || changed
        }
        if changed { ArrangementRepair.repairIfNeeded() }
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

    /// Displays Nits turned off in an earlier run that are still off (after a crash or a kill, nothing
    /// turned them back on). Only Nits' own saved list counts: macOS keeps answering vendor/model queries
    /// for a display for a while after it's *unplugged*, so probing IDs would mistake an unplugged
    /// monitor for a turned-off one, and then hide it when it's plugged back in under a reused ID.
    private static func discoverOffDisplays() -> [OffDisplay] {
        let saved = UserDefaults.standard.data(forKey: offDisplaysKey)
            .flatMap { try? JSONDecoder().decode([OffDisplay].self, from: $0) } ?? []
        return stillOff(saved)
    }

    /// Drops entries that are no longer "turned off by Nits": the display is active again (turned on,
    /// replugged), gone, or its ID now belongs to a different monitor.
    static func stillOff(_ entries: [OffDisplay]) -> [OffDisplay] {
        filterOff(entries,
                  isActive: { CGDisplayIsActive($0) != 0 },
                  currentKey: { id in
                      let vendor = CGDisplayVendorNumber(id)
                      guard vendor != 0, vendor != 0xFFFF_FFFF else { return nil }
                      return DisplayKey.make(vendor: vendor, model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id))
                  })
    }

    /// Pure core of `stillOff`, unit tested.
    static func filterOff(_ entries: [OffDisplay], isActive: (CGDirectDisplayID) -> Bool,
                          currentKey: (CGDirectDisplayID) -> String?) -> [OffDisplay] {
        entries.filter { entry in !isActive(entry.id) && currentKey(entry.id) == entry.key }
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
        turnedOffAt[id] = Date()
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

    func noteTurnedOff(_ id: CGDirectDisplayID) { turnedOffAt[id] = Date() }

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
    Log.displays.debug("Reconfigured display \(id, privacy: .public) flags=\(flags.rawValue, privacy: .public)")
    let manager = Unmanaged<DisplayManager>.fromOpaque(info).takeUnretainedValue()
    let topology: CGDisplayChangeSummaryFlags = [.addFlag, .removeFlag, .enabledFlag, .disabledFlag]
    let changed = !flags.isDisjoint(with: topology)
    DispatchQueue.main.async {
        if changed { manager.topologyChanged = true }
        manager.scheduleRefresh()
    }
}
