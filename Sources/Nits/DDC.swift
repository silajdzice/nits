import CoreGraphics
import Foundation
import IOKit

/// Apple Silicon's private I²C transport, looked up while the app runs. If a macOS update removes it,
/// DDC controls disappear and the rest of Nits keeps working (a link-time reference would stop launch).
private enum AVService {
    typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    static let create = symbol("IOAVServiceCreateWithService", as: Create.self)
    static let readI2C = symbol("IOAVServiceReadI2C", as: Transfer.self)
    static let writeI2C = symbol("IOAVServiceWriteI2C", as: Transfer.self)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
}

/// DDC/CI: the monitor's own settings (brightness, contrast...) controlled over the video cable's I2C bus.
/// On Apple Silicon the bus is reached through the private IOAVService API on a `DCPAVServiceProxy`.
final class DDCService {
    enum VCP: UInt8 {
        case brightness = 0x10
        case contrast = 0x12
        case input = 0x60
        case volume = 0x62
    }

    /// MCCS input source codes. Monitors implement a subset; Dell uses 0x1B for USB-C.
    static let inputs: [(name: String, code: UInt16)] = [
        ("DisplayPort 1", 0x0F), ("DisplayPort 2", 0x10),
        ("HDMI 1", 0x11), ("HDMI 2", 0x12),
        ("USB-C", 0x1B), ("USB-C 2", 0x19),
    ]

    /// One serial queue for all bus traffic: DDC is slow (~50 ms per read) and monitors drop overlapping packets.
    static let queue = DispatchQueue(label: "nits.ddc")

    private static let chipAddress: UInt32 = 0x37
    private static let hostAddress: UInt32 = 0x51

    let vendor: UInt32
    let product: UInt32
    let serial: UInt32
    /// Monitor name from its EDID; lets Nits name a display macOS no longer lists (turned off).
    let productName: String?
    private let service: CFTypeRef

    private let lock = NSLock()
    private var pending: [UInt8: UInt16] = [:]
    private var flushing = false
    /// IORegistry entry ID: stable for one physical connection, while DDCService objects are rebuilt on
    /// every display change.
    let registryID: UInt64

    /// Connections with a read thread that hasn't returned. While one is stuck in the kernel, new reads
    /// on that connection are skipped: starting more would leak a thread each and put overlapping
    /// traffic on the bus. Static, so it survives the rebuilds.
    private static var readsInFlight: Set<UInt64> = []
    private static let inFlightLock = NSLock()

    private init(vendor: UInt32, product: UInt32, serial: UInt32, productName: String?, registryID: UInt64, service: CFTypeRef) {
        self.registryID = registryID
        self.vendor = vendor
        self.product = product
        self.serial = serial
        self.productName = productName
        self.service = service
    }

    /// External display services, each paired with the EDID attributes of the framebuffer that precedes it
    /// in the IORegistry (an AppleCLCD2 node carrying `DisplayAttributes`, then its DCPAVServiceProxy).
    /// Pairs displays with DDC services one to one: exact serial first, then same model, and the
    /// single-service fallback only when there's exactly one external display. A service is never
    /// handed to two displays (that would make one card's sliders drive another monitor).
    static func assign(displays: [(id: CGDirectDisplayID, vendor: UInt32, model: UInt32, serial: UInt32)],
                       services: [(vendor: UInt32, product: UInt32, serial: UInt32)]) -> [CGDirectDisplayID: Int] {
        var free = Set(services.indices)
        var result: [CGDirectDisplayID: Int] = [:]
        // Pass 1: vendor + model + non-zero serial.
        for d in displays where d.serial != 0 {
            if let i = free.sorted().first(where: { services[$0].vendor == d.vendor && services[$0].product == d.model && services[$0].serial == d.serial }) {
                result[d.id] = i
                free.remove(i)
            }
        }
        // Pass 2: vendor + model, in display-ID order.
        for d in displays.sorted(by: { $0.id < $1.id }) where result[d.id] == nil {
            if let i = free.sorted().first(where: { services[$0].vendor == d.vendor && services[$0].product == d.model }) {
                result[d.id] = i
                free.remove(i)
            }
        }
        // Pass 3: one external display, one unclaimed service (EDID attributes missing or odd).
        if displays.count == 1, result.isEmpty, services.count == 1, let i = free.first {
            result[displays[0].id] = i
        }
        return result
    }

    static func all() -> [DDCService] {
        guard let create = AVService.create, AVService.readI2C != nil, AVService.writeI2C != nil else { return [] }
        var iterator = io_iterator_t()
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [DDCService] = []
        var lastAttributes: [String: Any]?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            if let attributes = property(entry, "DisplayAttributes") as? [String: Any],
               let product = attributes["ProductAttributes"] as? [String: Any] {
                lastAttributes = product
            }
            var className = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(entry, &className)
            guard String(cString: className) == "DCPAVServiceProxy" else { continue }
            defer { lastAttributes = nil }
            guard property(entry, "Location") as? String == "External",
                  let attributes = lastAttributes,
                  let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &registryID)
            result.append(DDCService(
                vendor: (attributes["LegacyManufacturerID"] as? NSNumber)?.uint32Value ?? 0,
                product: (attributes["ProductID"] as? NSNumber)?.uint32Value ?? 0,
                serial: (attributes["SerialNumber"] as? NSNumber)?.uint32Value ?? 0,
                productName: attributes["ProductName"] as? String,
                registryID: registryID,
                service: service
            ))
        }
        return result
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// DDC/CI checksum: XOR of the destination address (0x6E), the source address (0x51) and every packet byte.
    static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(0x6E ^ 0x51) { $0 ^ $1 }
    }

    /// Blocking, at most `timeout`. Call on `DDCService.queue`.
    ///
    /// A read the monitor never answers can block inside the kernel forever (seen when two processes polled
    /// the Dell at once). The read runs on its own thread so a hang strands that thread, not the bus queue
    /// that brightness writes go through.
    func read(_ vcp: VCP, timeout: TimeInterval = 2) -> (current: UInt16, max: UInt16)? {
        let key = registryID
        Self.inFlightLock.lock()
        guard Self.readsInFlight.insert(key).inserted else {
            Self.inFlightLock.unlock()
            return nil
        }
        Self.inFlightLock.unlock()

        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: (current: UInt16, max: UInt16)?
        Thread {
            let value = self.readBlocking(vcp)
            lock.lock()
            result = value
            lock.unlock()
            Self.inFlightLock.lock()
            Self.readsInFlight.remove(key)
            Self.inFlightLock.unlock()
            done.signal()
        }.start()
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    private func readBlocking(_ vcp: VCP) -> (current: UInt16, max: UInt16)? {
        var request: [UInt8] = [0x82, 0x01, vcp.rawValue, 0]
        request[3] = Self.checksum(request[0..<3])
        var reply = [UInt8](repeating: 0, count: 11)

        for _ in 0..<4 {
            usleep(10_000)
            guard transfer(AVService.writeI2C, &request) else { continue }
            usleep(50_000)
            guard transfer(AVService.readI2C, &reply) else { continue }
            // Reply: 6E 88 02 <result> <vcp> <type> <maxHi> <maxLo> <curHi> <curLo> <checksum>
            guard let value = Self.parseReply(reply, vcp: vcp.rawValue) else { continue }
            return value
        }
        return nil
    }

    /// Reply: 6E 88 02 <result> <vcp> <type> <maxHi> <maxLo> <curHi> <curLo> <checksum>.
    /// Rejects corrupt or nonsensical replies (bad checksum, error code, current above max).
    static func parseReply(_ reply: [UInt8], vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        guard reply.count >= 11, reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp else { return nil }
        // Checksum: XOR of the host address (0x50) and every byte before it.
        guard reply[0..<10].reduce(UInt8(0x50), ^) == reply[10] else { return nil }
        let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        // Input source (0x60) is a code, not a level; its "max" is meaningless on many monitors.
        guard vcp == 0x60 || current <= max else { return nil }
        return (current, max)
    }

    /// Blocking. Call on `DDCService.queue`.
    @discardableResult
    func write(_ vcp: UInt8, _ value: UInt16) -> Bool {
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = Self.checksum(packet[0..<5])
        var ok = false
        // Sent twice: some monitors silently drop the first packet after a pause.
        for _ in 0..<2 {
            usleep(10_000)
            ok = transfer(AVService.writeI2C, &packet) || ok
        }
        return ok
    }

    private func transfer(_ function: AVService.Transfer?, _ bytes: inout [UInt8]) -> Bool {
        guard let function else { return false }
        let count = UInt32(bytes.count)
        return bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            return function(service, Self.chipAddress, Self.hostAddress, base, count) == kIOReturnSuccess
        }
    }

    /// Non-blocking. Slider drags fire dozens of values; only the latest per control is sent.
    func enqueue(_ vcp: VCP, _ value: UInt16) {
        lock.lock()
        pending[vcp.rawValue] = value
        let start = !flushing
        flushing = true
        lock.unlock()
        if start { Self.queue.async { self.flush() } }
    }

    private func flush() {
        while true {
            lock.lock()
            guard let next = pending.first else {
                flushing = false
                lock.unlock()
                return
            }
            pending.removeValue(forKey: next.key)
            lock.unlock()
            write(next.key, next.value)
        }
    }
}
