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
///
/// MonitorPanel is expensive: its shared display manager builds a mode table for every display with an
/// all-pairs comparison (about 20 s and 700 MB on a 4K/160 Hz monitor), and once loaded it redoes that
/// on the main thread after every display change. So the menu bar app never loads it. Rotation runs in
/// a short-lived helper process (this same binary with `--rotate`), which exits afterwards.
enum DisplayRotation {
    /// Built-in panels can't be rotated; external displays generally can. Checked without MonitorPanel.
    static func canRotate(_ id: CGDirectDisplayID) -> Bool { CGDisplayIsBuiltin(id) == 0 }

    static func isValid(_ degrees: Int) -> Bool { [0, 90, 180, 270].contains(degrees) }

    /// Rotates in the helper process; `done(true)` on the main thread once the helper reports success.
    static func set(_ id: CGDirectDisplayID, degrees: Int, done: @escaping (Bool) -> Void) {
        guard isValid(degrees), let executable = Bundle.main.executableURL else { return done(false) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--rotate", String(id), String(degrees)]
        process.terminationHandler = { finished in
            let ok = finished.terminationReason == .exit && finished.terminationStatus == 0
            DispatchQueue.main.async { done(ok) }
        }
        do {
            try process.run()
        } catch {
            done(false)
            return
        }
        // Never wait forever on the helper.
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            if process.isRunning { process.terminate() }
        }
    }

    @MainActor
    static func set(_ id: CGDirectDisplayID, degrees: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            set(id, degrees: degrees) { continuation.resume(returning: $0) }
        }
    }

    /// Helper-process entry point (`Nits --rotate <id> <degrees>`). Returns the exit code.
    static func runHelper(_ arguments: [String]) -> Int32 {
        guard arguments.count == 2, let id = UInt32(arguments[0]), let degrees = Int(arguments[1]), isValid(degrees) else { return 2 }
        return Panel.setOrientation(CGDirectDisplayID(id), degrees: degrees) ? 0 : 1
    }

    /// Direct MonitorPanel access. Only ever used inside the helper process.
    private enum Panel {
        typealias InitWithID = @convention(c) (UnsafeRawPointer, Selector, Int32) -> UnsafeRawPointer?
        typealias SetInt = @convention(c) (UnsafeRawPointer, Selector, Int32) -> Void

        static func setOrientation(_ id: CGDirectDisplayID, degrees: Int) -> Bool {
            dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY)
            let initSelector = NSSelectorFromString("initWithCGSDisplayID:")
            let setSelector = NSSelectorFromString("setOrientation:")
            guard let cls = NSClassFromString("MPDisplay") as? NSObject.Type, cls.instancesRespond(to: initSelector),
                  let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc")) else { return false }
            // alloc returns +1 and init consumes it and returns +1, so ownership moves straight through.
            let initialize = unsafeBitCast(cls.instanceMethod(for: initSelector), to: InitWithID.self)
            guard let result = initialize(allocated.toOpaque(), initSelector, Int32(bitPattern: id)) else { return false }
            let display = Unmanaged<NSObject>.fromOpaque(result).takeRetainedValue()
            guard display.responds(to: setSelector) else { return false }
            let call = unsafeBitCast(display.method(for: setSelector), to: SetInt.self)
            call(Unmanaged.passUnretained(display).toOpaque(), setSelector, Int32(degrees))
            return true
        }
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
