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

        public init(downBps: Double = 0, upBps: Double = 0, deltaIn: UInt64 = 0, deltaOut: UInt64 = 0) {
            self.downBps = downBps
            self.upBps = upBps
            self.deltaIn = deltaIn
            self.deltaOut = deltaOut
        }
    }

    struct InterfaceCounters: Equatable, Sendable {
        var name: String
        var bytesIn: UInt64
        var bytesOut: UInt64
        var isUp: Bool

        init(
            name: String,
            bytesIn: UInt64,
            bytesOut: UInt64,
            isUp: Bool = true
        ) {
            self.name = name
            self.bytesIn = bytesIn
            self.bytesOut = bytesOut
            self.isUp = isUp
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
                    isUp: (flags & UInt32(IFF_UP)) != 0
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
            deltaIn = Self.addingWithoutOverflow(
                deltaIn,
                Self.delta32(current: current.bytesIn, previous: previous.bytesIn)
            )
            deltaOut = Self.addingWithoutOverflow(
                deltaOut,
                Self.delta32(current: current.bytesOut, previous: previous.bytesOut)
            )
        }
        lastByInterface = currentByInterface
        lastAt = now
        return Rates(
            downBps: Double(deltaIn) / dt,
            upBps: Double(deltaOut) / dt,
            deltaIn: deltaIn,
            deltaOut: deltaOut
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

    /// Darwin's `if_data` exposes 32-bit byte counters. Distinguish a genuine
    /// wrap near `UInt32.max` from an interface reset to avoid a ~4 GiB spike.
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
