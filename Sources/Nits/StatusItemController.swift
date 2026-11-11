import AppKit
import SwiftUI

/// Menu bar icon plus an NSPopover for the menu.
///
/// SwiftUI's MenuBarExtra(.window) re-centres its window when the content height changes (expanding a
/// card, a display turning on), so the panel drifted away from the icon. An NSPopover stays attached to
/// the status item and grows downward from it.
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let manager: DisplayManager

    init(manager: DisplayManager) {
        self.manager = manager
        super.init()

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Nits")
            button.target = self
            button.action = #selector(toggle(_:))
        }

        let host = NSHostingController(rootView: PopoverRoot(manager: manager))
        // Popover size follows the SwiftUI content as it grows and shrinks.
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            manager.refresh()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

/// Scrolls only when the menu is taller than the screen (three cards expanded on a laptop screen).
/// The content's natural height is measured and the popover sized to min(content, screen), so it never
/// has to guess between two layouts.
private struct PopoverRoot: View {
    @ObservedObject var manager: DisplayManager
    @State private var contentHeight: CGFloat = 400

    private var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) - 40
    }

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
        .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
