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
    /// Reverse lookup through a killable helper with both resolver and wall-clock
    /// deadlines. A stalled resolver can no longer occupy the enrichment queue.
    public static func lookup(_ ip: String) -> String? {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        let isNumeric = trimmed.withCString {
            inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1
        }
        guard isNumeric else { return nil }

        guard let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/dig"),
            arguments: ["+time=1", "+tries=1", "+short", "-x", trimmed],
            timeout: 2
        ), !result.timedOut, result.terminationStatus == 0,
              let output = String(data: result.stdout, encoding: .utf8)
        else {
            return nil
        }
        return parseLookupOutput(output, originalIP: trimmed)
    }

    static func parseLookupOutput(_ output: String, originalIP: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            var candidate = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !candidate.isEmpty, !candidate.hasPrefix(";") else { continue }
            while candidate.last == "." {
                candidate.removeLast()
            }
            guard !candidate.isEmpty,
                  candidate != originalIP.lowercased(),
                  !candidate.contains(where: \.isWhitespace)
            else {
                continue
            }
            return candidate
        }
        return nil
    }
}
