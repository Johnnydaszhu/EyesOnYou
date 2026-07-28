import Foundation
import Darwin

/// Host-wide interface byte counters (non-loopback), for live rates when
/// the Network Extension has not reported per-app telemetry yet.
///
/// Only physical `en*` interfaces are counted. Tunnel and side-channel
/// interfaces carry another view of the same traffic and must not be added to
/// the physical transport total.
public final class HostNetworkSampler: @unchecked Sendable {
    public struct Counters: Equatable, Sendable {
        public var bytesIn: UInt64
        public var bytesOut: UInt64

        public init(bytesIn: UInt64 = 0, bytesOut: UInt64 = 0) {
            self.bytesIn = bytesIn
            self.bytesOut = bytesOut
        }
    }

    public struct Rates: Equatable, Sendable {
        public var downBps: Double
        public var upBps: Double
        public var deltaIn: UInt64
        public var deltaOut: UInt64
        public var sampleInterval: TimeInterval

        public init(
            downBps: Double = 0,
            upBps: Double = 0,
            deltaIn: UInt64 = 0,
            deltaOut: UInt64 = 0,
            sampleInterval: TimeInterval = 0
        ) {
            self.downBps = downBps
            self.upBps = upBps
            self.deltaIn = deltaIn
            self.deltaOut = deltaOut
            self.sampleInterval = sampleInterval
        }
    }

    enum CounterSource: Equatable, Sendable {
        case route64
        case legacy32
    }

    struct InterfaceCounters: Equatable, Sendable {
        var name: String
        var bytesIn: UInt64
        var bytesOut: UInt64
        var isUp: Bool
        var source: CounterSource

        init(
            name: String,
            bytesIn: UInt64,
            bytesOut: UInt64,
            isUp: Bool = true,
            source: CounterSource = .route64
        ) {
            self.name = name
            self.bytesIn = bytesIn
            self.bytesOut = bytesOut
            self.isUp = isUp
            self.source = source
        }
    }

    typealias CounterProvider = () -> [InterfaceCounters]

    private let counterProvider: CounterProvider
    private var lastByInterface: [String: InterfaceCounters] = [:]
    private var lastAt: Date?
    private var primed = false

    public convenience init() {
        self.init(counterProvider: Self.readInterfaceCounters)
    }

    init(counterProvider: @escaping CounterProvider) {
        self.counterProvider = counterProvider
    }

    /// True when at least one `utun*` interface is up (VPN / tunnel client likely active).
    public static func hasActiveTunnelInterface() -> Bool {
        var ifaddrList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrList) == 0, let head = ifaddrList else {
            return false
        }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let iface = cursor {
            defer { cursor = iface.pointee.ifa_next }
            guard let cName = iface.pointee.ifa_name else { continue }
            let name = String(cString: cName)
            guard name.hasPrefix("utun") else { continue }
            let flags = UInt32(iface.pointee.ifa_flags)
            if (flags & UInt32(IFF_UP)) != 0 {
                return true
            }
        }
        return false
    }

    /// Sum `ifi_ibytes` / `ifi_obytes` across active physical interfaces.
    ///
    /// `utun*`, `awdl*`, `llw*`, and similar interfaces are intentionally not
    /// included because their bytes overlap with the physical `en*` transport.
    public static func currentCounters() -> Counters {
        aggregatePhysicalCounters(readInterfaceCounters())
    }

    static func aggregatePhysicalCounters(_ interfaces: [InterfaceCounters]) -> Counters {
        physicalInterfacesByName(interfaces).values.reduce(into: Counters()) { total, interface in
            total.bytesIn = addingWithoutOverflow(total.bytesIn, interface.bytesIn)
            total.bytesOut = addingWithoutOverflow(total.bytesOut, interface.bytesOut)
        }
    }

    private static func readInterfaceCounters() -> [InterfaceCounters] {
        if let counters = readInterfaceCounters64(), !counters.isEmpty {
            return counters
        }
        return readInterfaceCounters32Fallback()
    }

    /// Preferred source. `NET_RT_IFLIST2` reports `if_msghdr2.ifm_data`, whose
    /// byte counters are 64-bit and therefore do not wrap every ~4 GiB.
    private static func readInterfaceCounters64() -> [InterfaceCounters]? {
        var mib: [Int32] = [
            Int32(CTL_NET),
            Int32(PF_ROUTE),
            0,
            Int32(AF_UNSPEC),
            Int32(NET_RT_IFLIST2),
            0,
        ]

        // The routing table can grow between the size query and the read. Retry
        // once when that race returns ENOMEM, then fall back to getifaddrs.
        for _ in 0..<2 {
            var byteCount = 0
            let sizeStatus = mib.withUnsafeMutableBufferPointer { mibBuffer in
                sysctl(
                    mibBuffer.baseAddress,
                    u_int(mibBuffer.count),
                    nil,
                    &byteCount,
                    nil,
                    0
                )
            }
            guard sizeStatus == 0 else { return nil }
            guard byteCount > 0 else { return [] }

            var bytes = [UInt8](repeating: 0, count: byteCount)
            var written = byteCount
            let readStatus = mib.withUnsafeMutableBufferPointer { mibBuffer in
                bytes.withUnsafeMutableBytes { rawBuffer in
                    sysctl(
                        mibBuffer.baseAddress,
                        u_int(mibBuffer.count),
                        rawBuffer.baseAddress,
                        &written,
                        nil,
                        0
                    )
                }
            }
            if readStatus == 0 {
                return bytes.withUnsafeBytes { rawBuffer in
                    let validBytes = UnsafeRawBufferPointer(rebasing: rawBuffer[..<written])
                    return parseInterfaceCounters64(
                        validBytes,
                        interfaceName: interfaceName(for:)
                    )
                }
            }
            guard errno == ENOMEM else { return nil }
        }
        return nil
    }

    /// Internal entry point for deterministic parser tests.
    static func parseInterfaceCounters64(
        _ data: Data,
        interfaceName: (UInt32) -> String?
    ) -> [InterfaceCounters]? {
        data.withUnsafeBytes {
            parseInterfaceCounters64($0, interfaceName: interfaceName)
        }
    }

    private static func parseInterfaceCounters64(
        _ bytes: UnsafeRawBufferPointer,
        interfaceName: (UInt32) -> String?
    ) -> [InterfaceCounters]? {
        var interfaces: [InterfaceCounters] = []
        var offset = 0
        let messagePrefixSize = MemoryLayout<UInt16>.size + 2
        let interfaceMessageSize = MemoryLayout<if_msghdr2>.size

        while offset < bytes.count {
            guard bytes.count - offset >= messagePrefixSize else { return nil }
            let messageLength = Int(
                bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            )
            guard messageLength >= messagePrefixSize,
                  messageLength <= bytes.count - offset
            else {
                return nil
            }

            let messageType = bytes[offset + 3]
            if messageType == UInt8(RTM_IFINFO2) {
                guard messageLength >= interfaceMessageSize else { return nil }
                let message = bytes.loadUnaligned(
                    fromByteOffset: offset,
                    as: if_msghdr2.self
                )
                let index = UInt32(message.ifm_index)
                if let name = interfaceName(index) {
                    interfaces.append(
                        InterfaceCounters(
                            name: name,
                            bytesIn: message.ifm_data.ifi_ibytes,
                            bytesOut: message.ifm_data.ifi_obytes,
                            isUp: (UInt32(message.ifm_flags) & UInt32(IFF_UP)) != 0,
                            source: .route64
                        )
                    )
                }
            }
            offset += messageLength
        }
        return interfaces
    }

    private static func interfaceName(for index: UInt32) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        return name.withUnsafeMutableBufferPointer { buffer in
            guard if_indextoname(index, buffer.baseAddress) != nil else { return nil }
            return String(cString: buffer.baseAddress!)
        }
    }

    /// Explicit compatibility fallback. `getifaddrs` exposes legacy `if_data`
    /// with 32-bit byte counters, so only snapshots from this source use wrap math.
    private static func readInterfaceCounters32Fallback() -> [InterfaceCounters] {
        var ifaddrList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrList) == 0, let head = ifaddrList else {
            return []
        }
        defer { freeifaddrs(head) }

        var interfaces: [InterfaceCounters] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let iface = cursor {
            defer { cursor = iface.pointee.ifa_next }

            guard let addr = iface.pointee.ifa_addr else { continue }
            guard addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard let cName = iface.pointee.ifa_name else { continue }
            guard let raw = iface.pointee.ifa_data else { continue }

            let flags = UInt32(iface.pointee.ifa_flags)
            let data = raw.assumingMemoryBound(to: if_data.self)
            interfaces.append(
                InterfaceCounters(
                    name: String(cString: cName),
                    bytesIn: UInt64(data.pointee.ifi_ibytes),
                    bytesOut: UInt64(data.pointee.ifi_obytes),
                    isUp: (flags & UInt32(IFF_UP)) != 0,
                    source: .legacy32
                )
            )
        }
        return interfaces
    }

    /// Delta rates since the previous sample. First call primes and returns zeros.
    public func sampleRates(now: Date = Date()) -> Rates {
        let currentByInterface = Self.physicalInterfacesByName(counterProvider())
        guard primed, let previousAt = lastAt else {
            lastByInterface = currentByInterface
            lastAt = now
            primed = true
            return Rates()
        }
        let dt = now.timeIntervalSince(previousAt)
        // UI refreshes can happen between timer ticks. Do not advance the counter
        // baseline for those calls or their bytes disappear from the next real sample.
        guard dt >= 0.25 else { return Rates() }

        var deltaIn: UInt64 = 0
        var deltaOut: UInt64 = 0
        for (name, current) in currentByInterface {
            // A newly appearing interface starts with a fresh baseline. Its
            // lifetime counter is not traffic observed during this interval.
            guard let previous = lastByInterface[name] else { continue }
            // A source transition changes counter width and may also change the
            // exact kernel snapshot moment. Treat it as a fresh baseline.
            guard previous.source == current.source else { continue }
            deltaIn = Self.addingWithoutOverflow(
                deltaIn,
                Self.delta(
                    current: current.bytesIn,
                    previous: previous.bytesIn,
                    source: current.source
                )
            )
            deltaOut = Self.addingWithoutOverflow(
                deltaOut,
                Self.delta(
                    current: current.bytesOut,
                    previous: previous.bytesOut,
                    source: current.source
                )
            )
        }
        lastByInterface = currentByInterface
        lastAt = now
        return Rates(
            downBps: Double(deltaIn) / dt,
            upBps: Double(deltaOut) / dt,
            deltaIn: deltaIn,
            deltaOut: deltaOut,
            sampleInterval: dt
        )
    }

    private static func physicalInterfacesByName(
        _ interfaces: [InterfaceCounters]
    ) -> [String: InterfaceCounters] {
        var result: [String: InterfaceCounters] = [:]
        for interface in interfaces where interface.isUp && isPhysicalInterfaceName(interface.name) {
            result[interface.name] = interface
        }
        return result
    }

    private static func isPhysicalInterfaceName(_ name: String) -> Bool {
        guard name.hasPrefix("en") else { return false }
        let suffix = name.dropFirst(2)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    private static func delta(
        current: UInt64,
        previous: UInt64,
        source: CounterSource
    ) -> UInt64 {
        switch source {
        case .route64:
            // A 64-bit counter cannot realistically wrap. A decrease means the
            // interface reset or was recreated, so no interval delta is knowable.
            return current >= previous ? current - previous : 0
        case .legacy32:
            return delta32(current: current, previous: previous)
        }
    }

    /// Legacy `if_data` exposes 32-bit byte counters. Distinguish a genuine wrap
    /// near `UInt32.max` from an interface reset to avoid a ~4 GiB spike.
    private static func delta32(current: UInt64, previous: UInt64) -> UInt64 {
        guard current < previous else { return current - previous }

        let maximum = UInt64(UInt32.max)
        let highWatermark = maximum * 3 / 4
        let lowWatermark = maximum / 4
        guard previous >= highWatermark, current <= lowWatermark else {
            return 0
        }
        return (maximum - previous) + current + 1
    }

    private static func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}
