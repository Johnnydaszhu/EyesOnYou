import Foundation
import Darwin

/// Host-wide interface byte counters (non-loopback), for live rates when
/// the Network Extension has not reported per-app telemetry yet.
///
/// When macOS system proxy (e.g. Shadowrocket) is on, egress on `en*` / `utun*`
/// is a reasonable stand-in for “proxy path” volume until NE capture lands.
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

    private var last: Counters = Counters()
    private var lastAt: Date?
    private var primed = false

    public init() {}

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

    /// Sum `ifi_ibytes` / `ifi_obytes` across non-loopback AF_LINK interfaces.
    public static func currentCounters() -> Counters {
        var ifaddrList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrList) == 0, let head = ifaddrList else {
            return Counters()
        }
        defer { freeifaddrs(head) }

        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let iface = cursor {
            defer { cursor = iface.pointee.ifa_next }

            let flags = UInt32(iface.pointee.ifa_flags)
            if (flags & UInt32(IFF_LOOPBACK)) != 0 { continue }
            guard let addr = iface.pointee.ifa_addr else { continue }
            guard addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard let raw = iface.pointee.ifa_data else { continue }

            let data = raw.assumingMemoryBound(to: if_data.self)
            bytesIn &+= UInt64(data.pointee.ifi_ibytes)
            bytesOut &+= UInt64(data.pointee.ifi_obytes)
        }
        return Counters(bytesIn: bytesIn, bytesOut: bytesOut)
    }

    /// Delta rates since the previous sample. First call primes and returns zeros.
    public func sampleRates(now: Date = Date()) -> Rates {
        let current = Self.currentCounters()
        defer {
            last = current
            lastAt = now
            primed = true
        }

        guard primed, let previousAt = lastAt else {
            return Rates()
        }
        let dt = now.timeIntervalSince(previousAt)
        guard dt >= 0.25 else { return Rates() }

        let deltaIn = current.bytesIn >= last.bytesIn ? current.bytesIn - last.bytesIn : 0
        let deltaOut = current.bytesOut >= last.bytesOut ? current.bytesOut - last.bytesOut : 0
        return Rates(
            downBps: Double(deltaIn) / dt,
            upBps: Double(deltaOut) / dt,
            deltaIn: deltaIn,
            deltaOut: deltaOut
        )
    }
}
