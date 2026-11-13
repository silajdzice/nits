import AppKit
import CoreGraphics
import Foundation

enum DisplayKey {
    static func make(vendor: UInt32, model: UInt32, serial: UInt32) -> String { "\(vendor)-\(model)-\(serial)" }

    /// Identical monitors can share vendor, model and serial (often serial 0); those get "#1", "#2"...
    /// in display-ID order. Unique ones keep the plain key, so presets saved earlier still match.
    static func assign(_ displays: [(id: CGDirectDisplayID, base: String)]) -> [CGDirectDisplayID: String] {
        var result: [CGDirectDisplayID: String] = [:]
        for (base, group) in Dictionary(grouping: displays, by: \.base) {
            let sorted = group.sorted { $0.id < $1.id }
            for (i, entry) in sorted.enumerated() {
                result[entry.id] = sorted.count == 1 ? base : "\(base)#\(i + 1)"
            }
        }
        return result
    }
}

/// What one display should look like in a preset. Off displays only need `enabled = false`.
struct DisplayState: Codable, Equatable {
    var name: String
    var enabled: Bool
    var width: Int?          // points ("looks like")
    var height: Int?
    var pixelWidth: Int?     // tells HiDPI and low-res versions of the same size apart
    var refreshRate: Int?
    var rotation: Int?
    var originX: Int?        // arrangement; the display at (0, 0) is the main display
    var originY: Int?
    var brightness: Double?  // DDC percent, only when the monitor answers DDC reads
    var dimming: Double?

    var isMain: Bool { originX == 0 && originY == 0 }
}

/// A named snapshot of the whole desk: every display Nits knew about when it was saved, keyed by `DisplayKey`.
struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var displays: [String: DisplayState]

    /// Same layout as `now`: displays in both agree on on/off, mode, refresh rate, rotation and main.
    /// Brightness and exact positions are ignored, so nudging a slider doesn't "leave" the preset.
    /// "Off" and "not connected" count as the same thing, so a laptop-only preset still matches when
    /// the external monitor is unplugged, and a two-screen preset doesn't.
    func matches(_ now: [String: DisplayState]) -> Bool {
        // Every display that is on right now must be part of this preset.
        for (key, have) in now where have.enabled && displays[key] == nil { return false }
        for (key, want) in displays {
            let have = now[key]
            guard want.enabled else {
                if have?.enabled == true { return false }
                continue
            }
            guard let have, have.enabled else { return false }
            if want.width != have.width || want.height != have.height || want.pixelWidth != have.pixelWidth
                || want.refreshRate != have.refreshRate || (want.rotation ?? 0) != (have.rotation ?? 0)
                || want.isMain != have.isMain { return false }
        }
        return !displays.isEmpty
    }
}

enum PresetStore {
    private static let key = "presets.v1"

    static func load() -> [Preset] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        // Decode one by one: a single unreadable preset must not wipe the others on the next save.
        let items = (try? JSONDecoder().decode([Lossy].self, from: data)) ?? []
        return items.compactMap(\.preset)
    }

    private struct Lossy: Decodable {
        let preset: Preset?
        init(from decoder: Decoder) throws { preset = try? Preset(from: decoder) }
    }

    static func save(_ presets: [Preset]) {
        if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: key) }
    }
}

extension DisplayManager {
    // MARK: Identity

    /// The preset key for every display Nits knows about (on or off). Identical monitors can share
    /// vendor, model and serial (often serial 0), so those get "#1", "#2"... in display-ID order.
    func presetKeys() -> [CGDirectDisplayID: String] {
        DisplayKey.assign(displays.map { (id: $0.id, base: $0.key) } + offDisplays.map { (id: $0.id, base: $0.key) })
    }

    /// Names of connected displays (on or off) a preset says nothing about; applying it leaves them alone.
    func connectedNotIn(_ preset: Preset) -> [String] {
        let keys = presetKeys()
        let named = displays.map { ($0.id, $0.name) } + offDisplays.map { ($0.id, $0.name) }
        return named.compactMap { id, name in
            guard let key = keys[id], preset.displays[key] == nil else { return nil }
            return name
        }
    }

    // MARK: Capture

    func captureSetup() -> [String: DisplayState] {
        let keys = presetKeys()
        var result: [String: DisplayState] = [:]
        for display in displays {
            guard let key = keys[display.id] else { continue }
            let mode = CGDisplayCopyDisplayMode(display.id)
            let origin = CGDisplayBounds(display.id).origin
            result[key] = DisplayState(
                name: display.name, enabled: true,
                width: mode?.width, height: mode?.height, pixelWidth: mode?.pixelWidth,
                refreshRate: mode.map { Int($0.refreshRate.rounded()) },
                rotation: Int(CGDisplayRotation(display.id)),
                originX: Int(origin.x), originY: Int(origin.y),
                brightness: display.ddcResponded ? display.brightness : nil,
                dimming: display.dimming
            )
        }
        for off in offDisplays {
            guard let key = keys[off.id] else { continue }
            result[key] = DisplayState(name: off.name, enabled: false)
        }
        return result
    }

    // MARK: Editing

    func savePreset(named name: String) {
        presets.append(Preset(name: name, displays: captureSetup()))
        updateActivePreset()
    }

    func updatePreset(_ preset: Preset) {
        guard let i = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[i].displays = captureSetup()
        updateActivePreset()
    }

    func renamePreset(_ preset: Preset, to name: String) {
        guard let i = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[i].name = name
    }

    func deletePreset(_ preset: Preset) {
        presets.removeAll { $0.id == preset.id }
        updateActivePreset()
    }

    // MARK: Applying

    /// Applies a preset, then shows one "Keep this setup?" countdown for the whole change.
    /// Reverting re-applies a snapshot taken just before, so a preset saved on a different desk can't
    /// strand you on a black screen.
    func apply(_ preset: Preset) {
        guard !isApplyingPreset else { return }
        guard RevertPrompt.begin() else {
            NSSound.beep()   // another change is still waiting for Keep/Revert
            return
        }
        let before = captureSetup()
        isApplyingPreset = true
        Task { @MainActor in
            await self.applySetup(preset.displays)
            // Old presets may hold a layout that strands the cursor; fix before asking to keep it.
            if ArrangementRepair.repairIfNeeded() { try? await Task.sleep(for: .milliseconds(800)) }
            if RevertPrompt.confirmKeep(title: "Keep the \u{201C}\(preset.name)\u{201D} setup?") {
                self.noteApplied(preset)
                // Steps ran for this session only; now let macOS remember the modes for this display set.
                self.applyModes(preset.displays, option: .permanently)
            } else {
                await self.applySetup(before)
                ArrangementRepair.repairIfNeeded()
            }
            RevertPrompt.end()
            self.excludeFromRestore(preset)
            self.isApplyingPreset = false
            self.refresh()
            self.learnModes()
        }
    }

    /// Order matters: displays must be on before they can be configured, rotation changes the shape that
    /// origins refer to, and displays are turned off last so the others are already where they belong.
    @MainActor
    private func applySetup(_ setup: [String: DisplayState]) async {
        // Displays the setup doesn't mention keep their mode through the on/off changes below.
        var keys = presetKeys()
        let untouched = currentModes().filter { id, _ in keys[id].map { setup[$0] == nil } ?? true }

        // 1. Turn on displays the setup wants on.
        let toTurnOn = offDisplays.filter { keys[$0.id].flatMap { setup[$0]?.enabled } == true }
        var turnedOn: [CGDirectDisplayID] = []
        for off in toTurnOn where DisplayPower.setEnabled(off.id, true) {
            turnedOn.append(off.id)
        }
        offDisplays.removeAll { turnedOn.contains($0.id) }
        if !turnedOn.isEmpty {
            await waitUntilActive(turnedOn)
            refresh()
            keys = presetKeys()
        }

        // 2. Rotation.
        var rotated = false
        for display in displays {
            guard let want = keys[display.id].flatMap({ setup[$0] }), want.enabled, let degrees = want.rotation,
                  degrees != Int(CGDisplayRotation(display.id)), display.canRotate else { continue }
            rotated = await DisplayRotation.set(display.id, degrees: degrees) || rotated
        }
        if rotated { await settle() }

        // 3. Modes and arrangement in one transaction.
        applyModes(setup, option: .forSession)
        await settle()
        refresh()

        // 4. Turn off displays the setup wants off, never the last active one.
        keys = presetKeys()
        var turnedOff = false
        for display in displays where keys[display.id].flatMap({ setup[$0]?.enabled }) == false {
            guard DisplayPower.desktopCount() > 1, DisplayPower.setEnabled(display.id, false) else { continue }
            offDisplays.append(OffDisplay(id: display.id, name: display.name, key: display.key))
            turnedOff = true
        }
        if turnedOff {
            await settle()
            refresh()
            // A new set of active displays makes macOS fall back to default modes on the rest; put ours back.
            applyModes(setup, option: .forSession)
            for (id, wanted) in untouched {
                guard let now = CGDisplayCopyDisplayMode(id), !Self.sameMode(now, wanted),
                      let match = Self.findMode(like: wanted, on: id) else { continue }
                DisplayConfig.apply(match, to: id, option: .forSession)
            }
            await settle()
            refresh()
        }

        // 5. Brightness and dimming on the fresh controllers.
        keys = presetKeys()
        for display in displays {
            guard let want = keys[display.id].flatMap({ setup[$0] }), want.enabled else { continue }
            if let dimming = want.dimming { display.setDimming(dimming) }
            if let brightness = want.brightness, display.ddc != nil {
                // New controllers queue their DDC reads at init. Going through the same serial queue
                // runs this after those reads land, so a stale read can't overwrite the new value.
                DDCService.queue.async {
                    DispatchQueue.main.async { display.setBrightness(brightness) }
                }
            }
        }
    }

    @discardableResult
    func applyModes(_ setup: [String: DisplayState], option: CGConfigureOption) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        var changed = false
        let keys = presetKeys()
        for display in displays {
            guard let want = keys[display.id].flatMap({ setup[$0] }), want.enabled else { continue }
            if let mode = Self.findMode(want, on: display.id) {
                CGConfigureDisplayWithDisplayMode(config, display.id, mode, nil)
                changed = true
            }
            if let x = want.originX, let y = want.originY {
                // Clamped: a corrupted preset must not crash the app (Int32(_) traps when out of range).
                CGConfigureDisplayOrigin(config, display.id, Int32(clamping: x), Int32(clamping: y))
                changed = true
            }
        }
        guard changed else {
            CGCancelDisplayConfiguration(config)
            return true
        }
        return CGCompleteDisplayConfiguration(config, option) == .success
    }

    private static func findMode(_ want: DisplayState, on id: CGDirectDisplayID) -> CGDisplayMode? {
        guard let width = want.width, let height = want.height else { return nil }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []).filter { $0.isUsableForDesktopGUI() }
        let sameSize = all.filter { $0.width == width && $0.height == height && (want.pixelWidth == nil || $0.pixelWidth == want.pixelWidth) }
        // Exact refresh rate if offered, otherwise the fastest at that size.
        return sameSize.first { Int($0.refreshRate.rounded()) == want.refreshRate }
            ?? sameSize.max { $0.refreshRate < $1.refreshRate }
    }

    /// A display that was just turned on can take a few seconds to link up; wait for it (up to 6 s).
    private func waitUntilActive(_ ids: [CGDirectDisplayID]) async {
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(500))
            if ids.allSatisfy({ CGDisplayIsActive($0) != 0 }) { break }
        }
        await settle()
    }

    /// Display changes land asynchronously, in a burst of callbacks; give them time before the next step.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(1500))
    }
}
