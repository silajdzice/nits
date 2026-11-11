import Foundation

/// One-time move from the app's previous name (Lumen, `com.edhem.lumen`): presets, the list of
/// turned-off displays, collapsed cards, and HiDPI override backups. Runs before anything reads settings.
enum Migration {
    private static let doneKey = "migratedFromLumen"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        if let old = UserDefaults(suiteName: "com.edhem.lumen") {
            for key in ["presets.v1", "offDisplays.v1", "collapsedDisplays"] where defaults.object(forKey: key) == nil {
                if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldBackups = support.appendingPathComponent("Lumen/Backups", isDirectory: true)
        let newBackups = HiDPIOverride.backupDirectory
        if FileManager.default.fileExists(atPath: oldBackups.path), !FileManager.default.fileExists(atPath: newBackups.path) {
            try? FileManager.default.createDirectory(at: newBackups.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: oldBackups, to: newBackups)   // copy, never delete the originals
        }
    }
}
