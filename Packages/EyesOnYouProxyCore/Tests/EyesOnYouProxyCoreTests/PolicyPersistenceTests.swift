import XCTest
@testable import EyesOnYouProxyCore
import EyesOnYouCore
import EyesOnYouRuleEngine

final class PolicyPersistenceTests: XCTestCase {
    private var directory: URL!
    private var url: URL!

    private let chrome = AppIdentityKey(teamIdentifier: "EQHXZ8M8AV", signingIdentifier: "com.google.Chrome")
    private let claude = AppIdentityKey(teamIdentifier: nil, signingIdentifier: "com.anthropic.claude-code")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eyesonyou-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("policy.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeConfiguredStore() -> (PolicyStore, ProxyProfile) {
        let store = PolicyStore()
        let profile = ProxyProfile(name: "Office SOCKS5", kind: .socks5, host: "127.0.0.1", port: 1080)
        store.assignRoute(app: claude, route: .proxy(profileID: profile.id))
        store.assignRoute(app: chrome, route: .direct)
        store.upsert(group: AppGroup(name: "Media", memberKeys: [chrome], defaultRoute: .direct))
        store.upsert(rule: NetworkPolicyRule(
            priority: 100,
            app: .exact(claude),
            destination: .hostnameExact("api.anthropic.com"),
            firewall: .allow,
            route: .proxy(profileID: profile.id),
            note: "Claude via SOCKS5"
        ))
        return (store, profile)
    }

    func testRoundTripRestoresEveryConfiguredDimension() throws {
        let (store, profile) = makeConfiguredStore()
        try PolicyArchiveStore.save(
            PolicyArchive.capture(from: store, proxyProfiles: [profile]),
            to: url
        )

        let loaded = try XCTUnwrap(try PolicyArchiveStore.load(from: url))
        let restored = PolicyStore()
        loaded.apply(to: restored)

        XCTAssertEqual(restored.assignment(for: chrome), .direct)
        XCTAssertEqual(restored.assignment(for: claude), .proxy(profileID: profile.id))
        XCTAssertEqual(restored.allGroups().map(\.name), ["Media"])
        XCTAssertEqual(restored.allRules().map(\.note), ["Claude via SOCKS5"])
        XCTAssertEqual(loaded.proxyProfiles.map(\.id), [profile.id])
    }

    func testApplyReplacesRatherThanAppends() throws {
        let (store, profile) = makeConfiguredStore()
        let archive = PolicyArchive.capture(from: store, proxyProfiles: [profile])

        // Applying twice must not duplicate rules or groups.
        let target = PolicyStore()
        archive.apply(to: target)
        archive.apply(to: target)
        XCTAssertEqual(target.allRules().count, 1)
        XCTAssertEqual(target.allGroups().count, 1)
        XCTAssertEqual(target.allAssignments().count, 2)
    }

    func testInheritAssignmentsAreNotPersisted() throws {
        let store = PolicyStore()
        store.assignRoute(app: chrome, route: .direct)
        store.assignRoute(app: chrome, route: .inherit)

        let archive = PolicyArchive.capture(from: store, proxyProfiles: [])
        XCTAssertTrue(archive.assignments.isEmpty)
        XCTAssertTrue(archive.isEmpty)
    }

    func testLoadReturnsNilWhenNothingSaved() throws {
        XCTAssertNil(try PolicyArchiveStore.load(from: url))
    }

    func testCorruptFileDoesNotThrow() throws {
        try Data("not json".utf8).write(to: url)
        // A bad file must never stop the app from launching.
        XCTAssertNil(try PolicyArchiveStore.load(from: url))
    }

    func testArchiveFromNewerBuildIsRejected() throws {
        var archive = PolicyArchive()
        archive.version = PolicyArchive.currentVersion + 1
        try PolicyArchiveStore.save(archive, to: url)

        XCTAssertThrowsError(try PolicyArchiveStore.load(from: url)) { error in
            guard case PolicyArchiveStore.LoadError.unsupportedVersion = error else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
        }
    }

    func testSaveCreatesMissingDirectories() throws {
        let nested = directory
            .appendingPathComponent("a/b/c", isDirectory: true)
            .appendingPathComponent("policy.json")
        try PolicyArchiveStore.save(PolicyArchive(proxyProfiles: []), to: nested)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }
}
