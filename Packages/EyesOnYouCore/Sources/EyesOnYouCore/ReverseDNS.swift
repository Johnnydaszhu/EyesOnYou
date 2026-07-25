import Foundation
import Darwin

/// Turns a raw socket peer address into something worth showing as a destination.
public enum RemoteDestination {
    /// Address blocks a local proxy hands out instead of the real server address.
    ///
    /// Clash / Surge / Shadowrocket "fake-IP" TUN modes answer DNS from
    /// `198.18.0.0/15` (RFC 2544 benchmarking) and sometimes `240.0.0.0/4`
    /// (reserved). These identify a slot in the proxy's own table, not a site, so
    /// showing one as a destination is worse than admitting we do not know.
    public static func isProxyPlaceholderAddress(_ host: String) -> Bool {
        guard let addr = DirectDestinationIndex.parseIPv4(host) else { return false }
        let is198_18 = (addr & 0xFFFE_0000) == 0xC612_0000   // 198.18.0.0/15
        let isReserved240 = (addr & 0xF000_0000) == 0xF000_0000  // 240.0.0.0/4
        return is198_18 || isReserved240
    }

    /// Display key for a peer address.
    ///
    /// Prefers a resolved hostname; keeps a real IP when reverse DNS fails (still
    /// actionable); returns `nil` for placeholder addresses so the caller can fall
    /// back to `DestinationKey.unknown` rather than invent a site.
    public static func label(host: String, resolved: String? = nil) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if let resolved {
            let name = resolved.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !name.isEmpty, name != trimmed { return name }
        }
        if isProxyPlaceholderAddress(trimmed) { return nil }
        return trimmed
    }
}

/// Best-effort reverse DNS for classifying proxy egress IPs against domain rules.
public enum ReverseDNS {
    public static func lookup(_ ip: String, timeoutSeconds: TimeInterval = 0.35) -> String? {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var hints = addrinfo(
            ai_flags: AI_NUMERICHOST,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        let lookupResult = trimmed.withCString { cHost in
            getaddrinfo(cHost, nil, &hints, &info)
        }
        guard lookupResult == 0, let info else { return nil }
        defer { freeaddrinfo(info) }

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let flags = NI_NAMEREQD
        let status = getnameinfo(
            info.pointee.ai_addr,
            info.pointee.ai_addrlen,
            &hostBuffer,
            socklen_t(hostBuffer.count),
            nil,
            0,
            flags
        )
        guard status == 0 else { return nil }
        let name = String(cString: hostBuffer)
        let lower = name.lowercased()
        if lower.isEmpty || lower == trimmed.lowercased() { return nil }
        _ = timeoutSeconds
        return lower
    }
}
