import Foundation

/// Read-only report used to check the app against real hardware from the terminal.
enum Diagnostics {
    static func dump() {
        let services = DDCService.all()
        print("Display power control available: \(DisplayPower.isAvailable), active displays: \(DisplayPower.activeCount())")
        print("DDC services:\(services.map { "vendor=\($0.vendor) product=\($0.product) serial=\($0.serial)" })")

        let ids = DisplayInfo.onlineIDs()
        let ddc = DisplayManager.matchDDC(ids, services)
        for id in ids {
            let display = DisplayController(id: id, ddc: ddc[id], loadDDC: false)
            print("\n\(display.name)  id=\(id) vendor=\(display.vendor) model=\(display.model) serial=\(display.serial)")
            if let mode = display.currentMode {
                print("  current: \(mode.label) px=\(mode.pixelWidth)x\(mode.pixelHeight) hidpi=\(mode.isHiDPI)")
            }
            print("  modes: \(display.hiDPIModes.count) HiDPI, \(display.lowResolutionModes.count) low-res, refresh rates: \(display.refreshRates.map { Int($0.refreshRate.rounded()) })")
            print("  main=\(display.isMain) rotation=\(display.rotation) canRotate=\(display.canRotate)")

            if let native = DisplayInfo.nativePixelSize(id) {
                let generated = HiDPIOverride.entries(nativeWidth: native.width, nativeHeight: native.height)
                let installed = HiDPIOverride.installedEntries(vendor: display.vendor, model: display.model)
                print("  native: \(native.width)x\(native.height)")
                print("  override: installed=\(display.overrideInstalled) entries=\(installed.count) generated=\(generated.count) sameSet=\(Set(generated) == Set(installed))")
            }

            guard let ddc = display.ddc else {
                print("  ddc: no matching service")
                continue
            }
            DDCService.queue.sync {
                for vcp in [DDCService.VCP.brightness, .contrast, .volume, .input] {
                    if let value = ddc.read(vcp) {
                        print("  ddc \(vcp): \(value.current)/\(value.max)")
                    } else {
                        print("  ddc \(vcp): no reply")
                    }
                }
            }
        }
    }
}
