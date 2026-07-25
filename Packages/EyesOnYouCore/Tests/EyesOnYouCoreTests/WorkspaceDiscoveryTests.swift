import XCTest
@testable import EyesOnYouCore

final class WorkspaceDiscoveryTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("eyesonyou-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    func testHyphenPathDecoderLongestMatch() throws {
        let github = tempRoot.appendingPathComponent("Documents/GitHub", isDirectory: true)
        let project = github.appendingPathComponent("dontbesilent-web", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let encoded = "Documents-GitHub-dontbesilent-web"
        let decoded = HyphenPathDecoder.decode(
            encoded,
            homeDirectory: tempRoot,
            fileManager: .default
        )
        XCTAssertEqual(decoded, project.standardizedFileURL.path)

        let cursorProjects = tempRoot
            .appendingPathComponent(".cursor/projects/\(encoded)", isDirectory: true)
        try FileManager.default.createDirectory(at: cursorProjects, withIntermediateDirectories: true)

        let options = WorkspaceDiscoveryOptions(
            homeDirectory: tempRoot,
            cursorHome: tempRoot.appendingPathComponent(".cursor"),
            claudeHome: tempRoot.appendingPathComponent(".claude"),
            applicationSupport: tempRoot.appendingPathComponent("Library/Application Support"),
            maxCodexSessionsToScan: 10,
            limit: 20
        )
        let found = WorkspaceDiscovery.discover(options: options)
        XCTAssertTrue(
            found.contains(where: { $0.path == project.standardizedFileURL.path }),
            "expected \(project.path) in \(found.map(\.path))"
        )
        XCTAssertTrue(found.contains(where: { $0.sources.contains(.cursor) }))
    }

    func testCodexDesktopLocalProjectsAndSessionCwd() throws {
        let projectPath = tempRoot.appendingPathComponent("Documents/GitHub/Cultivation", isDirectory: true)
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        let codexHome = tempRoot.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)

        let state: [String: Any] = [
            "local-projects": [
                "local-abc": [
                    "id": "local-abc",
                    "name": "Cultivation",
                    "rootPaths": [projectPath.path],
                    "updatedAt": 1_700_000_000_000
                ] as [String: Any]
            ],
            "active-workspace-roots": [projectPath.path],
            "pinned-project-ids": ["local-abc"]
        ]
        let stateData = try JSONSerialization.data(withJSONObject: state)
        try stateData.write(to: codexHome.appendingPathComponent(".codex-global-state.json"))

        let sessionDir = codexHome.appendingPathComponent("sessions/2026/07/25", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let meta: [String: Any] = [
            "timestamp": "2026-07-25T03:00:00.000Z",
            "type": "session_meta",
            "payload": [
                "id": "019f0000-0000-7000-8000-000000000001",
                "cwd": projectPath.path,
                "source": "cli"
            ] as [String: Any]
        ]
        let line = try JSONSerialization.data(withJSONObject: meta)
        var body = line
        body.append(contentsOf: "\n{\"type\":\"event\"}\n".utf8)
        try body.write(to: sessionDir.appendingPathComponent("rollout-test.jsonl"))

        let options = WorkspaceDiscoveryOptions(
            homeDirectory: tempRoot,
            codexHome: codexHome,
            cursorHome: tempRoot.appendingPathComponent(".cursor"),
            claudeHome: tempRoot.appendingPathComponent(".claude"),
            applicationSupport: tempRoot.appendingPathComponent("Library/Application Support"),
            maxCodexSessionsToScan: 50,
            limit: 10
        )
        let found = WorkspaceDiscovery.discover(options: options)
        XCTAssertEqual(found.count, 1)
        let row = try XCTUnwrap(found.first)
        XCTAssertEqual(row.name, "Cultivation")
        XCTAssertEqual(row.path, projectPath.standardizedFileURL.path)
        XCTAssertTrue(row.sources.contains(.codexDesktop))
        XCTAssertTrue(row.sources.contains(.codexSession))
        XCTAssertTrue(row.isPinned)
        XCTAssertTrue(row.isActive)
        XCTAssertEqual(row.sessionCount, 1)
        XCTAssertEqual(row.destinationKey, "project:cultivation")
    }

    func testCodexMonitorWorkspacesJSON() throws {
        let path = tempRoot.appendingPathComponent("Documents/GitHub/TheGreatMe", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let support = tempRoot.appendingPathComponent("Library/Application Support/com.dimillian.codexmonitor", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let list: [[String: Any]] = [
            ["id": "w1", "name": "TheGreatMe", "path": path.path, "kind": "main"]
        ]
        let data = try JSONSerialization.data(withJSONObject: list)
        try data.write(to: support.appendingPathComponent("workspaces.json"))

        let options = WorkspaceDiscoveryOptions(
            homeDirectory: tempRoot,
            codexHome: tempRoot.appendingPathComponent(".codex"),
            applicationSupport: tempRoot.appendingPathComponent("Library/Application Support"),
            limit: 10
        )
        let found = WorkspaceDiscovery.discover(options: options)
        XCTAssertTrue(found.contains(where: {
            $0.name == "TheGreatMe" && $0.sources.contains(.codexMonitor)
        }))
    }

    func testProjectsFilterBySigningID() throws {
        let vscodePath = tempRoot.appendingPathComponent("code-proj", isDirectory: true)
        let cursorPath = tempRoot.appendingPathComponent("cursor-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: vscodePath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cursorPath, withIntermediateDirectories: true)

        let support = tempRoot.appendingPathComponent("Library/Application Support", isDirectory: true)
        try writeStorage(
            at: support.appendingPathComponent("Code/User/globalStorage/storage.json"),
            folderURI: URL(fileURLWithPath: vscodePath.path).absoluteString
        )
        try writeStorage(
            at: support.appendingPathComponent("Cursor/User/globalStorage/storage.json"),
            folderURI: URL(fileURLWithPath: cursorPath.path).absoluteString
        )

        let options = WorkspaceDiscoveryOptions(
            homeDirectory: tempRoot,
            applicationSupport: support,
            limit: 20
        )
        let vscode = WorkspaceDiscovery.projects(
            forSigningIdentifier: "com.microsoft.VSCode",
            options: options
        )
        let cursor = WorkspaceDiscovery.projects(
            forSigningIdentifier: "com.todesktop.230313mzl4w4u92",
            options: options
        )
        XCTAssertTrue(vscode.contains(where: { $0.path == vscodePath.standardizedFileURL.path }))
        XCTAssertTrue(cursor.contains(where: { $0.path == cursorPath.standardizedFileURL.path }))
        XCTAssertFalse(vscode.contains(where: { $0.path == cursorPath.standardizedFileURL.path }))
    }

    func testDrillableIdentityTreatsCodexAndCursorAsProjects() {
        let codex = AppIdentityKey(teamIdentifier: "2DC432GLL2", signingIdentifier: "com.openai.codex")
        let cursor = AppIdentityKey(teamIdentifier: "VDXQ22DGB9", signingIdentifier: "com.todesktop.230313mzl4w4u92")
        let claude = AppIdentityKey(teamIdentifier: "Q6L2SF6YDW", signingIdentifier: "com.anthropic.claudefordesktop")
        XCTAssertEqual(DrillableIdentity.segmentKind(for: codex), .project)
        XCTAssertEqual(DrillableIdentity.segmentKind(for: cursor), .project)
        XCTAssertEqual(DrillableIdentity.segmentKind(for: claude), .project)
    }

    func testDemoSeederUsesDiscoveredDestinationKeys() throws {
        let projectPath = tempRoot.appendingPathComponent("Documents/GitHub/EyesOnYou", isDirectory: true)
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
        let codexHome = tempRoot.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let state: [String: Any] = [
            "local-projects": [
                "local-1": [
                    "id": "local-1",
                    "name": "EyesOnYou",
                    "rootPaths": [projectPath.path],
                    "updatedAt": 1_700_000_000_000
                ] as [String: Any]
            ]
        ]
        try JSONSerialization.data(withJSONObject: state)
            .write(to: codexHome.appendingPathComponent(".codex-global-state.json"))

        let options = WorkspaceDiscoveryOptions(
            homeDirectory: tempRoot,
            codexHome: codexHome,
            cursorHome: tempRoot.appendingPathComponent(".cursor"),
            claudeHome: tempRoot.appendingPathComponent(".claude"),
            applicationSupport: tempRoot.appendingPathComponent("Library/Application Support"),
            limit: 10
        )
        let agg = TelemetryAggregator()
        DemoTrafficSeeder.seed(into: agg, discoveryOptions: options)
        let now = Date()
        let apps = agg.topApps(
            from: now.addingTimeInterval(-86_400),
            to: now.addingTimeInterval(86_400),
            limit: 20,
            preferredGranularity: .oneMinute,
            includeSitesForBrowsers: true
        )
        let chatgpt = apps.first { $0.app.signingIdentifier == "com.openai.codex" }
        XCTAssertNotNil(chatgpt)
        XCTAssertTrue(
            chatgpt?.sites.contains(where: { $0.destinationKey == "project:eyesonyou" }) == true,
            "sites=\(chatgpt?.sites.map(\.destinationKey) ?? [])"
        )
    }

    // MARK: - Helpers

    private func writeStorage(at url: URL, folderURI: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let obj: [String: Any] = [
            "profileAssociations": [
                "workspaces": [folderURI: "__default__profile__"]
            ]
        ]
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
    }

}
