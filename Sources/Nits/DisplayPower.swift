import CoreGraphics
import Foundation

/// Turns a display off without unplugging it, via the private SkyLight call `SLSConfigureDisplayEnabled`.
/// An "off" display leaves the desktop entirely (its windows move to the others). Session-only:
/// logging out or rebooting turns it back on, so a mistake can't outlive the session.
enum DisplayPower {
    private typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

    /// Looked up at runtime so a future macOS that drops the symbol disables this feature instead of the app.
    private static let configureEnabled: ConfigureEnabled? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, "SLSConfigureDisplayEnabled") else { return nil }
        return unsafeBitCast(symbol, to: ConfigureEnabled.self)
    }()

    static var isAvailable: Bool { configureEnabled != nil }

    static func activeCount() -> Int {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        return Int(count)
    }

    /// Active displays that show their own desktop (mirrors of another display don't count).
    static func desktopCount() -> Int {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }.count
    }

    @discardableResult
    static func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> Bool {
        guard let configureEnabled else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard configureEnabled(config, id, enabled) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }
}
