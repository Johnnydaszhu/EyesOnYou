import Foundation
import Network
import EyesOnYouCore
import EyesOnYouRuleEngine

/// What the transparent proxy provider should do with one new flow.
///
/// Same rule engine as the local enforcement proxy, one semantic difference:
/// `.inherit` means "the world as it was" — for a flow already redirected into the
/// local proxy that is "chain to the previous system proxy", but for a transparent
/// provider it is simply *decline the flow* and let the OS route it natively
/// (through whatever VPN / system proxy is active). Fail-open by construction.
public enum TransparentFlowPlan: Equatable, Sendable {
    /// Not ours — return the flow to the OS untouched (inherit / no rule).
    case decline
    /// Force-direct: dial the origin ourselves on the physical interface,
    /// escaping any TUN-mode tunnel that owns the default route.
    case dialDirect
    /// Force-proxy: dial this upstream and CONNECT/SOCKS to the target.
    case dialUpstream(ProxyUpstream)
    /// Explicit proxy route with no usable upstream — close the flow.
    /// An explicit route must never silently become direct traffic.
    case refuse(ProxyUnavailableReason)
    /// Firewall block — claim the flow and close it.
    case block
}

public enum TransparentFlowPlanner {
    public static func plan(
        app: AppIdentityKey,
        host: String?,
        port: UInt16?,
        rules: LocalProxyRules
    ) -> TransparentFlowPlan {
        let flow = FlowDescriptor(
            app: app,
            remoteHostname: host,
            remotePort: port
        )
        if rules.snapshot.evaluateFirewall(flow).action == .block {
            return .block
        }
        switch rules.snapshot.evaluateRoute(flow).action {
        case .inherit:
            return .decline
        case .direct:
            return .dialDirect
        case .systemProxy:
            return rules.systemUpstream.map { .dialUpstream($0) }
                ?? .refuse(.systemProxyMissing)
        case .proxy(let profileID):
            return rules.profileUpstreams[profileID].map { .dialUpstream($0) }
                ?? .refuse(.profileMissing(profileID))
        }
    }
}

/// Minimal HTTP CONNECT handshake for chaining a raw TCP flow through an HTTP
/// proxy (RFC 7231 §4.3.6). Request building and response parsing are pure so
/// they are testable without sockets; `perform` is the thin Network glue.
public enum HTTPConnectHandshake {
    /// The CONNECT request head for `host:port`.
    public static func request(host: String, port: UInt16) -> Data {
        Data("CONNECT \(host):\(port) HTTP/1.1\r\nHost: \(host):\(port)\r\n\r\n".utf8)
    }

    public enum ResponseVerdict: Equatable, Sendable {
        /// 2xx received; `remainder` is any bytes past the header block that
        /// belong to the tunneled stream.
        case success(remainder: Data)
        case failure
        case needMoreData
    }

    /// Judge an accumulating response buffer.
    public static func verdict(for buffer: Data) -> ResponseVerdict {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            // A proxy answering CONNECT sends a tiny header block; anything past
            // 16 KiB without terminator is not a sane proxy response.
            return buffer.count > 16_384 ? .failure : .needMoreData
        }
        let head = buffer[..<headerEnd.lowerBound]
        guard let statusLine = String(data: head, encoding: .ascii)?
            .split(separator: "\r\n").first else {
            return .failure
        }
        // "HTTP/1.1 200 Connection established"
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"),
              let code = Int(parts[1]), (200..<300).contains(code) else {
            return .failure
        }
        return .success(remainder: Data(buffer[headerEnd.upperBound...]))
    }

    /// Run the handshake on an open connection to the proxy.
    /// `completion(remainder)` — nil on failure; on success, any early tunneled
    /// bytes the proxy already sent.
    public static func perform(
        on connection: NWConnection,
        host: String,
        port: UInt16,
        queue: DispatchQueue,
        completion: @escaping @Sendable (Data?) -> Void
    ) {
        connection.send(
            content: request(host: host, port: port),
            completion: .contentProcessed { error in
                guard error == nil else { completion(nil); return }
                readResponse(connection, buffer: Data(), queue: queue, completion: completion)
            }
        )
    }

    private static func readResponse(
        _ connection: NWConnection,
        buffer: Data,
        queue: DispatchQueue,
        completion: @escaping @Sendable (Data?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            var next = buffer
            if let data { next.append(data) }
            switch verdict(for: next) {
            case .success(let remainder):
                completion(remainder)
            case .failure:
                completion(nil)
            case .needMoreData:
                if error != nil || isComplete {
                    completion(nil)
                } else {
                    readResponse(connection, buffer: next, queue: queue, completion: completion)
                }
            }
        }
    }
}
