import Foundation

/// The parsed head of an inbound proxy request.
///
/// Only two shapes exist for a client talking to an HTTP proxy:
/// - `CONNECT host:port HTTP/1.1` — a tunnel (all HTTPS)
/// - `GET http://host/path HTTP/1.1` — absolute-form plain HTTP
///
/// The raw head bytes are kept verbatim: an upstream HTTP proxy expects exactly
/// what the client sent, and RFC 7230 §5.3.2 requires origin servers to accept
/// absolute-form too — so forwarding never needs to rewrite anything.
public struct ProxyRequestHead: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// CONNECT tunnel; the head is consumed, everything after it is payload.
        case connect
        /// Plain-HTTP request; the head itself must be forwarded to the target.
        case httpForward
    }

    public let kind: Kind
    public let host: String
    public let port: UInt16
    /// Verbatim head bytes, including the terminating CRLFCRLF.
    public let rawHead: Data
    /// Bytes the client sent after the head in the same read (early payload).
    public let remainder: Data

    /// Locate and parse a complete head in `buffer`.
    ///
    /// - Returns: `nil` when the head is not complete yet (caller keeps reading),
    ///   `.failure` when the head is complete but not a valid proxy request.
    public static func parse(buffer: Data) -> Result<ProxyRequestHead, ParseError>? {
        guard let headEnd = findHeadEnd(buffer) else { return nil }
        let head = buffer.prefix(upTo: headEnd)
        let remainder = Data(buffer.suffix(from: headEnd))

        guard let firstLineEnd = head.firstRange(of: Data("\r\n".utf8))?.lowerBound,
              let requestLine = String(data: head.prefix(upTo: firstLineEnd), encoding: .utf8)
        else { return .failure(.malformedRequestLine) }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return .failure(.malformedRequestLine) }
        let method = parts[0].uppercased()
        let target = String(parts[1])

        if method == "CONNECT" {
            guard let (host, port) = splitAuthority(target, defaultPort: 443) else {
                return .failure(.badTarget(target))
            }
            return .success(ProxyRequestHead(
                kind: .connect,
                host: host,
                port: port,
                rawHead: Data(head),
                remainder: remainder
            ))
        }

        // Absolute-form: scheme://authority/path…
        guard let url = URL(string: target),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return .failure(.badTarget(target)) }
        let port = UInt16(url.port ?? (scheme == "https" ? 443 : 80))
        return .success(ProxyRequestHead(
            kind: .httpForward,
            host: host.lowercased(),
            port: port,
            rawHead: Data(head),
            remainder: remainder
        ))
    }

    public enum ParseError: Error, Equatable, Sendable {
        case malformedRequestLine
        case badTarget(String)
    }

    /// Index just past the CRLFCRLF terminator, or `nil` when incomplete.
    private static func findHeadEnd(_ data: Data) -> Data.Index? {
        guard let range = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        return range.upperBound
    }

    /// `host:port`, `[v6]:port`, or bare host.
    static func splitAuthority(_ value: String, defaultPort: UInt16) -> (String, UInt16)? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.isEmpty { return (host.lowercased(), defaultPort) }
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return nil }
            return (host.lowercased(), port)
        }

        guard let colon = trimmed.lastIndex(of: ":"),
              // A bare IPv6 literal without brackets has multiple colons — reject.
              trimmed.firstIndex(of: ":") == colon
        else {
            return trimmed.contains(":") ? nil : (trimmed.lowercased(), defaultPort)
        }
        let host = String(trimmed[..<colon])
        guard !host.isEmpty, let port = UInt16(trimmed[trimmed.index(after: colon)...]) else {
            return nil
        }
        return (host.lowercased(), port)
    }
}
