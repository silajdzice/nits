import Foundation

/// HiDPI on a non-Retina monitor via a display override plist.
///
/// macOS reads `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<hex>/DisplayProductID-<hex>`
/// when a display connects. Its `scale-resolutions` array lists extra framebuffer sizes; macOS offers each
/// one as a HiDPI mode at half that size in points. No virtual display, no mirroring, no app needs to keep
/// running: the modes become real modes of the monitor. Changes load on the next reconnect (replug or log out).
enum HiDPIOverride {
    static let root = "/Library/Displays/Contents/Resources/Overrides"

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func path(vendor: UInt32, model: UInt32) -> String {
        root + String(format: "/DisplayVendorID-%x/DisplayProductID-%x", vendor, model)
    }

    static func isInstalled(vendor: UInt32, model: UInt32) -> Bool {
        FileManager.default.fileExists(atPath: path(vendor: vendor, model: model))
    }

    /// Framebuffer sizes from 1280 px wide up to 2x native at the native aspect: 16 px steps below native,
    /// 32 px steps above. Sizes at or above native also get the scaled-mode flags (9, 0x200000).
    /// Layout verified on a 2560×1440 panel under macOS 26/27.
    static func entries(nativeWidth: Int, nativeHeight: Int) -> [Data] {
        let start = min(1280, nativeWidth)
        let widths = Array(stride(from: start, to: nativeWidth, by: 16)) + Array(stride(from: nativeWidth, through: nativeWidth * 2, by: 32))
        var result: [Data] = []
        for width in widths {
            let height = width * nativeHeight / nativeWidth
            result.append(pack([UInt32(width), UInt32(height)]))
            if width >= nativeWidth {
                result.append(pack([UInt32(width), UInt32(height), 9, 0x0020_0000]))
            }
        }
        return result
    }

    private static func pack(_ values: [UInt32]) -> Data {
        values.reduce(into: Data()) { data, value in
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
    }

    static func installedEntries(vendor: UInt32, model: UInt32) -> [Data] {
        guard let dict = readPlist(path(vendor: vendor, model: model)) else { return [] }
        return dict["scale-resolutions"] as? [Data] ?? []
    }

    /// Writes the override, keeping any other keys an existing file has (EDID patches etc.).
    ///
    /// Security: this is the only code that runs as root. The plist travels *inside* the command as base64,
    /// not through a temp file, so no other process can swap the file between "Nits wrote it" and "root
    /// copied it". Root writes it to a fresh temp file next to the destination and renames it into place,
    /// so a reader never sees a half-written file. Every value in the command is checked against a strict
    /// character set before anything runs.
    static func install(vendor: UInt32, model: UInt32, nativeWidth: Int, nativeHeight: Int) throws {
        let dest = path(vendor: vendor, model: model)
        var dict = readPlist(dest) ?? [:]
        dict["DisplayVendorID"] = vendor
        dict["DisplayProductID"] = model
        dict["scale-resolutions"] = entries(nativeWidth: nativeWidth, nativeHeight: nativeHeight)

        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try backup(dest)
        try runPrivileged(installCommand(dest: dest, plist: data))
    }

    /// Removes Nits' modes. If the file holds other settings (an EDID patch, another tool's keys),
    /// only `scale-resolutions` is dropped and the rest is kept.
    static func remove(vendor: UInt32, model: UInt32) throws {
        let dest = path(vendor: vendor, model: model)
        try backup(dest)
        var dict = readPlist(dest) ?? [:]
        dict["scale-resolutions"] = nil
        let ownKeys: Set<String> = ["DisplayVendorID", "DisplayProductID"]
        if Set(dict.keys).isSubset(of: ownKeys) {
            try runPrivileged(removeCommand(dest: dest))
        } else {
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try runPrivileged(installCommand(dest: dest, plist: data))
        }
    }

    // MARK: Root commands (pure, unit tested)

    /// /Library/Displays/.../DisplayVendorID-<hex>/DisplayProductID-<hex>, nothing else.
    static func isValidOverridePath(_ path: String) -> Bool {
        path.range(of: #"^/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-[0-9a-f]{1,8}/DisplayProductID-[0-9a-f]{1,8}$"#,
                   options: .regularExpression) != nil
    }

    static func installCommand(dest: String, plist: Data) throws -> String {
        guard isValidOverridePath(dest) else { throw Failure(errorDescription: "Refusing to write \(dest)") }
        let dir = (dest as NSString).deletingLastPathComponent
        let payload = plist.base64EncodedString()   // [A-Za-z0-9+/=] only
        // set -e: stop at the first failure. umask 022: files come out world-readable, root-writable.
        // `test ! -L`: refuse symlinks at the folder or destination, so root never writes through a link.
        // The temp file sits in the root-owned destination folder (no other user can touch it) and `mv`
        // replaces the old file atomically. No variables, no command substitution, no double quotes.
        let tmp = dir + "/.nits-incoming.plist"
        return [
            "set -e",
            "umask 022",
            "/bin/mkdir -p '\(dir)'",
            "/bin/test ! -L '\(dir)'",
            "/bin/test ! -L '\(dest)'",
            "/bin/rm -f '\(tmp)'",
            "echo '\(payload)' | /usr/bin/base64 -D > '\(tmp)'",
            "/usr/bin/plutil -lint -s '\(tmp)'",
            "/usr/sbin/chown root:wheel '\(tmp)'",
            "/bin/chmod 644 '\(tmp)'",
            "/bin/mv -f '\(tmp)' '\(dest)'",
        ].joined(separator: "; ")
    }

    static func removeCommand(dest: String) throws -> String {
        guard isValidOverridePath(dest) else { throw Failure(errorDescription: "Refusing to remove \(dest)") }
        return "/bin/rm -f '\(dest)'"
    }

    /// Characters a root command built above can contain. Anything else means a bug or tampering.
    static func isSafeCommand(_ command: String) -> Bool {
        command.unicodeScalars.allSatisfy { c in
            (c.isASCII && CharacterSet.alphanumerics.contains(c)) || "/-_.+=' ;:!|>".unicodeScalars.contains(c)
        }
    }

    static var backupDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nits/Backups", isDirectory: true)
    }

    /// Override files are world-readable, so the backup needs no admin rights.
    private static func backup(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let parts = path.split(separator: "/").suffix(2).joined(separator: "_")
        let unique = UUID().uuidString.prefix(8)   // two changes within one second must not collide
        try FileManager.default.copyItem(atPath: path, toPath: backupDirectory.appendingPathComponent("\(stamp)_\(unique)_\(parts).plist").path)
    }

    private static func readPlist(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// Runs a shell command as root through the standard macOS admin password dialog.
    private static func runPrivileged(_ command: String) throws {
        guard isSafeCommand(command) else { throw Failure(errorDescription: "Refusing to run an unexpected admin command.") }
        // AppleScript string literal: escape backslashes, then double quotes.
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        guard let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges") else {
            throw Failure(errorDescription: "Couldn't prepare the admin command.")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            throw Failure(errorDescription: error[NSAppleScript.errorMessage] as? String ?? "Admin command failed")
        }
    }
}
