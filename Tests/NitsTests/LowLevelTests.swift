import CoreGraphics
import Foundation
import Testing
@testable import Nits

@Suite struct HiDPIOverrideTests {
    @Test func entriesCoverRangeAtNativeAspect() {
        let entries = HiDPIOverride.entries(nativeWidth: 2560, nativeHeight: 1440)
        let decoded = entries.map { data in
            stride(from: 0, to: data.count, by: 4).map { i in
                data[data.startIndex + i ..< data.startIndex + i + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            }
        }
        #expect(decoded.first?.prefix(2) == [1280, 720])
        #expect(decoded.contains { Array($0) == [5120, 2880, 9, 0x0020_0000] })     // 2x native, flagged
        #expect(decoded.allSatisfy { $0[0] * 1440 / 2560 == $0[1] })                // native aspect
        #expect(decoded.allSatisfy { $0.count == 2 || $0.count == 4 })
    }

    @Test func pathUsesHexIDs() {
        #expect(HiDPIOverride.path(vendor: 0x10AC, model: 0x41DE)
                == "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-10ac/DisplayProductID-41de")
    }
}

@Suite struct DDCTests {
    /// Known-good "set brightness to 50" packet: 84 03 10 00 32 + checksum.
    @Test func checksumMatchesSpec() {
        let packet: [UInt8] = [0x84, 0x03, 0x10, 0x00, 0x32]
        #expect(DDCService.checksum(packet[...]) == 0x9A)   // 6E^51^84^03^10^00^32
    }
}

@Suite struct PrivilegedCommandTests {
    let dest = HiDPIOverride.path(vendor: 0x10AC, model: 0x41DE)

    @Test func onlyOverridePathsAreAccepted() {
        #expect(HiDPIOverride.isValidOverridePath(dest))
        for bad in [
            "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-10ac/../../../../etc/sudoers",
            "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-10ac/DisplayProductID-41de'; rm -rf /",
            "/etc/hosts",
            dest + "/x",
        ] {
            #expect(!HiDPIOverride.isValidOverridePath(bad))
            #expect(throws: (any Error).self) { try HiDPIOverride.installCommand(dest: bad, plist: Data()) }
            #expect(throws: (any Error).self) { try HiDPIOverride.removeCommand(dest: bad) }
        }
    }

    @Test func installCommandIsSafeAndCarriesThePlistInline() throws {
        let plist = Data("<plist>'\"$(reboot)`;</plist>".utf8)   // hostile bytes must stay inside base64
        let command = try HiDPIOverride.installCommand(dest: dest, plist: plist)
        #expect(HiDPIOverride.isSafeCommand(command))
        #expect(command.contains(plist.base64EncodedString()))
        #expect(!command.contains("reboot"))
        #expect(!command.contains("/tmp") && !command.contains("TemporaryItems"))   // no user-writable temp file
        #expect(command.hasPrefix("set -e"))
    }

    @Test func unsafeCharactersAreRejected() {
        for bad in ["rm -rf ~", "a`b`", "a\"b", "a\\b", "a\nb", "a&b", "a<b", "a{b}", "é", "$(id)", "${HOME}", "a*b", "a?b"] {
            #expect(!HiDPIOverride.isSafeCommand(bad))
        }
    }
}

@Suite struct PrivilegedCommandShellTests {
    /// Runs the real install command with /bin/sh, but redirected into a temp folder and without the
    /// root-only chown, to prove the shell actually writes the exact plist bytes.
    @Test func commandWritesExactPlistAndRefusesSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nits-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = HiDPIOverride.path(vendor: 0x10AC, model: 0x41DE)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["DisplayVendorID": 4268], format: .xml, options: 0)

        func run(_ command: String) -> Int32 {
            let sandboxed = command
                .replacingOccurrences(of: "/Library/Displays", with: root.path + "/Library/Displays")
                .replacingOccurrences(of: "/usr/sbin/chown root:wheel", with: "/usr/bin/true")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", sandboxed]
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }

        #expect(run(try HiDPIOverride.installCommand(dest: dest, plist: plist)) == 0)
        let written = root.path + dest
        #expect(FileManager.default.contents(atPath: written) == plist)
        #expect(!FileManager.default.fileExists(atPath: (written as NSString).deletingLastPathComponent + "/.nits-incoming.plist"))

        // Replace the destination with a symlink: the command must refuse and leave the link's target alone.
        let target = root.appendingPathComponent("victim").path
        FileManager.default.createFile(atPath: target, contents: Data("keep".utf8))
        try FileManager.default.removeItem(atPath: written)
        try FileManager.default.createSymbolicLink(atPath: written, withDestinationPath: target)
        #expect(run(try HiDPIOverride.installCommand(dest: dest, plist: plist)) != 0)
        #expect(FileManager.default.contents(atPath: target) == Data("keep".utf8))
    }
}

@Suite struct DDCParsingTests {
    /// A valid "brightness 58 of 100" reply, checksum computed from the spec.
    private func reply(vcp: UInt8 = 0x10, max: UInt16 = 100, current: UInt16 = 58, result: UInt8 = 0) -> [UInt8] {
        var r: [UInt8] = [0x6E, 0x88, 0x02, result, vcp, 0x00, UInt8(max >> 8), UInt8(max & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF)]
        r.append(r.reduce(UInt8(0x50), ^))
        return r
    }

    @Test func acceptsValidReply() {
        #expect(DDCService.parseReply(reply(), vcp: 0x10).map { [$0.current, $0.max] } == [58, 100])
    }

    @Test func rejectsCorruptOrNonsenseReplies() {
        var bad = reply(); bad[10] ^= 0xFF
        #expect(DDCService.parseReply(bad, vcp: 0x10) == nil)                                   // checksum
        #expect(DDCService.parseReply(reply(result: 1), vcp: 0x10) == nil)                      // monitor error
        #expect(DDCService.parseReply(reply(vcp: 0x12), vcp: 0x10) == nil)                      // other control
        #expect(DDCService.parseReply(reply(max: 100, current: 400), vcp: 0x10) == nil)         // above max
        #expect(DDCService.parseReply(Array(reply().prefix(5)), vcp: 0x10) == nil)              // truncated
        #expect(DDCService.parseReply(reply(vcp: 0x60, max: 3, current: 17), vcp: 0x60) != nil) // input codes are fine
    }

    @Test func percentConversionNeverTraps() {
        #expect(DisplayController.raw(-20, max: 100) == 0)
        #expect(DisplayController.raw(5000, max: 100) == 100)
        #expect(DisplayController.raw(.nan, max: 100) == 50)
        #expect(DisplayController.raw(50, max: 65535) == 32768)
    }
}

@Suite struct DDCAssignmentTests {
    typealias D = (id: CGDirectDisplayID, vendor: UInt32, model: UInt32, serial: UInt32)
    typealias S = (vendor: UInt32, product: UInt32, serial: UInt32)

    @Test func eachServiceGoesToOneDisplay() {
        // Two identical monitors with serial 0, two services.
        let displays: [D] = [(id: 5, vendor: 1, model: 2, serial: 0), (id: 3, vendor: 1, model: 2, serial: 0)]
        let services: [S] = [(vendor: 1, product: 2, serial: 0), (vendor: 1, product: 2, serial: 0)]
        let pairs = DDCService.assign(displays: displays, services: services)
        #expect(pairs.count == 2 && Set(pairs.values) == [0, 1])
    }

    @Test func singleServiceIsNotSharedWithAnUnrelatedScreen() {
        // A Dell with DDC plus a screen that has none (Sidecar, AirPlay, DisplayLink).
        let displays: [D] = [(id: 3, vendor: 4268, model: 16862, serial: 9), (id: 7, vendor: 1552, model: 999, serial: 0)]
        let pairs = DDCService.assign(displays: displays, services: [(vendor: 4268, product: 16862, serial: 9)])
        #expect(pairs == [3: 0])
    }

    @Test func exactSerialWinsOverOrder() {
        let displays: [D] = [(id: 1, vendor: 1, model: 2, serial: 111), (id: 2, vendor: 1, model: 2, serial: 222)]
        let services: [S] = [(vendor: 1, product: 2, serial: 222), (vendor: 1, product: 2, serial: 111)]
        #expect(DDCService.assign(displays: displays, services: services) == [1: 1, 2: 0])
    }

    @Test func loneDisplayWithOddEDIDStillGetsTheOnlyService() {
        let pairs = DDCService.assign(displays: [(id: 4, vendor: 9, model: 9, serial: 0)], services: [(vendor: 0, product: 0, serial: 0)])
        #expect(pairs == [4: 0])
    }
}

@Suite struct RevertLockTests {
    @Test @MainActor func onlyOneChangeAtATime() {
        #expect(RevertPrompt.begin())
        #expect(!RevertPrompt.begin())
        RevertPrompt.end()
        #expect(RevertPrompt.begin())
        RevertPrompt.end()
    }
}
