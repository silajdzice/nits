import AppKit
import CoreGraphics
import SwiftUI

struct NitsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // The menu lives in an NSPopover owned by the delegate (see StatusItemController); an App needs a scene.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var termSource: DispatchSourceSignal?
    private var statusItem: StatusItemController?

    /// `kill`/`pkill` sends SIGTERM, which skips normal quitting, so displays Nits turned off would stay
    /// dark. Route it through a normal quit so they're turned back on first.
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source
        Migration.run()
        statusItem = StatusItemController(manager: DisplayManager())
    }

    func applicationWillTerminate(_ notification: Notification) {
        CGDisplayRestoreColorSyncSettings()
    }
}

// `Nits --dump` prints what the app sees, without touching any display.
if CommandLine.arguments.contains("--dump") {
    Diagnostics.dump()
    exit(0)
}
// `Nits --snapshot out.png [light|dark]` renders the menu to a PNG (for README screenshots and UI review).
if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
    guard i + 1 < CommandLine.arguments.count else {
        fputs("usage: Nits --snapshot <out.png> [light|dark]\n", stderr)
        exit(2)
    }
    let dark = CommandLine.arguments.contains("dark")
    Snapshot.render(to: CommandLine.arguments[i + 1], dark: dark)
    exit(0)
}
NitsApp.main()
