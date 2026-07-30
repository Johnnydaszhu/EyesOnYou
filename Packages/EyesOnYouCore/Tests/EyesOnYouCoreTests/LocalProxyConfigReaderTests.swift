import XCTest
import SQLite3
@testable import EyesOnYouCore

final class LocalProxyConfigReaderTests: XCTestCase {
    func testClashYAMLParsesDirectRules() {
        let yaml = """
        rules:
          - DOMAIN-SUFFIX,bilibili.com,DIRECT
          - DOMAIN,api.example.com,DIRECT
          - DOMAIN-KEYWORD,jianying,DIRECT
          - IP-CIDR,203.107.1.0/24,DIRECT
          - DOMAIN-SUFFIX,google.com,PROXY
        """
        let index = ClashConfigReader.parseYAML(yaml, label: "test")
        XCTAssertTrue(index.matches(hostOrIP: "www.bilibili.com"))
        XCTAssertTrue(index.matches(hostOrIP: "api.example.com"))
        XCTAssertTrue(index.matches(hostOrIP: "api.jianyingpro.com"))
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

    func testShadowrocketSelectedDatabaseParsesDirectRulesAndCachedRuleSet() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let databaseDirectory = home.appendingPathComponent(
            "Library/Containers/com.liguangming.Shadowrocket/Data/Documents/Databases",
            isDirectory: true
        )
        let cacheDirectory = home.appendingPathComponent(
            "Library/Containers/com.liguangming.Shadowrocket/Data/Library/Caches",
            isDirectory: true
        )
        let preferencesURL = home.appendingPathComponent(
            "Library/Group Containers/group.com.liguangming.Shadowrocket/Library/Preferences/group.com.liguangming.Shadowrocket.plist"
        )
        try FileManager.default.createDirectory(
            at: databaseDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: preferencesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try makeShadowrocketDatabase(
            at: databaseDirectory.appendingPathComponent("selected.db"),
            rows: [
                ("DOMAIN-SUFFIX", "example.cn", "DIRECT"),
                ("DOMAIN-KEYWORD", "jianying", "DIRECT"),
                ("IP-CIDR", "203.0.113.0/24", "DIRECT"),
                ("RULE-SET", "https://example.invalid/rules/China.list", "DIRECT"),
                ("DOMAIN-SUFFIX", "proxy.example", "PROXY"),
            ]
        )
        // A newer inactive database must not replace the explicitly selected one.
        try makeShadowrocketDatabase(
            at: databaseDirectory.appendingPathComponent("inactive.db"),
            rows: [("DOMAIN-SUFFIX", "inactive.example", "DIRECT")]
        )
        let preferences: [String: Any] = [
            "group.com.liguangming.CurrentRuleFileName": "selected.db"
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: preferences,
            format: .binary,
            options: 0
        )
        try plist.write(to: preferencesURL)
        try """
        # NAME: China
        DOMAIN-SUFFIX,cached.cn
        IP-CIDR,198.51.100.0/24
        """.write(
            to: cacheDirectory.appendingPathComponent("rule-set-fixture.tmp"),
            atomically: true,
            encoding: .utf8
        )

        let index = ShadowrocketConfigReader.loadDirectIndex(homeDirectory: home)
        XCTAssertTrue(index.matches(hostOrIP: "api.example.cn"))
        XCTAssertTrue(index.matches(hostOrIP: "www.jianyingpro.com"))
        XCTAssertTrue(index.matches(hostOrIP: "203.0.113.42"))
        XCTAssertTrue(index.matches(hostOrIP: "assets.cached.cn"))
        XCTAssertTrue(index.matches(hostOrIP: "198.51.100.7"))
        XCTAssertFalse(index.matches(hostOrIP: "proxy.example"))
        XCTAssertFalse(index.matches(hostOrIP: "inactive.example"))
    }

    func testShadowrocketLegacyActiveConfBeatsNewerBackupAndParsesInlineDirect() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let tmp = home.appendingPathComponent(
            "Library/Containers/com.liguangming.Shadowrocket/Data/tmp",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let active = tmp.appendingPathComponent("lazy_group.conf")
        let backup = tmp.appendingPathComponent("lazy_group.conf.bak-newer")
        try """
        DOMAIN-SUFFIX,active.example,DIRECT
        DOMAIN-KEYWORD,jianying,DIRECT
        IP-CIDR,203.0.113.0/24,DIRECT
        """.write(to: active, atomically: true, encoding: .utf8)
        try "DOMAIN-SUFFIX,stale.example,DIRECT\n".write(
            to: backup,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: backup.path
        )

        let index = ShadowrocketConfigReader.loadDirectIndex(homeDirectory: home)
        XCTAssertTrue(index.matches(hostOrIP: "api.active.example"))
        XCTAssertTrue(index.matches(hostOrIP: "api.jianyingpro.com"))
        XCTAssertTrue(index.matches(hostOrIP: "203.0.113.9"))
        XCTAssertFalse(index.matches(hostOrIP: "api.stale.example"))
    }

    func testLocalProxyConfigReaderFailOpenOnMissingHome() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("eyesonyou-empty-home-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let index = LocalProxyConfigReader.loadDirectIndex(homeDirectory: tmp)
        XCTAssertTrue(index.isEmpty)
    }

    private func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "eyesonyou-shadowrocket-home-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private func makeShadowrocketDatabase(
        at url: URL,
        rows: [(name: String, value: String, option: String)]
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "LocalProxyConfigReaderTests", code: 1)
        }
        defer { sqlite3_close(database) }

        let create = """
        CREATE TABLE config (
            section TEXT,
            name TEXT,
            value TEXT,
            option TEXT
        );
        """
        guard sqlite3_exec(database, create, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "LocalProxyConfigReaderTests", code: 2)
        }

        var statement: OpaquePointer?
        let insert = "INSERT INTO config(section, name, value, option) VALUES('rule', ?, ?, ?)"
        guard sqlite3_prepare_v2(database, insert, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw NSError(domain: "LocalProxyConfigReaderTests", code: 3)
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for row in rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, row.name, -1, transient)
            sqlite3_bind_text(statement, 2, row.value, -1, transient)
            sqlite3_bind_text(statement, 3, row.option, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "LocalProxyConfigReaderTests", code: 4)
            }
        }
    }
}
