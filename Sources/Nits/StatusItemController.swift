import AppKit
import SwiftUI

/// Menu bar icon plus an NSPopover for the menu.
///
/// SwiftUI's MenuBarExtra(.window) re-centres its window when the content height changes (expanding a
/// card, a display turning on), so the panel drifted away from the icon. An NSPopover stays attached to
/// the status item and grows downward from it.
final class StatusItemController: NSObject, NSPopoverDelegate {
    private var item: NSStatusItem
    private let popover = NSPopover()
    private let manager: DisplayManager
    private let context = PopoverContext()

    init(manager: DisplayManager) {
        self.manager = manager
        item = Self.makeItem()
        super.init()
        configure(item)

        let host = NSHostingController(rootView: PopoverRoot(manager: manager, context: context))
        // Popover size follows the SwiftUI content as it grows and shrinks.
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        // A popover that was open on a screen that just disappeared can be left "shown" with its window
        // gone, and then the icon looks dead. Close it whenever the screens change.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let screen = self.popover.contentViewController?.view.window?.screen
            let screenGone = screen.map { s in !NSScreen.screens.contains { $0 == s } } ?? true
            Log.menu.notice("Screens changed; popover shown=\(self.popover.isShown, privacy: .public) screenGone=\(screenGone, privacy: .public)")
            // Only when its screen is gone: Nits' own changes (main display, layout repair) shouldn't close it.
            if self.popover.isShown && screenGone { self.popover.close() }
        }
    }

    private static func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "NitsStatusItem"   // keeps a position the user ⌘-dragged it to across rebuilds
        return item
    }

    private func configure(_ item: NSStatusItem) {
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Nits")
        button.target = self
        button.action = #selector(toggle(_:))
    }

    /// A fresh status item, for when the old one's button stopped hosting the popover.
    private func rebuildItem() {
        Log.menu.error("Rebuilding the status item")
        NSStatusBar.system.removeStatusItem(item)
        item = Self.makeItem()
        configure(item)
    }

    private var popoverVisible: Bool {
        popover.isShown && popover.contentViewController?.view.window?.isVisible == true
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popoverVisible {
            popover.performClose(sender)
            return
        }
        if popover.isShown {
            // Stale "shown" state from a screen change: reset before showing again.
            Log.menu.notice("Popover marked shown but not visible; closing it first")
            popover.close()
        }
        // The display list is kept current by reconfiguration callbacks; only re-read monitor values here.
        manager.refreshMonitorValues()
        show(from: sender, retry: true)
    }

    private func show(from button: NSStatusBarButton, retry: Bool) {
        // Cap the height by the screen whose menu bar was clicked, fixed for as long as the menu is open.
        let screen = button.window?.screen ?? NSScreen.main
        context.maxHeight = max(300, (screen?.visibleFrame.height ?? 900) - 40)
        Log.menu.info("Show: button window=\(button.window != nil, privacy: .public) screen=\(button.window?.screen?.localizedName ?? "none", privacy: .public)")
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        // If the popover didn't appear, the button is no longer usable as an anchor: rebuild and retry once.
        DispatchQueue.main.async { [weak self] in
            guard let self, retry, !self.popoverVisible else { return }
            Log.menu.error("Popover failed to appear (shown=\(self.popover.isShown, privacy: .public))")
            self.popover.close()
            self.rebuildItem()
            if let fresh = self.item.button { self.show(from: fresh, retry: false) }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        Log.menu.info("Popover closed")
    }
}

/// Scrolls only when the menu is taller than the screen (three cards expanded on a laptop screen).
/// The content's natural height is measured and the popover sized to min(content, screen), so it never
/// has to guess between two layouts.
final class PopoverContext: ObservableObject {
    @Published var maxHeight: CGFloat = 800
}

private struct PopoverRoot: View {
    @ObservedObject var manager: DisplayManager
    @ObservedObject var context: PopoverContext
    @State private var contentHeight: CGFloat = 400

    private var maxHeight: CGFloat { context.maxHeight }

    var body: some View {
        ScrollView(.vertical) {
            MenuView(manager: manager)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: HeightKey.self, value: geo.size.height)
                })
        }
        .scrollDisabled(contentHeight <= maxHeight)
        .scrollIndicators(.automatic)
        .frame(height: min(contentHeight, maxHeight))
        .onPreferenceChange(HeightKey.self) { height in
            // Ignore sub-point changes: re-sizing the popover for them can feed back into layout.
            if abs(height - contentHeight) >= 1 { contentHeight = height }
        }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
