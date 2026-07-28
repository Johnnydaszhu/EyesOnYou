import XCTest
@testable import EyesOnYouCore

final class RemoteDestinationTests: XCTestCase {
    func testResolvedHostnameWinsOverAddress() {
        XCTAssertEqual(
            RemoteDestination.label(host: "140.82.121.4", resolved: "lb-140-82-121-4.github.com"),
            "lb-140-82-121-4.github.com"
        )
    }

    func testUnresolvedPublicAddressIsKept() {
        // A real peer address is still actionable, so it stays as the destination.
        XCTAssertEqual(RemoteDestination.label(host: "140.82.121.4"), "140.82.121.4")
    }

    func testProxyPlaceholderAddressesAreNotDestinations() {
        // Clash / Shadowrocket fake-IP TUN hands out 198.18.0.0/15; the address
        // identifies a slot in the proxy's table, not a site anyone visited.
        XCTAssertTrue(RemoteDestination.isProxyPlaceholderAddress("198.18.0.20"))
        XCTAssertTrue(RemoteDestination.isProxyPlaceholderAddress("198.19.255.255"))
        XCTAssertNil(RemoteDestination.label(host: "198.18.0.20"))
        XCTAssertNil(RemoteDestination.label(host: "240.1.2.3"))
    }

    func testNeighbouringRangesAreRealDestinations() {
        XCTAssertFalse(RemoteDestination.isProxyPlaceholderAddress("198.17.255.255"))
        XCTAssertFalse(RemoteDestination.isProxyPlaceholderAddress("198.20.0.1"))
        XCTAssertFalse(RemoteDestination.isProxyPlaceholderAddress("17.57.145.55"))
        XCTAssertEqual(RemoteDestination.label(host: "198.20.0.1"), "198.20.0.1")
    }

    func testPlaceholderWithResolvedNameStillUsesTheName() {
        // If the proxy did publish a name for its own placeholder, that name is real.
        XCTAssertEqual(
            RemoteDestination.label(host: "198.18.0.20", resolved: "api.anthropic.com"),
            "api.anthropic.com"
        )
    }

    func testHostnamesPassThroughLowercased() {
        XCTAssertEqual(RemoteDestination.label(host: "API.Anthropic.com"), "api.anthropic.com")
        XCTAssertNil(RemoteDestination.label(host: "   "))
    }

    func testSocketSamplerLabelsDirectPeersWithResolvedNames() throws {
        let lines = ActiveAppSocketSampler.parse(lsofOutput: """
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        Chrome  4242 me     20u  IPv4 0x1      0t0     TCP 192.168.1.10:52000->140.82.121.4:443 (ESTABLISHED)
        Chrome  4242 me     21u  IPv4 0x2      0t0     TCP 192.168.1.10:52001->198.18.0.20:443 (ESTABLISHED)
        """)
        let snapshot = ActiveAppSocketSampler.summarize(
            lines,
            proxyPort: nil,
            resolvedHosts: ["140.82.121.4": "github.com"]
        )
        let chrome = try XCTUnwrap(snapshot.processes.first { $0.pid == 4242 })
        XCTAssertEqual(chrome.remoteHosts, ["github.com"], "placeholder address must not be a host")
        XCTAssertEqual(chrome.directConnections, 1, "only the real peer is direct")
        // The fake-IP socket terminates at the proxy's TUN — per-app proxy evidence.
        XCTAssertEqual(chrome.viaProxyConnections, 1)
        XCTAssertTrue(snapshot.hasLocalProxyClient)
    }

    func testFakeIPOnlyClientCountsAsViaProxyWithoutLoopbackListener() throws {
        // Enhanced/TUN mode: no loopback proxy port visible at all.
        let lines = ActiveAppSocketSampler.parse(lsofOutput: """
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        Chrome  4242 me     20u  IPv4 0x1      0t0     TCP 192.168.1.10:52000->198.18.0.5:443 (ESTABLISHED)
        """)
        let snapshot = ActiveAppSocketSampler.summarize(lines, proxyPort: nil)
        let chrome = try XCTUnwrap(snapshot.processes.first { $0.pid == 4242 })
        XCTAssertEqual(chrome.viaProxyConnections, 1)
        XCTAssertEqual(chrome.directConnections, 0)
        XCTAssertTrue(chrome.remoteHosts.isEmpty)
        XCTAssertTrue(snapshot.hasLocalProxyClient)
    }
}

final class RouteByteShareByAppTests: XCTestCase {
    private let chrome = AppIdentityKey(teamIdentifier: nil, signingIdentifier: "com.google.Chrome")
    private let slack = AppIdentityKey(teamIdentifier: nil, signingIdentifier: "com.tinyspeck.slackmacgap")

    private func record(
        _ app: AppIdentityKey,
        route: RouteAction,
        destination: String,
        bytes: UInt64,
        into aggregator: TelemetryAggregator,
        at: Date
    ) {
        let flow = FlowDescriptor(app: app, remoteHostname: destination, openedAt: at)
        aggregator.recordOpen(flow, displayName: app.signingIdentifier, route: route)
        aggregator.recordDelta(
            flowID: flow.id,
            app: app,
            up: bytes / 2,
            down: bytes - bytes / 2,
            at: at,
            route: route,
            destinationKey: destination
        )
    }

    func testPerAppSplitReflectsRecordedRoutes() {
        let now = Date()
        let aggregator = TelemetryAggregator()
        // Chrome: 300 bytes via proxy node (YouTube), 100 direct by rule (bilibili).
        record(chrome, route: .systemProxy, destination: DestinationKey.viaProxyNode,
               bytes: 300, into: aggregator, at: now)
        record(chrome, route: .direct, destination: DestinationKey.directByRule,
               bytes: 100, into: aggregator, at: now)
        // Slack: purely direct.
        record(slack, route: .direct, destination: "wss-primary.slack.com",
               bytes: 500, into: aggregator, at: now)

        let shares = aggregator.routeByteShareByApp(
            from: now.addingTimeInterval(-60),
            to: now.addingTimeInterval(60),
            preferredGranularity: .oneMinute
        )
        XCTAssertEqual(shares[chrome]?.proxied, 300)
        XCTAssertEqual(shares[chrome]?.direct, 100)
        XCTAssertEqual(shares[slack]?.proxied, 0)
        XCTAssertEqual(shares[slack]?.direct, 500)
        XCTAssertNil(shares[AppIdentityKey(teamIdentifier: nil, signingIdentifier: "com.idle.App")])
    }

    func testPathKeysSurviveDestinationNormalization() {
        XCTAssertEqual(DestinationKey.make(hostname: "path:proxy", address: nil), "path:proxy")
        XCTAssertEqual(DestinationKey.make(hostname: "PATH:direct", address: nil), "path:direct")
    }

    func testUnknownRouteBytesAreNotReportedAsDirect() {
        let now = Date()
        let aggregator = TelemetryAggregator()
        let unknownApp = AppIdentityKey(
            teamIdentifier: nil,
            signingIdentifier: "com.example.unattributed"
        )
        aggregator.recordDelta(
            flowID: UUID(),
            app: unknownApp,
            up: 10,
            down: 90,
            at: now,
            routeKindOverride: .unknown
        )

        let byApp = aggregator.routeByteShareByApp(
            from: now.addingTimeInterval(-1),
            to: now.addingTimeInterval(1),
            preferredGranularity: .oneSecond
        )
        XCTAssertNil(byApp[unknownApp])

        let overall = aggregator.routeByteShare(
            for: nil,
            from: now.addingTimeInterval(-1),
            to: now.addingTimeInterval(1)
        )
        XCTAssertEqual(overall.direct, 0)
        XCTAssertEqual(overall.systemProxy, 0)
        XCTAssertEqual(overall.customProxy, 0)
    }
}
