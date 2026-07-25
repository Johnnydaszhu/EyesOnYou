import XCTest
@testable import EyesOnYouCore

final class ProjectResolverTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eyesonyou-project-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeProject(_ name: String, marker: String = ".git") throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(marker),
            withIntermediateDirectories: true
        )
        return url
    }

    func testResolvesRepoRootFromNestedWorkingDirectory() throws {
        let repo = try makeProject("EyesOnYou")
        let nested = repo.appendingPathComponent("Packages/EyesOnYouCore/Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let resolver = ProjectResolver(homeDirectory: root, excludedPathPrefixes: [])
        let project = resolver.project(forPath: nested.path)
        XCTAssertEqual(project?.name, "EyesOnYou")
        XCTAssertEqual(project?.marker, "git")
    }

    func testNestedPackageManifestDoesNotOutrankEnclosingRepo() throws {
        let repo = try makeProject("Monorepo")
        let package = repo.appendingPathComponent("Packages/Feature")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: package.appendingPathComponent("Package.swift").path,
            contents: Data()
        )

        let resolver = ProjectResolver(homeDirectory: root, excludedPathPrefixes: [])
        XCTAssertEqual(resolver.project(forPath: package.path)?.name, "Monorepo")
    }

    func testBuildManifestUsedWhenNoVersionControlRoot() throws {
        let folder = root.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: folder.appendingPathComponent("package.json").path,
            contents: Data()
        )

        let resolver = ProjectResolver(homeDirectory: root, excludedPathPrefixes: [])
        let project = resolver.project(forPath: folder.path)
        XCTAssertEqual(project?.name, "scripts")
        XCTAssertEqual(project?.marker, "node")
    }

    func testHomeDirectoryIsNotAProject() throws {
        // An agent launched from `~` must not create a bucket named after the user.
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("package.json").path,
            contents: Data()
        )
        let resolver = ProjectResolver(homeDirectory: root, excludedPathPrefixes: [])
        XCTAssertNil(resolver.project(forPath: root.path))
    }

    func testUnmarkedFolderIsNotAProject() throws {
        let folder = root.appendingPathComponent("Downloads/random")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resolver = ProjectResolver(homeDirectory: root, excludedPathPrefixes: [])
        XCTAssertNil(resolver.project(forPath: folder.path))
    }

    func testWorkspaceTitleOverridesFolderName() throws {
        let repo = try makeProject("eyes-on-you-checkout")
        let workspace = DiscoveredWorkspace(
            name: "EyesOnYou (main)",
            path: repo.path,
            sources: [.codexDesktop]
        )
        let resolver = ProjectResolver(
            workspaces: [workspace],
            homeDirectory: root,
            excludedPathPrefixes: []
        )
        XCTAssertEqual(resolver.project(forPath: repo.path)?.name, "EyesOnYou (main)")
    }

    func testUpdatingWorkspacesRefreshesCachedTitles() throws {
        let repo = try makeProject("checkout")
        let resolver = ProjectResolver(homeDirectory: root, excludedPathPrefixes: [])
        XCTAssertEqual(resolver.project(forPath: repo.path)?.name, "checkout")

        resolver.updateWorkspaces([
            DiscoveredWorkspace(name: "Renamed", path: repo.path, sources: [.cursor])
        ])
        XCTAssertEqual(resolver.project(forPath: repo.path)?.name, "Renamed")
    }

    func testProjectByNameMatchesDiscoveredWorkspacePath() throws {
        let repo = try makeProject("FlowLens")
        let resolver = ProjectResolver(
            workspaces: [DiscoveredWorkspace(name: "FlowLens", path: repo.path, sources: [.cursor])],
            homeDirectory: root,
            excludedPathPrefixes: []
        )
        let project = resolver.project(named: "flowlens")
        XCTAssertEqual(project?.name, "FlowLens")
        XCTAssertEqual(project?.path, repo.path)
    }

    func testProjectByNameFallsBackToLabelWithoutPath() {
        let resolver = ProjectResolver(homeDirectory: root, excludedPathPrefixes: [])
        let project = resolver.project(named: "Untracked Workspace")
        XCTAssertEqual(project?.name, "Untracked Workspace")
        XCTAssertEqual(project?.path, "")
        XCTAssertEqual(project?.destinationKey, "project:Untracked Workspace")
    }
}

final class AgentProcessCatalogTests: XCTestCase {
    func testMatchesAgentCLIByExecutableName() {
        let match = AgentProcessCatalog.match(
            executablePath: "/Users/me/Library/Application Support/Claude/claude-code/2.1.219/"
                + "claude.app/Contents/MacOS/claude"
        )
        XCTAssertEqual(match?.signingIdentifier, "com.anthropic.claude-code")
        XCTAssertEqual(match?.displayName, "Claude Code")
    }

    func testHomebrewCodexSharesDesktopIdentity() {
        // ChatGPT.app itself signs as com.openai.codex, so both must aggregate together.
        let match = AgentProcessCatalog.match(executablePath: "/opt/homebrew/bin/codex")
        XCTAssertEqual(match?.signingIdentifier, "com.openai.codex")
    }

    func testMatchesAgentNamedOnlyInArguments() {
        let match = AgentProcessCatalog.match(
            executablePath: "/bin/zsh",
            arguments: ["/bin/zsh", "-lc", "opencode"]
        )
        XCTAssertEqual(match?.displayName, "opencode")
    }

    func testGenericRuntimesAreRecognized() {
        XCTAssertTrue(AgentProcessCatalog.isGenericRuntime(executablePath: "/opt/homebrew/bin/node"))
        XCTAssertTrue(AgentProcessCatalog.isGenericRuntime(executablePath: "/usr/bin/python3"))
        XCTAssertFalse(
            AgentProcessCatalog.isGenericRuntime(executablePath: "/Applications/Cursor.app/Contents/MacOS/Cursor")
        )
    }

    func testWorkspaceLabelFromExtensionHostTitle() {
        XCTAssertEqual(
            AgentProcessCatalog.workspaceLabel(
                fromProcessTitle: "Cursor Helper (Plugin): extension-host EyesOnYou [1-3]"
            ),
            "EyesOnYou"
        )
        XCTAssertEqual(
            AgentProcessCatalog.workspaceLabel(
                fromProcessTitle: "Code Helper (Plugin): extension-host Agents Window [1-1]"
            ),
            "Agents Window"
        )
    }

    func testWorkspaceLabelIgnoresFolderlessWindows() {
        XCTAssertNil(
            AgentProcessCatalog.workspaceLabel(
                fromProcessTitle: "Cursor Helper (Plugin): extension-host Empty Window [1-2]"
            )
        )
        XCTAssertNil(
            AgentProcessCatalog.workspaceLabel(fromProcessTitle: "Cursor Helper (Renderer)")
        )
    }
}

final class ProcessRuntimeInfoTests: XCTestCase {
    func testReadsOwnWorkingDirectory() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let cwd = ProcessRuntimeInfo.workingDirectory(pid: pid)
        XCTAssertEqual(
            cwd.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path
        )
    }

    func testReadsOwnArgumentsAndParent() {
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertFalse(ProcessRuntimeInfo.arguments(pid: pid).isEmpty)
        XCTAssertNotNil(ProcessRuntimeInfo.executablePathFromArgs(pid: pid))
        XCTAssertNotNil(ProcessRuntimeInfo.parentPID(pid: pid))
        XCTAssertNotNil(ProcessRuntimeInfo.startTime(pid: pid))
    }

    func testEnvironmentReadIsLimitedToRequestedKeys() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let values = ProcessRuntimeInfo.environmentValues(pid: pid, keys: ["PATH"])
        XCTAssertEqual(Set(values.keys).subtracting(["PATH"]), [])
        if let path = values["PATH"] {
            XCTAssertEqual(path, ProcessInfo.processInfo.environment["PATH"])
        }
    }

    func testEmptyKeySetReadsNothing() {
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(ProcessRuntimeInfo.environmentValues(pid: pid, keys: []).isEmpty)
    }

    func testAncestorsStopAtLaunchd() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let ancestors = ProcessRuntimeInfo.ancestors(of: pid)
        XCTAssertFalse(ancestors.contains(1))
        XCTAssertFalse(ancestors.contains(pid))
    }
}

final class WorkspaceSourceOwnershipTests: XCTestCase {
    func testKnownAgentsOwnTheirSources() {
        XCTAssertEqual(
            WorkspaceDiscovery.sources(forSigningIdentifier: "com.anthropic.claude-code"),
            [.claudeCode]
        )
        XCTAssertEqual(
            WorkspaceDiscovery.sources(forSigningIdentifier: "com.todesktop.230313mzl4w4u92"),
            [.cursor]
        )
        XCTAssertEqual(
            WorkspaceDiscovery.sources(forSigningIdentifier: "com.openai.codex"),
            [.codexDesktop, .codexSession, .codexMonitor]
        )
    }

    func testCompanionToolsDoNotInheritAgentProjects() {
        // A menu-bar monitor reads Codex state without being Codex.
        XCTAssertNil(WorkspaceDiscovery.sources(forSigningIdentifier: "com.steipete.codexbar"))
        XCTAssertNil(WorkspaceDiscovery.sources(forSigningIdentifier: "com.google.Chrome"))
        XCTAssertNil(WorkspaceDiscovery.sources(forSigningIdentifier: ""))
    }
}
