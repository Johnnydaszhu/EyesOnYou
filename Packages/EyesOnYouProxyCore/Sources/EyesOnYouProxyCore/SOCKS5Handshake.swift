import Foundation
import Network

/// Minimal SOCKS5 CONNECT handshake (RFC 1928), no authentication.
///
/// Enough to hand a flow to a local SOCKS5 proxy (Shadowrocket / Clash listen this
/// way): greet with "no auth", send a CONNECT to the target as a hostname, and check
/// the reply succeeded. The target host is sent as a domain name (ATYP 0x03) so the
/// upstream does the DNS — matching how proxy chains normally behave.
public enum SOCKS5Handshake {
    public static func perform(
        on connection: NWConnection,
        host: String,
        port: UInt16,
        queue: DispatchQueue,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        // Greeting: version 5, 1 method, 0x00 = no auth.
        let greeting = Data([0x05, 0x01, 0x00])
        connection.send(content: greeting, completion: .contentProcessed { error in
            guard error == nil else { completion(false); return }
            receiveExactly(connection, count: 2, queue: queue) { reply in
                // Expect 0x05 0x00 (no-auth accepted).
                guard let reply, reply.count == 2, reply[0] == 0x05, reply[1] == 0x00 else {
                    completion(false); return
                }
                sendConnect(connection, host: host, port: port, queue: queue, completion: completion)
            }
        })
    }

    private static func sendConnect(
        _ connection: NWConnection,
        host: String,
        port: UInt16,
        queue: DispatchQueue,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        guard let hostBytes = host.data(using: .utf8), hostBytes.count <= 255 else {
            completion(false); return
        }
        var request = Data([0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)])
        request.append(hostBytes)
        request.append(UInt8(port >> 8))
        request.append(UInt8(port & 0xFF))

        connection.send(content: request, completion: .contentProcessed { error in
            guard error == nil else { completion(false); return }
            // Reply header is 4 bytes; the bound address that follows varies by ATYP.
            receiveExactly(connection, count: 4, queue: queue) { header in
                guard let header, header.count == 4, header[0] == 0x05, header[1] == 0x00 else {
                    completion(false); return
                }
                let addrLen: Int
                switch header[3] {
                case 0x01: addrLen = 4          // IPv4
                case 0x04: addrLen = 16         // IPv6
                case 0x03:                       // domain: first byte is length
                    receiveExactly(connection, count: 1, queue: queue) { lenByte in
                        guard let lenByte, let n = lenByte.first else { completion(false); return }
                        drain(connection, count: Int(n) + 2, queue: queue, completion: completion)
                    }
                    return
                default:
                    completion(false); return
                }
                // Consume bound address + 2-byte port, then we're ready to splice.
                drain(connection, count: addrLen + 2, queue: queue, completion: completion)
            }
        })
    }

    private static func drain(
        _ connection: NWConnection,
        count: Int,
        queue: DispatchQueue,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        receiveExactly(connection, count: count, queue: queue) { data in
            completion(data?.count == count)
        }
    }

    /// Receive exactly `count` bytes, coalescing short reads.
    private static func receiveExactly(
        _ connection: NWConnection,
        count: Int,
        queue: DispatchQueue,
        accumulated: Data = Data(),
        completion: @escaping @Sendable (Data?) -> Void
    ) {
        let remaining = count - accumulated.count
        guard remaining > 0 else { completion(accumulated); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) {
            data, _, isComplete, error in
            guard error == nil, let data, !data.isEmpty else {
                completion(isComplete ? nil : accumulated.isEmpty ? nil : nil)
                return
            }
            var next = accumulated
            next.append(data)
            if next.count >= count {
                completion(next)
            } else if isComplete {
                completion(nil)
            } else {
                receiveExactly(connection, count: count, queue: queue,
                               accumulated: next, completion: completion)
            }
        }
    }
}
