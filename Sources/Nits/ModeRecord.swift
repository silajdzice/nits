import CoreGraphics
import Foundation

/// A display mode reduced to what identifies it across reconnects (mode IDs can change).
struct ModeRecord: Codable, Equatable {
    var width: Int        // points
    var height: Int
    var pixelWidth: Int
    var refreshRate: Int  // hundredths of a hertz, so 59.94 and 60 stay distinct

    init(width: Int, height: Int, pixelWidth: Int, refreshRate: Int) {
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.refreshRate = refreshRate
    }

    init(_ mode: CGDisplayMode) {
        self.init(width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                  refreshRate: Int((mode.refreshRate * 100).rounded()))
    }

    /// The display's mode with these values, if it still offers one.
    func find(on id: CGDirectDisplayID) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []).filter { $0.isUsableForDesktopGUI() }
        return all.first { ModeRecord($0) == self }
    }

    private static let key = "rememberedModes.v1"

    static func load() -> [String: ModeRecord] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: ModeRecord].self, from: data)) ?? [:]
    }

    static func save(_ records: [String: ModeRecord]) {
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: key) }
    }
}
