import XCTest
@testable import EyesOnYouProxyCore

/// A fake `networksetup` that records commands and answers queries from an in-memory
/// model — so takeover/restore is tested without touching the machine.
private final class FakeNetworkSetup: @unchecked Sendable {
    struct Proxy { var enabled = false; var host = ""; var port = 0 }
    struct Service { var web = Proxy(); var secure = Proxy() }

    var services: [String: Service]
    let enabledOrder: [String]
    private(set) var commands: [[String]] = []
    private let lock = NSLock()

    init(services: [String: Service], order: [String]) {
        self.services = services
        self.enabledOrder = order
    }

    func run(_ args: [String]) -> (status: Int32, output: String) {
        lock.lock(); defer { lock.unlock() }
        commands.append(args)
        guard let verb = args.first else { return (1, "") }

        switch verb {
        case "-listallnetworkservices":
            let lines = ["An asterisk (*) denotes that a network service is disabled."]
                + enabledOrder
            return (0, lines.joined(separator: "\n"))
        case "-getwebproxy", "-getsecurewebproxy":
            let svc = services[args[1]] ?? Service()
            let p = verb == "-getwebproxy" ? svc.web : svc.secure
            return (0, "Enabled: \(p.enabled ? "Yes" : "No")\nServer: \(p.host)\nPort: \(p.port)\n")
        case "-setwebproxy":
            services[args[1], default: Service()].web = Proxy(enabled: true, host: args[2], port: Int(args[3]) ?? 0)
            return (0, "")
        case "-setsecurewebproxy":
            services[args[1], default: Service()].secure = Proxy(enabled: true, host: args[2], port: Int(args[3]) ?? 0)
            return (0, "")
        case "-setwebproxystate":
            services[args[1], default: Service()].web.enabled = (args[2] == "on")
            return (0, "")
        case "-setsecurewebproxystate":
            services[args[1], default: Service()].secure.enabled = (args[2] == "on")
            return (0, "")
        default:
            return (1, "unknown \(verb)")
        }
    }
}

final class SystemProxyControllerTests: XCTestCase {
    private var dir: URL!
    private var backupURL: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eyesonyou-sysproxy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        backupURL = dir.appendingPathComponent("proxy-backup.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testTakeoverCapturesUpstreamAndPointsAtLocalProxy() throws {
        // Wi-Fi already routes through Shadowrocket at 127.0.0.1:1082.
        let fake = FakeNetworkSetup(
            services: [
                "Wi-Fi": .init(
                    web: .init(enabled: true, host: "127.0.0.1", port: 1082),
                    secure: .init(enabled: true, host: "127.0.0.1", port: 1082)
                )
            ],
            order: ["Wi-Fi"]
        )
        let controller = SystemProxyController(backupURL: backupURL, runner: fake.run)

        let backup = try controller.takeOver(localPort: 9099)
        // Upstream is what was there before, so tunneling still works after chaining.
        XCTAssertEqual(backup.upstream, ProxyUpstream(kind: .http, host: "127.0.0.1", port: 1082))
        // The live setting now points at us.
        XCTAssertEqual(fake.services["Wi-Fi"]?.secure.host, "127.0.0.1")
        XCTAssertEqual(fake.services["Wi-Fi"]?.secure.port, 9099)
        XCTAssertTrue(fake.services["Wi-Fi"]?.web.enabled ?? false)
        // Backup persisted before any change.
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testRestorePutsBackTheOriginalUpstreamAndDeletesBackup() throws {
        let fake = FakeNetworkSetup(
            services: [
                "Wi-Fi": .init(
                    web: .init(enabled: true, host: "127.0.0.1", port: 1082),
                    secure: .init(enabled: true, host: "127.0.0.1", port: 1082)
                )
            ],
            order: ["Wi-Fi"]
        )
        let controller = SystemProxyController(backupURL: backupURL, runner: fake.run)
        _ = try controller.takeOver(localPort: 9099)

        XCTAssertTrue(controller.restoreIfNeeded())
        XCTAssertEqual(fake.services["Wi-Fi"]?.secure.port, 1082, "original upstream restored")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path), "backup consumed")
        XCTAssertFalse(controller.restoreIfNeeded(), "second restore is a no-op")
    }

    func testRestoreDisablesProxyThatWasOffBefore() throws {
        // No proxy configured initially.
        let fake = FakeNetworkSetup(services: ["Wi-Fi": .init()], order: ["Wi-Fi"])
        let controller = SystemProxyController(backupURL: backupURL, runner: fake.run)
        _ = try controller.takeOver(localPort: 9099)
        XCTAssertTrue(fake.services["Wi-Fi"]?.web.enabled ?? false)

        _ = controller.restoreIfNeeded()
        XCTAssertFalse(fake.services["Wi-Fi"]?.web.enabled ?? true, "must turn the proxy back off")
        XCTAssertFalse(fake.services["Wi-Fi"]?.secure.enabled ?? true)
    }

    func testCrashRecoveryRestoresFromBackupWrittenByAPriorProcess() throws {
        // Simulate: prior run took over, then crashed (backup on disk, live still ours).
        let fake = FakeNetworkSetup(
            services: [
                "Wi-Fi": .init(
                    web: .init(enabled: true, host: "127.0.0.1", port: 9099),
                    secure: .init(enabled: true, host: "127.0.0.1", port: 9099)
                )
            ],
            order: ["Wi-Fi"]
        )
        let backup = SystemProxyBackup(savedAt: Date(), services: [
            ServiceProxyState(
                service: "Wi-Fi",
                webEnabled: true, webHost: "127.0.0.1", webPort: 1082,
                secureEnabled: true, secureHost: "127.0.0.1", securePort: 1082
            )
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(backup).write(to: backupURL)

        let controller = SystemProxyController(backupURL: backupURL, runner: fake.run)
        XCTAssertTrue(controller.hasPendingBackup)
        XCTAssertTrue(controller.restoreIfNeeded())
        XCTAssertEqual(fake.services["Wi-Fi"]?.secure.port, 1082)
    }

    func testParsesOnlyEnabledServices() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        Wi-Fi
        iPhone USB
        *Thunderbolt Bridge
        """
        XCTAssertEqual(SystemProxyController.parseServices(output), ["Wi-Fi", "iPhone USB"])
    }

    func testNetworkSetupRunnerTerminatesAtDeadline() {
        let started = Date()
        let result = SystemProxyController.networksetup(
            ["2"],
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            timeout: 0.05
        )

        XCTAssertEqual(result.status, -1)
        XCTAssertTrue(result.output.contains("timed out"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testNetworkSetupRunnerCapturesStandardError() {
        let result = SystemProxyController.networksetup(
            ["-c", "echo failure-message >&2; exit 7"],
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            timeout: 1
        )

        XCTAssertEqual(result.status, 7)
        XCTAssertTrue(result.output.contains("failure-message"))
    }
}
