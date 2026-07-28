import XCTest
@testable import EyesOnYouCore

final class ActiveAppSocketSamplerTests: XCTestCase {
    func testSuccessfulEmptyKernelReadDoesNotInvokeLsofFallback() {
        var lsofReads = 0

        let connections = ActiveAppSocketSampler.currentConnections(
            readSocketTable: { .success([]) },
            readLsof: {
                lsofReads += 1
                return """
                COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
                Safari 200 me 12u IPv4 0x3 0t0 TCP 192.168.1.2:50003->1.1.1.1:443 (ESTABLISHED)
                """
            }
        )

        XCTAssertEqual(connections, [])
        XCTAssertEqual(lsofReads, 0)
    }

    func testFailedKernelReadInvokesLsofFallback() {
        var lsofReads = 0

        let connections = ActiveAppSocketSampler.currentConnections(
            readSocketTable: { .failure },
            readLsof: {
                lsofReads += 1
                return """
                COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
                Safari 200 me 12u IPv4 0x3 0t0 TCP 192.168.1.2:50003->1.1.1.1:443 (ESTABLISHED)
                """
            }
        )

        XCTAssertEqual(lsofReads, 1)
        XCTAssertEqual(connections.count, 1)
        XCTAssertEqual(connections.first?.pid, 200)
        XCTAssertEqual(connections.first?.remoteHost, "1.1.1.1")
    }

    func testBothSocketSourcesFailWithoutPretendingTheCensusIsEmpty() {
        let result = ActiveAppSocketSampler.currentConnectionResult(
            readSocketTable: { .failure },
            readLsof: { nil }
        )

        XCTAssertEqual(result, .failure)
    }

    func testEmptyLsofFallbackIsASuccessfulEmptyCensus() {
        let result = ActiveAppSocketSampler.currentConnectionResult(
            readSocketTable: { .failure },
            readLsof: { "" }
        )

        XCTAssertEqual(result, .success([]))
    }

    func testKernelWalkNeedsAtLeastOneReadableProcess() {
        XCTAssertEqual(
            SocketTable.classifyKernelWalk(lines: [], readableProcessCount: 0),
            .failure
        )
        XCTAssertEqual(
            SocketTable.classifyKernelWalk(lines: [], readableProcessCount: 1),
            .success([])
        )
    }

    func testSocketSnapshotFreshnessUsesFixedCaptureAge() {
        let capturedAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(
            ActiveAppSocketSampler.snapshotIsFresh(
                capturedAt: capturedAt,
                now: capturedAt.addingTimeInterval(3)
            )
        )
        XCTAssertFalse(
            ActiveAppSocketSampler.snapshotIsFresh(
                capturedAt: capturedAt,
                now: capturedAt.addingTimeInterval(3.001)
            )
        )
        XCTAssertFalse(
            ActiveAppSocketSampler.snapshotIsFresh(
                capturedAt: capturedAt,
                now: capturedAt.addingTimeInterval(-0.001)
            )
        )
        XCTAssertFalse(
            ActiveAppSocketSampler.snapshotIsFresh(capturedAt: nil, now: capturedAt)
        )
    }

    func testLoopbackCoversIPv4RangeIPv6AndIPv4MappedBoundaries() {
        let loopbackHosts = [
            "127.0.0.0",
            "127.0.0.1",
            "127.42.18.9",
            "127.255.255.255",
            "::1",
            "0:0:0:0:0:0:0:1",
            "::ffff:127.0.0.0",
            "::ffff:127.255.255.255",
            "localhost",
            "LOCALHOST",
        ]
        for host in loopbackHosts {
            XCTAssertTrue(SocketTable.isLoopback(host), "\(host) should be loopback")
        }

        let nonLoopbackHosts = [
            "126.255.255.255",
            "128.0.0.0",
            "::",
            "::2",
            "::ffff:126.255.255.255",
            "::ffff:128.0.0.0",
            "127.example.com",
        ]
        for host in nonLoopbackHosts {
            XCTAssertFalse(SocketTable.isLoopback(host), "\(host) should not be loopback")
        }
    }

    func testIPv4MappedLoopbackUsesSharedProxyClassification() {
        let output = """
        COMMAND     PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        Chrome      100 me     10u  IPv6 0x1      0t0  TCP [::ffff:127.8.0.1]:50001->[::ffff:127.8.0.2]:7890 (ESTABLISHED)
        clash-meta  808 me     18u  IPv6 0x4      0t0  TCP [::ffff:127.8.0.2]:7890->[::ffff:127.8.0.1]:50001 (ESTABLISHED)
        """

        let snapshot = ActiveAppSocketSampler.summarize(
            ActiveAppSocketSampler.parse(lsofOutput: output),
            proxyPort: nil
        )

        XCTAssertEqual(snapshot.proxyPorts, [7890])
        XCTAssertEqual(byVia(snapshot, pid: 100), 1)
    }

    func testParseAndPreferProxyClientsOverProxyEgress() {
        let output = """
        COMMAND     PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        Chrome      100 me     10u  IPv4 0x1      0t0  TCP 127.0.0.1:50001->127.0.0.1:1082 (ESTABLISHED)
        Chrome      100 me     11u  IPv4 0x2      0t0  TCP 127.0.0.1:50002->127.0.0.1:1082 (ESTABLISHED)
        Safari      200 me     12u  IPv4 0x3      0t0  TCP 192.168.1.2:50003->1.1.1.1:443 (ESTABLISHED)
        MacPacket   808 me     18u  IPv4 0x4      0t0  TCP 127.0.0.1:1082->127.0.0.1:50001 (ESTABLISHED)
        MacPacket   808 me     19u  IPv4 0x5      0t0  TCP 192.168.1.2:51071->95.169.2.146:443 (ESTABLISHED)
        MacPacket   808 me     20u  IPv4 0x6      0t0  TCP 192.168.1.2:51072->203.107.1.10:443 (ESTABLISHED)
        """

        let index = DirectDestinationIndex(
            domains: [],
            domainSuffixes: ["bilibili.com", "bilivideo.com"],
            ipv4Networks: [
                IPv4Network(address: DirectDestinationIndex.parseIPv4("203.107.1.0") ?? 0, prefix: 24)
            ],
            policyLabels: ["BiliBili"]
        )

        let snap = ActiveAppSocketSampler.summarize(
            ActiveAppSocketSampler.parse(lsofOutput: output),
            proxyPort: 1082,
            directIndex: index,
            resolvedHosts: ["95.169.2.146": "upos-sz.bilivideo.com"]
        )

        let byPID = Dictionary(uniqueKeysWithValues: snap.processes.map { ($0.pid, $0) })
        XCTAssertEqual(byPID[100]?.viaProxyConnections, 2)
        XCTAssertEqual(byPID[200]?.directConnections, 1)
        XCTAssertEqual(snap.proxyDirectEgress, 2, "CIDR + reverse-DNS bilibili host should count as DIRECT")
        XCTAssertEqual(snap.proxyRemoteEgress, 0)
        XCTAssertTrue(snap.proxyDirectHosts.contains("upos-sz.bilivideo.com"))
        XCTAssertTrue(snap.proxyDirectHosts.contains("203.107.1.10"))
    }

    func testDirectIndexMatchesSuffix() {
        let index = DirectDestinationIndex(domainSuffixes: ["bilibili.com"])
        XCTAssertTrue(index.matches(hostOrIP: "api.bilibili.com"))
        XCTAssertFalse(index.matches(hostOrIP: "example.com"))
    }

    func testPrimaryProxyNodeIPPicksDominantRemoteEgress() {
        let output = """
        COMMAND     PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        Chrome      100 me     10u  IPv4 0x1      0t0  TCP 127.0.0.1:50001->127.0.0.1:1082 (ESTABLISHED)
        MacPacket   808 me     18u  IPv4 0x4      0t0  TCP 127.0.0.1:1082->127.0.0.1:50001 (ESTABLISHED)
        MacPacket   808 me     19u  IPv4 0x5      0t0  TCP 192.168.1.2:51071->95.169.2.146:443 (ESTABLISHED)
        MacPacket   808 me     20u  IPv4 0x6      0t0  TCP 192.168.1.2:51072->95.169.2.146:443 (ESTABLISHED)
        MacPacket   808 me     21u  IPv4 0x7      0t0  TCP 192.168.1.2:51073->95.169.2.146:443 (ESTABLISHED)
        MacPacket   808 me     22u  IPv4 0x8      0t0  TCP 192.168.1.2:51074->203.107.1.10:443 (ESTABLISHED)
        MacPacket   808 me     23u  IPv4 0x9      0t0  TCP 192.168.1.2:51075->1.1.1.1:443 (ESTABLISHED)
        """

        let index = DirectDestinationIndex(
            domains: [],
            domainSuffixes: ["bilivideo.com"],
            ipv4Networks: [
                IPv4Network(address: DirectDestinationIndex.parseIPv4("203.107.1.0") ?? 0, prefix: 24)
            ],
            policyLabels: ["BiliBili"]
        )

        let snap = ActiveAppSocketSampler.summarize(
            ActiveAppSocketSampler.parse(lsofOutput: output),
            proxyPort: 1082,
            directIndex: index
        )

        XCTAssertEqual(snap.proxyDirectEgress, 1)
        XCTAssertEqual(snap.proxyRemoteEgress, 4)
        XCTAssertEqual(snap.primaryProxyNodeIP, "95.169.2.146")
    }

    func testClashPortDiscoveryWithoutSystemProxyHint() {
        // Clash-like: clients on 7890, no explicit system-proxy hint port.
        let output = """
        COMMAND     PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        Chrome      100 me     10u  IPv4 0x1      0t0  TCP 127.0.0.1:50001->127.0.0.1:7890 (ESTABLISHED)
        Chrome      100 me     11u  IPv4 0x2      0t0  TCP 127.0.0.1:50002->127.0.0.1:7890 (ESTABLISHED)
        clash-meta  808 me     18u  IPv4 0x4      0t0  TCP 127.0.0.1:7890->127.0.0.1:50001 (ESTABLISHED)
        clash-meta  808 me     19u  IPv4 0x5      0t0  TCP 192.168.1.2:51071->198.18.0.2:443 (ESTABLISHED)
        clash-meta  808 me     20u  IPv4 0x6      0t0  TCP 192.168.1.2:51072->198.18.0.2:443 (ESTABLISHED)
        """

        let snap = ActiveAppSocketSampler.summarize(
            ActiveAppSocketSampler.parse(lsofOutput: output),
            proxyPort: nil,
            directIndex: .empty
        )

        XCTAssertTrue(snap.proxyPorts.contains(7890))
        XCTAssertTrue(snap.hasLocalProxyClient)
        let byPID = Dictionary(uniqueKeysWithValues: snap.processes.map { ($0.pid, $0) })
        XCTAssertEqual(byPID[100]?.viaProxyConnections, 2)
        XCTAssertEqual(snap.proxyRemoteEgress, 2, "non-DIRECT proxy egress counts as 翻墙")
        XCTAssertEqual(snap.proxyDirectEgress, 0)
        XCTAssertEqual(snap.primaryProxyNodeIP, "198.18.0.2")
    }

    func testViaProxyWithDirectRuleEgress() {
        let output = """
        COMMAND     PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        Chrome      100 me     10u  IPv4 0x1      0t0  TCP 127.0.0.1:50001->127.0.0.1:7890 (ESTABLISHED)
        clash-meta  808 me     18u  IPv4 0x4      0t0  TCP 127.0.0.1:7890->127.0.0.1:50001 (ESTABLISHED)
        clash-meta  808 me     19u  IPv4 0x5      0t0  TCP 192.168.1.2:51071->203.107.1.10:443 (ESTABLISHED)
        clash-meta  808 me     20u  IPv4 0x6      0t0  TCP 192.168.1.2:51072->203.107.1.11:443 (ESTABLISHED)
        """
        let index = DirectDestinationIndex(
            ipv4Networks: [
                IPv4Network(address: DirectDestinationIndex.parseIPv4("203.107.1.0") ?? 0, prefix: 24)
            ]
        )
        let snap = ActiveAppSocketSampler.summarize(
            ActiveAppSocketSampler.parse(lsofOutput: output),
            proxyPort: nil,
            directIndex: index
        )
        XCTAssertEqual(snap.proxyDirectEgress, 2)
        XCTAssertEqual(snap.proxyRemoteEgress, 0)
        XCTAssertEqual(byVia(snap, pid: 100), 1)
        XCTAssertEqual(Set(snap.proxyDirectHosts), Set(["203.107.1.10", "203.107.1.11"]))
    }

    func testProxyRemoteHostsExcludePrimaryNode() {
        let output = """
        COMMAND     PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        Google      100 me     10u  IPv4 0x1      0t0  TCP 127.0.0.1:50001->127.0.0.1:1082 (ESTABLISHED)
        MacPacket   808 me     18u  IPv4 0x4      0t0  TCP 127.0.0.1:1082->127.0.0.1:50001 (ESTABLISHED)
        MacPacket   808 me     19u  IPv4 0x5      0t0  TCP 192.168.1.2:51071->95.169.2.146:443 (ESTABLISHED)
        MacPacket   808 me     20u  IPv4 0x6      0t0  TCP 192.168.1.2:51072->95.169.2.146:443 (ESTABLISHED)
        MacPacket   808 me     21u  IPv4 0x7      0t0  TCP 192.168.1.2:51073->1.2.3.4:443 (ESTABLISHED)
        """
        let snap = ActiveAppSocketSampler.summarize(
            ActiveAppSocketSampler.parse(lsofOutput: output),
            proxyPort: 1082,
            directIndex: .empty
        )
        XCTAssertEqual(snap.primaryProxyNodeIP, "95.169.2.146")
        XCTAssertFalse(snap.proxyRemoteHosts.contains("95.169.2.146"))
        XCTAssertTrue(snap.proxyRemoteHosts.contains("1.2.3.4"))
    }

    func testBypassWithoutProxyClientIsDirectInternet() {
        let output = """
        COMMAND     PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        Safari      200 me     12u  IPv4 0x3      0t0  TCP 192.168.1.2:50003->1.1.1.1:443 (ESTABLISHED)
        """
        let snap = ActiveAppSocketSampler.summarize(
            ActiveAppSocketSampler.parse(lsofOutput: output),
            proxyPort: nil
        )
        XCTAssertFalse(snap.hasLocalProxyClient)
        XCTAssertEqual(snap.proxyPorts, [])
        let byPID = Dictionary(uniqueKeysWithValues: snap.processes.map { ($0.pid, $0) })
        XCTAssertEqual(byPID[200]?.directConnections, 1)
        XCTAssertEqual(byPID[200]?.viaProxyConnections, 0)
    }

    func testTunWeakEvidenceHasProxyEgressButNoLoopbackClients() {
        // Local proxy listening on a common port with node egress, but no app→loopback clients
        // (typical TUN / enhanced mode). Sampler identifies the client; apps stay "direct" sockets.
        let output = """
        COMMAND     PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        Safari      200 me     12u  IPv4 0x3      0t0  TCP 192.168.1.2:50003->1.1.1.1:443 (ESTABLISHED)
        clash-meta  808 me     18u  IPv4 0x4      0t0  TCP 127.0.0.1:7890->127.0.0.1:59999 (ESTABLISHED)
        clash-meta  808 me     19u  IPv4 0x5      0t0  TCP 192.168.1.2:51071->198.18.0.2:443 (ESTABLISHED)
        """
        let snap = ActiveAppSocketSampler.summarize(
            ActiveAppSocketSampler.parse(lsofOutput: output),
            proxyPort: nil
        )
        XCTAssertTrue(snap.hasLocalProxyClient)
        XCTAssertEqual(snap.proxyRemoteEgress, 1)
        let byPID = Dictionary(uniqueKeysWithValues: snap.processes.map { ($0.pid, $0) })
        // App still looks like a bypass socket at lsof layer — AppModel must not force Direct.
        XCTAssertEqual(byPID[200]?.directConnections, 1)
        XCTAssertEqual(byPID[200]?.viaProxyConnections, 0)
    }

    private func byVia(_ snap: ActiveSocketSnapshot, pid: Int32) -> Int {
        snap.processes.first(where: { $0.pid == pid })?.viaProxyConnections ?? -1
    }
}
