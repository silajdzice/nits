import AppKit
import SwiftUI

/// Renders MenuView into an off-screen window and saves it as a PNG. Read-only: it shows the real displays
/// but doesn't change anything.
enum Snapshot {
    static func render(to path: String, dark: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let manager = DisplayManager()
        // Let the DDC reads (async, ~50 ms each) land before drawing.
        RunLoop.main.run(until: Date().addingTimeInterval(10))
        if CommandLine.arguments.contains("demo-presets") {
            // Demo data for screenshots: the current setup as "Desk", plus a made-up "Gaming".
            manager.savePreset(named: "Desk")
            var gaming = manager.presets[0]
            gaming.id = UUID()
            gaming.name = "Gaming"
            for key in gaming.displays.keys { gaming.displays[key]?.refreshRate = 144 }
            manager.presets.append(gaming)
            manager.updateActivePreset()
        }

        let host = NSHostingView(rootView: MenuView(manager: manager)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds),
              case _ = host.cacheDisplay(in: host.bounds, to: rep),
              let png = rep.representation(using: .png, properties: [:]) else {
            fputs("Couldn't render the menu\n", stderr)
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            fputs("Couldn't write \(path): \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        print("Wrote \(path) (\(Int(size.width))×\(Int(size.height)) pt)")
    }
}
