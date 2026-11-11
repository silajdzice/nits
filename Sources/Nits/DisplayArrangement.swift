import CoreGraphics
import Foundation

enum DisplayArrangement {
    /// The main display (menu bar, Dock, new windows) is whichever display sits at global origin (0, 0).
    /// Shifting every display by the target's origin moves it there without changing the layout.
    @discardableResult
    static func makeMain(_ id: CGDirectDisplayID) -> Bool {
        let target = CGDisplayBounds(id).origin
        guard target != .zero else { return true }
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        for display in ids where CGDisplayMirrorsDisplay(display) == kCGNullDirectDisplay {
            let origin = CGDisplayBounds(display).origin
            CGConfigureDisplayOrigin(config, display, Int32(clamping: Int(origin.x - target.x)), Int32(clamping: Int(origin.y - target.y)))
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }
}

/// Rotation through MonitorPanel's private `MPDisplay` (the class System Settings > Displays uses).
/// Looked up at runtime: if a macOS update removes it, the rotation menu just disappears.
enum DisplayRotation {
    private typealias InitWithID = @convention(c) (UnsafeRawPointer, Selector, Int32) -> UnsafeRawPointer?
    private typealias GetBool = @convention(c) (UnsafeRawPointer, Selector) -> Bool
    private typealias SetInt = @convention(c) (UnsafeRawPointer, Selector, Int32) -> Void

    private static let displayClass: NSObject.Type? = {
        dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY)
        return NSClassFromString("MPDisplay") as? NSObject.Type
    }()

    private static func mpDisplay(_ id: CGDirectDisplayID) -> NSObject? {
        let initSelector = NSSelectorFromString("initWithCGSDisplayID:")
        guard let cls = displayClass, cls.instancesRespond(to: initSelector),
              let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc")) else { return nil }
        // alloc returns +1 and init consumes it and returns +1, so ownership moves straight through.
        let pointer = allocated.toOpaque()
        let initialize = unsafeBitCast(cls.instanceMethod(for: initSelector), to: InitWithID.self)
        guard let result = initialize(pointer, initSelector, Int32(bitPattern: id)) else { return nil }
        return Unmanaged<NSObject>.fromOpaque(result).takeRetainedValue()
    }

    static func canRotate(_ id: CGDirectDisplayID) -> Bool {
        let selector = NSSelectorFromString("canChangeOrientation")
        guard let display = mpDisplay(id), display.responds(to: selector) else { return false }
        let call = unsafeBitCast(display.method(for: selector), to: GetBool.self)
        return call(Unmanaged.passUnretained(display).toOpaque(), selector)
    }

    @discardableResult
    static func set(_ id: CGDirectDisplayID, degrees: Int) -> Bool {
        let selector = NSSelectorFromString("setOrientation:")
        guard let display = mpDisplay(id), display.responds(to: selector) else { return false }
        let call = unsafeBitCast(display.method(for: selector), to: SetInt.self)
        guard [0, 90, 180, 270].contains(degrees) else { return false }
        call(Unmanaged.passUnretained(display).toOpaque(), selector, Int32(degrees))
        return true
    }
}

/// Keeps every active display reachable by the cursor. macOS only moves the pointer across a shared edge
/// segment; displays that touch only at a corner (or not at all) strand it. This can happen when displays
/// are turned back on or a preset restores an old layout.
enum ArrangementRepair {
    /// Smallest shared edge, in points, that counts as "connected". Tiny overlaps are hard to hit.
    static let minimumOverlap = 100
    /// Shared edge a repair aims for: wide enough to cross without aiming.
    static let repairOverlap = 400

    struct Box {
        let id: CGDirectDisplayID
        var x, y, w, h: Int
        var maxX: Int { x + w }
        var maxY: Int { y + h }
    }

    static func activeBoxes() -> [Box] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }.map {
            let b = CGDisplayBounds($0)
            return Box(id: $0, x: Int(b.minX), y: Int(b.minY), w: Int(b.width), h: Int(b.height))
        }
    }

    private static func overlap(_ a0: Int, _ a1: Int, _ b0: Int, _ b1: Int) -> Int { min(a1, b1) - max(a0, b0) }

    static func touching(_ a: Box, _ b: Box) -> Bool {
        let need = min(minimumOverlap, a.w, a.h, b.w, b.h)
        if a.maxX == b.x || b.maxX == a.x { return overlap(a.y, a.maxY, b.y, b.maxY) >= need }
        if a.maxY == b.y || b.maxY == a.y { return overlap(a.x, a.maxX, b.x, b.maxX) >= need }
        return false
    }

    private static func intersects(_ a: Box, _ b: Box) -> Bool {
        overlap(a.x, a.maxX, b.x, b.maxX) > 0 && overlap(a.y, a.maxY, b.y, b.maxY) > 0
    }

    /// Displays connected to `start` through shared edges.
    private static func component(of start: CGDirectDisplayID, in boxes: [Box]) -> Set<CGDirectDisplayID> {
        var seen: Set<CGDirectDisplayID> = [start]
        var queue = [start]
        while let id = queue.popLast() {
            guard let a = boxes.first(where: { $0.id == id }) else { continue }
            for b in boxes where !seen.contains(b.id) && touching(a, b) {
                seen.insert(b.id)
                queue.append(b.id)
            }
        }
        return seen
    }

    static func isConnected(_ boxes: [Box] = activeBoxes()) -> Bool {
        guard let first = boxes.first else { return true }
        return component(of: first.id, in: boxes).count == boxes.count
    }

    /// New positions that connect every display to the main display's group, moving as little as possible.
    /// A stranded group (e.g. Dell attached to the built-in) moves as one, so its own layout is kept.
    static func repairedBoxes(_ input: [Box], mainID: CGDirectDisplayID) -> [Box] {
        var boxes = input
        guard boxes.contains(where: { $0.id == mainID }) else { return boxes }
        for _ in 0..<boxes.count {
            let connected = component(of: mainID, in: boxes)
            guard let strandedID = boxes.first(where: { !connected.contains($0.id) })?.id else { break }
            let group = component(of: strandedID, in: boxes)

            // Try touching each side of each connected display with each display of the stranded group;
            // keep the smallest move that doesn't overlap anything.
            var best: (dx: Int, dy: Int, cost: Int)?
            for anchor in boxes where connected.contains(anchor.id) {
                for mover in boxes where group.contains(mover.id) {
                    let need = min(repairOverlap, mover.w, mover.h, anchor.w, anchor.h)
                    // Clamp the sliding coordinate so the shared edge is at least `need` long.
                    let ySlide = min(max(mover.y, anchor.y - mover.h + need), anchor.maxY - need)
                    let xSlide = min(max(mover.x, anchor.x - mover.w + need), anchor.maxX - need)
                    let targets = [
                        (anchor.maxX, ySlide),          // right of anchor
                        (anchor.x - mover.w, ySlide),   // left of anchor
                        (xSlide, anchor.maxY),          // below anchor
                        (xSlide, anchor.y - mover.h),   // above anchor
                    ]
                    for (tx, ty) in targets {
                        let dx = tx - mover.x, dy = ty - mover.y
                        let cost = abs(dx) + abs(dy)
                        if let b = best, b.cost <= cost { continue }
                        let moved = boxes.filter { group.contains($0.id) }.map { Box(id: $0.id, x: $0.x + dx, y: $0.y + dy, w: $0.w, h: $0.h) }
                        let others = boxes.filter { !group.contains($0.id) }
                        if moved.contains(where: { m in others.contains { intersects(m, $0) } }) { continue }
                        best = (dx, dy, cost)
                    }
                }
            }
            guard let move = best else { break }
            for i in boxes.indices where group.contains(boxes[i].id) {
                boxes[i].x += move.dx
                boxes[i].y += move.dy
            }
        }
        return boxes
    }

    /// Fixes the live layout if it's broken. Returns true if anything moved.
    @discardableResult
    static func repairIfNeeded() -> Bool {
        let boxes = activeBoxes()
        guard boxes.count > 1, !isConnected(boxes) else { return false }
        let mainID = CGMainDisplayID()
        let fixed = repairedBoxes(boxes, mainID: mainID)
        let changed = zip(boxes, fixed).filter { $0.x != $1.x || $0.y != $1.y }
        guard !changed.isEmpty else { return false }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        for (_, box) in changed {
            CGConfigureDisplayOrigin(config, box.id, Int32(clamping: box.x), Int32(clamping: box.y))
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }
}
