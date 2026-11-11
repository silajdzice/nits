import Testing
@testable import Nits

private typealias Box = ArrangementRepair.Box

@Suite struct ArrangementTests {
    @Test func sharedEdgeIsConnectedCornerIsNot() {
        let a = Box(id: 1, x: 0, y: 0, w: 1920, h: 1080)
        #expect(ArrangementRepair.touching(a, Box(id: 2, x: 1920, y: 500, w: 1000, h: 1000)))
        #expect(!ArrangementRepair.touching(a, Box(id: 2, x: -1512, y: 1080, w: 1512, h: 982)))   // corner only
        #expect(!ArrangementRepair.touching(a, Box(id: 2, x: 1920, y: 1060, w: 1000, h: 1000)))   // 20 pt sliver
    }

    /// The real layout that stranded the cursor: built-in touching the G27U only at a corner.
    @Test func repairsCornerOnlyLayoutAndMovesGroupsTogether() {
        let broken = [
            Box(id: 2, x: 0, y: 0, w: 1920, h: 1080),
            Box(id: 1, x: -1512, y: 1080, w: 1512, h: 982),
            Box(id: 3, x: -2952, y: -360, w: 1440, h: 2560),
        ]
        #expect(!ArrangementRepair.isConnected(broken))
        let fixed = ArrangementRepair.repairedBoxes(broken, mainID: 2)
        #expect(ArrangementRepair.isConnected(fixed))
        #expect(fixed.first { $0.id == 2 }.map { ($0.x, $0.y) } ?? (9, 9) == (0, 0))   // main never moves
        // Built-in and Dell keep their relative position.
        let b = fixed.first { $0.id == 1 }!, d = fixed.first { $0.id == 3 }!
        #expect(b.x - d.x == 1440 && b.y - d.y == 1440)
        // Nothing overlaps.
        for i in fixed.indices { for j in fixed.indices where i < j {
            let p = fixed[i], q = fixed[j]
            #expect(min(p.maxX, q.maxX) <= max(p.x, q.x) || min(p.maxY, q.maxY) <= max(p.y, q.y))
        } }
    }

    @Test func connectedLayoutIsLeftAlone() {
        let ok = [Box(id: 1, x: 0, y: 0, w: 1920, h: 1080), Box(id: 2, x: 1920, y: 0, w: 2560, h: 1440)]
        #expect(ArrangementRepair.isConnected(ok))
        let fixed = ArrangementRepair.repairedBoxes(ok, mainID: 1)
        #expect(zip(ok, fixed).allSatisfy { $0.x == $1.x && $0.y == $1.y })
    }

    @Test func farAwayDisplayIsPulledIn() {
        let far = [Box(id: 1, x: 0, y: 0, w: 1920, h: 1080), Box(id: 2, x: 9000, y: 9000, w: 1000, h: 800)]
        #expect(ArrangementRepair.isConnected(ArrangementRepair.repairedBoxes(far, mainID: 1)))
    }
}
