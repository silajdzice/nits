import Testing
@testable import Nits

private func mode(_ id: Int32, _ w: Int, _ h: Int, scale: Int = 2, hz: Double = 60) -> ModeLogic.Mode {
    ModeLogic.Mode(id: id, width: w, height: h, pixelWidth: w * scale, refreshRate: hz)
}

@Suite struct SuggestionTests {
    /// A 4K monitor: HiDPI modes at 16:9 plus plain ones.
    let fourK: [ModeLogic.Mode] = [
        mode(1, 960, 540), mode(2, 1152, 648), mode(3, 1280, 720), mode(4, 1600, 900),
        mode(5, 1920, 1080), mode(6, 2560, 1440), mode(7, 3360, 1890), mode(8, 1280, 1024),   // 5:4 odd one out
        mode(20, 3840, 2160, scale: 1), mode(21, 1920, 1080, scale: 1),
    ]

    @Test func hiDPIDesktopGetsHiDPIChoicesOfOneShape() {
        let picks = ModeLogic.suggestions(from: fourK, current: fourK[4])
        #expect(picks.count == 6)
        #expect(picks.allSatisfy { $0.isHiDPI })
        #expect(!picks.contains { $0.id == 8 })            // 5:4 mode filtered out
        #expect(picks.contains { $0.id == 5 })             // current is always offered
        #expect(picks.map(\.width) == picks.map(\.width).sorted())
    }

    @Test func plainDesktopGetsPlainChoices() {
        let dell: [ModeLogic.Mode] = [
            mode(1, 960, 540), mode(2, 1280, 720),                                  // tiny HiDPI modes
            mode(10, 2560, 1440, scale: 1), mode(11, 1920, 1080, scale: 1), mode(12, 1600, 900, scale: 1),
            mode(13, 1280, 720, scale: 1),
        ]
        let picks = ModeLogic.suggestions(from: dell, current: dell[2])
        #expect(picks.allSatisfy { !$0.isHiDPI })
        #expect(picks.contains { $0.id == 10 })
    }

    @Test func rotatedDisplayComparesPortraitWithPortrait() {
        // Portrait Dell: macOS reports modes already rotated (height > width).
        let portrait: [ModeLogic.Mode] = [
            mode(1, 540, 960), mode(2, 576, 1024), mode(3, 600, 800),
            mode(10, 1440, 2560, scale: 1), mode(11, 1080, 1920, scale: 1), mode(12, 900, 1600, scale: 1),
            mode(13, 768, 1024, scale: 1),                                           // 3:4, other shape
        ]
        let picks = ModeLogic.suggestions(from: portrait, current: portrait[3])
        #expect(picks.map(\.id).sorted() == [10, 11, 12])
    }

    @Test func currentModeOutsideTheGridIsSwappedIn() {
        let current = mode(99, 1700, 956)   // HiDPI, not in the list (another refresh rate of a size)
        let picks = ModeLogic.suggestions(from: fourK, current: current)
        #expect(picks.contains { $0.id == 99 })
        #expect(picks.count <= 6)
    }

    @Test func emptyAndSingleListsDontCrash() {
        #expect(ModeLogic.suggestions(from: [], current: nil).isEmpty)
        let one = mode(1, 1920, 1080)
        #expect(ModeLogic.suggestions(from: [one], current: one).map(\.id) == [1])
    }
}

@Suite struct RefreshTests {
    @Test func keepsFractionalRatesSeparateAndPrefersCurrent() {
        let a = mode(1, 1920, 1080, hz: 60), b = mode(2, 1920, 1080, hz: 59.94)
        let c = mode(3, 1920, 1080, hz: 160), dup = mode(4, 1920, 1080, hz: 60)
        let variants = ModeLogic.refreshVariants(of: [a, b, c, dup], current: dup)
        #expect(variants.map(\.refreshRate) == [160, 60, 59.94])
        #expect(variants.contains { $0.id == 4 })          // current wins its rate
        #expect(!variants.contains { $0.id == 1 })
    }

    @Test func labels() {
        #expect(ModeLogic.hzLabel(60) == "60 Hz")
        #expect(ModeLogic.hzLabel(59.94) == "59.94 Hz")
        #expect(ModeLogic.hzLabel(160.0001) == "160 Hz")
    }
}
