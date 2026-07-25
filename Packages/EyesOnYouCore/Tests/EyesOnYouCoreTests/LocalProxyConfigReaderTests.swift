import XCTest
@testable import EyesOnYouCore

final class LocalProxyConfigReaderTests: XCTestCase {
    func testClashYAMLParsesDirectRules() {
        let yaml = """
        rules:
          - DOMAIN-SUFFIX,bilibili.com,DIRECT
          - DOMAIN,api.example.com,DIRECT
          - IP-CIDR,203.107.1.0/24,DIRECT
          - DOMAIN-SUFFIX,google.com,PROXY
        """
        let index = ClashConfigReader.parseYAML(yaml, label: "test")
        XCTAssertTrue(index.matches(hostOrIP: "www.bilibili.com"))
        XCTAssertTrue(index.matches(hostOrIP: "api.example.com"))
        XCTAssertTrue(index.matches(hostOrIP: "203.107.1.10"))
        XCTAssertFalse(index.matches(hostOrIP: "www.google.com"))
        XCTAssertTrue(index.policyLabels.contains("test"))
    }

    func testDirectIndexMergingUnionsPatterns() {
        let a = DirectDestinationIndex(domainSuffixes: ["a.com"], policyLabels: ["A"])
        let b = DirectDestinationIndex(
            domains: ["exact.b.com"],
            domainSuffixes: ["b.com"],
            policyLabels: ["B"]
        )
        let merged = a.merging(b)
        XCTAssertTrue(merged.matches(hostOrIP: "x.a.com"))
        XCTAssertTrue(merged.matches(hostOrIP: "exact.b.com"))
        XCTAssertEqual(merged.policyLabels, ["A", "B"])
    }

    func testLocalProxyConfigReaderFailOpenOnMissingHome() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("eyesonyou-empty-home-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let index = LocalProxyConfigReader.loadDirectIndex(homeDirectory: tmp)
        XCTAssertTrue(index.isEmpty)
    }
}
