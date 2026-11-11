import AppKit
import SwiftUI

/// Control Center–style slider: a fat capsule that fills with the accent colour,
/// icon on the left, percentage on the right. Drag or click anywhere on it.
struct PillSlider: View {
    let title: String
    let systemImage: String
    let value: Double
    let range: ClosedRange<Double>
    let set: (Double) -> Void
    var tint: Color = .accentColor

    @State private var dragging = false

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule()
                    .fill(tint.gradient)
                    // Never narrower than the capsule's height, so 0% still shows a round knob behind the icon.
                    .frame(width: max(geo.size.height, geo.size.width * fraction))
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(fraction > 0.04 ? .white : .secondary)
                        .frame(width: geo.size.height)
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(fraction > 0.3 ? .white.opacity(0.9) : .secondary)
                    Spacer()
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 10)
                }
            }
            .clipShape(Capsule())
            .scaleEffect(dragging ? 1.02 : 1)
            .animation(.spring(duration: 0.2), value: dragging)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        let f = min(max(drag.location.x / geo.size.width, 0), 1)
                        set(range.lowerBound + f * (range.upperBound - range.lowerBound))
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: 26)
        .help(title)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 10
            set(min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound))
        }
    }
}

/// Small rounded "pill" used for resolution choices.
struct Chip: View {
    let title: String
    let selected: Bool
    /// Small orange dot: something about this choice needs attention (see its tooltip).
    var warning = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular).monospacedDigit())
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) {
                    if warning {
                        Circle().fill(.orange).frame(width: 6, height: 6).padding(4)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? AnyShapeStyle(Color.accentColor.gradient)
                              : AnyShapeStyle(.primary.opacity(hovering ? 0.12 : 0.06)))
                )
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Compact menu that looks like a chip: icon + value + chevron.
struct ChipMenu<Content: View>: View {
    let systemImage: String
    let title: String
    let help: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Label(title, systemImage: systemImage)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help(help)
    }
}

/// Tiny capsule label: "HiDPI", "Main", "160 Hz".
struct Badge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
            .foregroundStyle(tint)
    }
}

/// Round icon-only button used in card headers and the footer.
struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Small modal text prompt (the menu bar window can't host sheets).
enum NamePrompt {
    static func ask(title: String, message: String?, defaultName: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultName
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(24))
    }
}
