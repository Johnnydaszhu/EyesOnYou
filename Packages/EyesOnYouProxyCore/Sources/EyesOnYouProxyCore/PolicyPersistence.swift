import Foundation
import EyesOnYouCore
import EyesOnYouRuleEngine

/// On-disk snapshot of everything the user configured: per-app routes, rules, groups,
/// and proxy profiles.
///
/// Traffic history lives in SQLite; this is configuration, which is small, edited by
/// hand, and painful to lose — so it gets its own human-readable JSON file.
public struct PolicyArchive: Codable, Equatable, Sendable {
    /// Bumped when the shape changes so an older file can be rejected rather than
    /// half-decoded into a surprising configuration.
    public static let currentVersion = 1

    public var version: Int
    public var rules: [NetworkPolicyRule]
    public var groups: [AppGroup]
    public var assignments: [AppRouteAssignment]
    public var proxyProfiles: [ProxyProfile]
    public var savedAt: Date

    public init(
        version: Int = PolicyArchive.currentVersion,
        rules: [NetworkPolicyRule] = [],
        groups: [AppGroup] = [],
        assignments: [AppRouteAssignment] = [],
        proxyProfiles: [ProxyProfile] = [],
        savedAt: Date = Date()
    ) {
        self.version = version
        self.rules = rules
        self.groups = groups
        self.assignments = assignments
        self.proxyProfiles = proxyProfiles
        self.savedAt = savedAt
    }

    public var isEmpty: Bool {
        rules.isEmpty && groups.isEmpty && assignments.isEmpty && proxyProfiles.isEmpty
    }

    /// Capture the current configuration of a store.
    public static func capture(
        from store: PolicyStore,
        proxyProfiles: [ProxyProfile],
        at date: Date = Date()
    ) -> PolicyArchive {
        PolicyArchive(
            rules: store.allRules(),
            groups: store.allGroups(),
            assignments: store.allAssignments().map {
                AppRouteAssignment(app: $0.key, route: $0.value)
            },
            proxyProfiles: proxyProfiles,
            savedAt: date
        )
    }

    /// Apply this archive to a store, replacing whatever it currently holds.
    public func apply(to store: PolicyStore) {
        store.setRules(rules)
        store.setGroups(groups)
        store.setAssignments(
            Dictionary(assignments.map { ($0.app, $0.route) }, uniquingKeysWith: { _, last in last })
        )
    }
}

/// Reads and writes ``PolicyArchive`` as JSON.
public enum PolicyArchiveStore {
    public enum LoadError: Error, CustomStringConvertible {
        case unsupportedVersion(Int)

        public var description: String {
            switch self {
            case .unsupportedVersion(let version):
                return "policy archive version \(version) is newer than this build supports"
            }
        }
    }

    /// Default location, shared by the app and the CLI (this app is not sandboxed).
    public static var defaultURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base
            .appendingPathComponent("EyesOnYou", isDirectory: true)
            .appendingPathComponent("policy.json")
    }

    /// Load an archive, or `nil` when none has been written yet.
    ///
    /// Throws only for a file written by a *newer* build; a corrupt or unreadable file
    /// returns `nil` so a bad write can never stop the app from launching.
    public static func load(from url: URL = PolicyArchiveStore.defaultURL) throws -> PolicyArchive? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(PolicyArchive.self, from: data) else {
            return nil
        }
        guard archive.version <= PolicyArchive.currentVersion else {
            throw LoadError.unsupportedVersion(archive.version)
        }
        return archive
    }

    /// Write atomically so a crash mid-save cannot leave a truncated configuration.
    public static func save(
        _ archive: PolicyArchive,
        to url: URL = PolicyArchiveStore.defaultURL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(archive).write(to: url, options: .atomic)
    }
}
