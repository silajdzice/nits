import Foundation

/// Pure mode-picking logic, kept free of CoreGraphics so it can be unit tested.
enum ModeLogic {
    struct Mode: Equatable {
        let id: Int32
        let width: Int        // points
        let height: Int
        let pixelWidth: Int
        let refreshRate: Double
        var isHiDPI: Bool { pixelWidth > width }
    }

    /// Up to six one-click choices, like the thumbnails in System Settings, spread from largest text to
    /// most space, always including the current mode.
    ///
    /// The pool is the same kind as the current mode: HiDPI choices for a HiDPI desktop, plain ones for a
    /// non-Retina desktop (where the few HiDPI modes are tiny, e.g. 540×960). Only modes with the shape
    /// of the largest plain mode are offered. That mode is taken from the list itself, so a rotated
    /// (portrait) display compares portrait with portrait.
    static func suggestions(from modes: [Mode], current: Mode?) -> [Mode] {
        let hiDPI = modes.filter(\.isHiDPI)
        let plain = modes.filter { !$0.isHiDPI }
        let wantHiDPI = current?.isHiDPI ?? true
        let pool = wantHiDPI ? (hiDPI.count >= 2 ? hiDPI : plain) : (plain.count >= 2 ? plain : hiDPI)

        let reference = plain.max { $0.width * $0.height < $1.width * $1.height }
        let sameShape = pool.filter { mode in
            guard let reference, reference.height > 0, mode.height > 0 else { return true }
            return abs(Double(mode.width) / Double(mode.height) - Double(reference.width) / Double(reference.height)) < 0.02
        }
        let candidates = (sameShape.count >= 2 ? sameShape : pool).sorted { $0.width < $1.width }
        let count = min(6, candidates.count)
        guard count > 0 else { return current.map { [$0] } ?? [] }

        var picked = (0..<count).map { i in
            candidates[count == 1 ? 0 : i * (candidates.count - 1) / (count - 1)]
        }
        if let current, !picked.contains(where: { $0.id == current.id }) {
            // Swap out the pick closest in width so the current mode is always one click away.
            if let nearest = picked.indices.min(by: { abs(picked[$0].width - current.width) < abs(picked[$1].width - current.width) }) {
                picked[nearest] = current
            }
        }
        var seen = Set<Int32>()
        return picked.filter { seen.insert($0.id).inserted }.sorted { $0.width < $1.width }
    }

    /// One entry per distinct refresh rate, fastest first. 59.94 and 60 stay separate (they are different
    /// timings); within a rate the current mode wins, so the menu can always check it.
    static func refreshVariants(of modes: [Mode], current: Mode?) -> [Mode] {
        var byRate: [Int: Mode] = [:]
        for mode in modes {
            let key = Int((mode.refreshRate * 100).rounded())   // hundredths of a hertz
            if mode.id == current?.id || byRate[key] == nil { byRate[key] = mode }
        }
        return byRate.values.sorted { $0.refreshRate > $1.refreshRate }
    }

    /// "60 Hz", "59.94 Hz".
    static func hzLabel(_ rate: Double) -> String {
        abs(rate - rate.rounded()) < 0.01 ? "\(Int(rate.rounded())) Hz" : String(format: "%.2f Hz", rate)
    }
}
