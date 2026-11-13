import Foundation
import Testing
@testable import Nits

private func on(_ name: String, _ w: Int, _ h: Int, hz: Int = 60, x: Int = 0, y: Int = 0, rotation: Int = 0) -> DisplayState {
    DisplayState(name: name, enabled: true, width: w, height: h, pixelWidth: w * 2, refreshRate: hz,
                 rotation: rotation, originX: x, originY: y, brightness: 50, dimming: 1)
}
private func off(_ name: String) -> DisplayState { DisplayState(name: name, enabled: false) }

@Suite struct PresetMatchTests {
    let desk = Preset(name: "Desk", displays: ["g": on("G27U", 1920, 1080, hz: 160), "d": on("Dell", 2560, 1440, x: 1920)])
    let gaming = Preset(name: "Gaming", displays: ["g": on("G27U", 1920, 1080, hz: 160), "d": off("Dell"), "b": off("Built-in")])

    @Test func exactSetupMatches() {
        #expect(desk.matches(["g": on("G27U", 1920, 1080, hz: 160), "d": on("Dell", 2560, 1440, x: 1920)]))
    }

    @Test func brightnessAndExactPositionAreIgnored() {
        var dell = on("Dell", 2560, 1440, x: 1920, y: 200)
        dell.brightness = 90
        #expect(desk.matches(["g": on("G27U", 1920, 1080, hz: 160), "d": dell]))
    }

    @Test func differentRefreshOrMainDoesNotMatch() {
        #expect(!desk.matches(["g": on("G27U", 1920, 1080, hz: 60), "d": on("Dell", 2560, 1440, x: 1920)]))
        #expect(!desk.matches(["g": on("G27U", 1920, 1080, hz: 160, x: 2560), "d": on("Dell", 2560, 1440)]))
    }

    @Test func offAndUnpluggedAreTheSame() {
        #expect(gaming.matches(["g": on("G27U", 1920, 1080, hz: 160)]))
        #expect(gaming.matches(["g": on("G27U", 1920, 1080, hz: 160), "d": off("Dell")]))
        #expect(!gaming.matches(["g": on("G27U", 1920, 1080, hz: 160), "d": on("Dell", 2560, 1440, x: 1920)]))
    }

    @Test func screenOnButMissingFromPresetDoesNotMatch() {
        let gOnly = Preset(name: "G", displays: ["g": on("G27U", 1920, 1080, hz: 160)])
        #expect(!gOnly.matches(["g": on("G27U", 1920, 1080, hz: 160), "b": on("Built-in", 1512, 982, x: -1512)]))
    }

    @Test func emptyPresetNeverMatches() {
        #expect(!Preset(name: "Empty", displays: [:]).matches([:]))
    }
}

@Suite struct DisplayKeyTests {
    @Test func uniqueKeysStayPlainDuplicatesGetOrdinals() {
        let keys = DisplayKey.assign([(id: 7, base: "a"), (id: 3, base: "a"), (id: 5, base: "b")])
        #expect(keys[3] == "a#1" && keys[7] == "a#2" && keys[5] == "b")
    }
}

@Suite struct PresetStoreTests {
    @Test func roundTripsThroughJSON() throws {
        let preset = Preset(name: "Desk", displays: ["g": on("G27U", 1920, 1080)])
        let data = try JSONEncoder().encode([preset])
        #expect(try JSONDecoder().decode([Preset].self, from: data) == [preset])
    }
}

@Suite struct ModeRecordTests {
    @Test func fractionalRatesStayDistinctAndRoundTrip() throws {
        let a = ModeRecord(width: 1920, height: 1080, pixelWidth: 3840, refreshRate: 6000)
        let b = ModeRecord(width: 1920, height: 1080, pixelWidth: 3840, refreshRate: 5994)
        #expect(a != b)
        let data = try JSONEncoder().encode(["g": a])
        #expect(try JSONDecoder().decode([String: ModeRecord].self, from: data) == ["g": a])
    }
}
