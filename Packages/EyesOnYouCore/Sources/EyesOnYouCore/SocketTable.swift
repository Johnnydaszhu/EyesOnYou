import Darwin
import Foundation

/// The host's ESTABLISHED TCP sockets, read straight from the kernel.
///
/// The same information used to come from `/usr/sbin/lsof -nP -iTCP -sTCP:ESTABLISHED`,
/// once a second, forever. That meant a fork + exec + a full scan of every descriptor of
/// every process (`lsof` resolves file paths, devices and mount points it never needed
/// here) and then parsing the result back out of text. This asks `libproc` for exactly
/// the four things attribution uses — pid, command, local endpoint, remote endpoint —
/// and nothing else.
///
/// Visibility matches `lsof` run as the same user: sockets belonging to other users'
/// processes are not readable without root, and are skipped rather than reported.
public enum SocketTable {
    /// Every ESTABLISHED TCP socket this process is allowed to see.
    public static func establishedTCP() -> [ActiveAppSocketSampler.ConnectionLine] {
        guard let pids = allPIDs() else { return [] }

        var lines: [ActiveAppSocketSampler.ConnectionLine] = []
        lines.reserveCapacity(256)
        // Reused across processes: the descriptor table is read once per pid and a
        // fresh allocation each time would dominate the walk.
        var fdBuffer = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)

        for pid in pids where pid > 0 {
            let fdCount = listSocketFDs(pid: pid, into: &fdBuffer)
            guard fdCount > 0 else { continue }

            var command: String?
            for index in 0..<fdCount {
                let entry = fdBuffer[index]
                guard entry.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
                guard let endpoints = tcpEndpoints(pid: pid, fd: entry.proc_fd) else { continue }
                // Resolving the name costs a syscall, so only processes that actually
                // hold a matching socket pay for it.
                let name = command ?? processName(pid: pid)
                command = name
                lines.append(
                    ActiveAppSocketSampler.ConnectionLine(
                        command: name,
                        pid: pid,
                        localHost: endpoints.localHost,
                        localPort: endpoints.localPort,
                        remoteHost: endpoints.remoteHost,
                        remotePort: endpoints.remotePort
                    )
                )
            }
        }
        return lines
    }

    /// ESTABLISHED TCP sockets whose local endpoint is loopback, as (pid, localPort).
    ///
    /// This is the reverse index that says which process dialed the local proxy.
    public static func loopbackClients() -> [(pid: Int32, localPort: UInt16)] {
        establishedTCP().compactMap { line in
            guard isLoopback(line.localHost), line.localPort > 0, line.localPort <= 65_535 else {
                return nil
            }
            return (line.pid, UInt16(line.localPort))
        }
    }

    public static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1" || host == "localhost"
    }

    // MARK: - libproc

    private static func allPIDs() -> [pid_t]? {
        // Ask for the size first; the table changes between calls, so allocate slack.
        let probed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard probed > 0 else { return nil }
        let stride = MemoryLayout<pid_t>.stride
        var capacity = Int(probed) / stride + 64
        for _ in 0..<3 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let written = pids.withUnsafeMutableBufferPointer { buffer in
                proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count * stride))
            }
            guard written > 0 else { return nil }
            let count = Int(written) / stride
            // A full buffer means the list may have been truncated — retry larger.
            if count < capacity {
                return Array(pids[0..<count])
            }
            capacity *= 2
        }
        return nil
    }

    /// Fill `buffer` with the process's descriptor table; returns the entry count.
    private static func listSocketFDs(pid: pid_t, into buffer: inout [proc_fdinfo]) -> Int {
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Processes owned by another user return 0 here (EPERM), same as under `lsof`.
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return 0 }
        let entries = Int(needed) / stride
        if buffer.count < entries {
            buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: entries * 2)
        }
        let written = buffer.withUnsafeMutableBufferPointer { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count * stride))
        }
        guard written > 0 else { return 0 }
        return min(Int(written) / stride, buffer.count)
    }

    private static func tcpEndpoints(
        pid: pid_t,
        fd: Int32
    ) -> (localHost: String, localPort: Int, remoteHost: String, remotePort: Int)? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        let read = proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size)
        guard read == size else { return nil }
        guard info.psi.soi_kind == SOCKINFO_TCP else { return nil }

        let tcp = info.psi.soi_proto.pri_tcp
        guard tcp.tcpsi_state == TSI_S_ESTABLISHED else { return nil }

        // `insi_laddr` and `insi_faddr` are separate anonymous unions, so they import
        // as distinct Swift types; unpack both to the shared v4/v6 pair.
        let endpoint = tcp.tcpsi_ini
        guard
            let local = address(
                v4: endpoint.insi_laddr.ina_46.i46a_addr4,
                v6: endpoint.insi_laddr.ina_6,
                vflag: endpoint.insi_vflag
            ),
            let remote = address(
                v4: endpoint.insi_faddr.ina_46.i46a_addr4,
                v6: endpoint.insi_faddr.ina_6,
                vflag: endpoint.insi_vflag
            )
        else { return nil }

        return (
            localHost: local,
            localPort: Int(port(endpoint.insi_lport)),
            remoteHost: remote,
            remotePort: Int(port(endpoint.insi_fport))
        )
    }

    /// Ports are stored in network byte order.
    private static func port(_ raw: Int32) -> UInt16 {
        UInt16(bigEndian: UInt16(truncatingIfNeeded: raw))
    }

    private static func address(v4: in_addr, v6: in6_addr, vflag: UInt8) -> String? {
        if vflag & UInt8(INI_IPV4) != 0 {
            return ipv4String(v4)
        }
        if vflag & UInt8(INI_IPV6) != 0 {
            var v6 = v6
            // An IPv4-mapped address is an IPv4 peer; printing it as `::ffff:1.2.3.4`
            // would defeat every downstream IPv4 comparison (DIRECT rules, loopback
            // checks, reverse DNS).
            if let mapped = mappedIPv4(v6) {
                return ipv4String(mapped)
            }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                return nil
            }
            return String(cString: buffer)
        }
        return nil
    }

    private static func ipv4String(_ address: in_addr) -> String? {
        var value = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &value, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(cString: buffer)
    }

    private static func mappedIPv4(_ address: in6_addr) -> in_addr? {
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        guard bytes.count == 16 else { return nil }
        let prefixIsZero = bytes[0..<10].allSatisfy { $0 == 0 }
        guard prefixIsZero, bytes[10] == 0xFF, bytes[11] == 0xFF else { return nil }
        let packed = UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16
            | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
        return in_addr(s_addr: packed.bigEndian)
    }

    /// Short process name, matching the 16-character `COMMAND` column `lsof` prints.
    private static func processName(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(2 * MAXCOMLEN) + 1)
        let written = proc_name(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return "pid.\(pid)" }
        let name = String(cString: buffer)
        return name.isEmpty ? "pid.\(pid)" : name
    }
}
