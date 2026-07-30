import XCTest
@testable import EyesOnYouCore

final class ClashControllerTests: XCTestCase {

    // MARK: - Config parsing

    func testParsesControllerAndSecretFromYAML() {
        let yaml = """
        port: 7890
        socks-port: 7891
        external-controller: 127.0.0.1:9090
        secret: "s3cret"
        dns:
          external-controller: 1.2.3.4:9999
        """
        let endpoint = ClashConfigParser.endpoint(fromYAML: yaml)
        XCTAssertEqual(endpoint?.baseURL.absoluteString, "http://127.0.0.1:9090")
        XCTAssertEqual(endpoint?.secret, "s3cret")
    }

    func testNormalizesWildcardAndBarePortBinds() {
        XCTAssertEqual(
            ClashConfigParser.endpoint(fromYAML: "external-controller: 0.0.0.0:9090")?
                .baseURL.absoluteString,
            "http://127.0.0.1:9090"
        )
        let bare = ClashConfigParser.endpoint(fromYAML: "external-controller: ':9090'")
        XCTAssertEqual(bare?.baseURL.absoluteString, "http://127.0.0.1:9090")
        XCTAssertNil(bare?.secret)
    }

    func testIgnoresCommentsAndMissingController() {
        XCTAssertNil(ClashConfigParser.endpoint(fromYAML: "# external-controller: 127.0.0.1:9090"))
        XCTAssertNil(ClashConfigParser.endpoint(fromYAML: "port: 7890"))
        XCTAssertNil(ClashConfigParser.endpoint(fromYAML: "external-controller: ''"))
    }

    // MARK: - /connections decoding + rollup

    private let connectionsFixture = """
    {
      "downloadTotal": 1000,
      "uploadTotal": 500,
      "connections": [
        {
          "id": "a",
          "upload": 10, "download": 20,
          "chains": ["HK-01", "Auto", "Proxies"],
          "rule": "RuleSet",
          "metadata": {
            "network": "tcp", "host": "chatgpt.com",
            "destinationIP": "1.2.3.4", "destinationPort": "443",
            "processPath": "/Applications/Telegram.app/Contents/MacOS/Telegram",
            "process": "Telegram"
          }
        },
        {
          "id": "b",
          "upload": 1, "download": 2,
          "chains": ["DIRECT"],
          "rule": "Match",
          "metadata": {
            "network": "tcp", "host": "baidu.com",
            "processPath": "/Applications/Safari.app/Contents/MacOS/Safari",
            "process": "Safari"
          }
        },
        {
          "id": "c",
          "upload": 0, "download": 0,
          "chains": ["REJECT"],
          "rule": "AdBlock",
          "metadata": { "network": "tcp", "host": "ads.example", "process": "Safari" }
        },
        {
          "id": "d",
          "upload": 5, "download": 5,
          "chains": ["HK-01"],
          "rule": "Match",
          "metadata": { "network": "udp", "host": "", "process": "" }
        }
      ]
    }
    """

    func testDecodesAndRollsUpEvidence() throws {
        let snapshot = try JSONDecoder().decode(
            ClashConnectionsSnapshot.self,
            from: Data(connectionsFixture.utf8)
        )
        let evidence = ClashRouteEvidence.build(from: snapshot)

        XCTAssertEqual(evidence.totalConnections, 4)
        XCTAssertEqual(evidence.proxiedConnections, 2)
        XCTAssertEqual(evidence.directConnections, 1)
        XCTAssertEqual(evidence.rejectedConnections, 1)

        let telegram = evidence.byProcess["/Applications/Telegram.app/Contents/MacOS/Telegram"]
        XCTAssertEqual(telegram?.proxied, 1)
        XCTAssertEqual(telegram?.definiteRoute, .proxied(node: ""))

        let safari = evidence.byProcess["/Applications/Safari.app/Contents/MacOS/Safari"]
        XCTAssertEqual(safari?.direct, 1)
        XCTAssertEqual(safari?.definiteRoute, .direct)

        // Connection "d" has no process info — counted host-wide, attributed to no app.
        XCTAssertEqual(evidence.byProcess.count, 2)
    }

    func testMixedEvidenceYieldsNoDefiniteRoute() {
        let counts = ClashRouteEvidence.Counts(proxied: 3, direct: 2)
        XCTAssertNil(counts.definiteRoute, "mixed routes must stay undecided, never rounded")
    }

    // MARK: - Client transport

    func testClientSendsBearerSecretAndDecodes() async throws {
        let endpoint = ClashControllerEndpoint(
            baseURL: URL(string: "http://127.0.0.1:9090")!,
            secret: "s3cret"
        )
        let fixture = connectionsFixture
        let client = ClashControllerClient(endpoint: endpoint) { request in
            XCTAssertEqual(request.url?.path, "/connections")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer s3cret")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(fixture.utf8), response)
        }
        let snapshot = try await client.connections()
        XCTAssertEqual(snapshot.connections?.count, 4)
    }

    func testClientRejectsUnauthorized() async {
        let endpoint = ClashControllerEndpoint(baseURL: URL(string: "http://127.0.0.1:9090")!)
        let client = ClashControllerClient(endpoint: endpoint) { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
        do {
            _ = try await client.connections()
            XCTFail("401 must throw")
        } catch {
            // expected
        }
        let reachable = await client.isReachable()
        XCTAssertFalse(reachable)
    }
}
