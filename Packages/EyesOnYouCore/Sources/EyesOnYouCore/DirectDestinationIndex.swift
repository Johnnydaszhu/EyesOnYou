import Foundation

public struct IPv4Network: Equatable, Sendable {
    public var address: UInt32
    public var prefix: Int

    public init(address: UInt32, prefix: Int) {
        self.address = address
        self.prefix = prefix
    }
}

/// Host / IP patterns that a local proxy config marks as DIRECT (e.g. Shadowrocket 哔哩哔哩).
public struct DirectDestinationIndex: Equatable, Sendable {
    public var domains: Set<String>
    public var domainSuffixes: [String]
    public var ipv4Networks: [IPv4Network]
    /// Human labels of DIRECT policy groups that contributed rules (e.g. "哔哩哔哩").
    public var policyLabels: [String]

    public init(
        domains: Set<String> = [],
        domainSuffixes: [String] = [],
        ipv4Networks: [IPv4Network] = [],
        policyLabels: [String] = []
    ) {
        self.domains = domains
        self.domainSuffixes = domainSuffixes
        self.ipv4Networks = ipv4Networks
        self.policyLabels = policyLabels
    }

    public static let empty = DirectDestinationIndex()

    public var isEmpty: Bool {
        domains.isEmpty && domainSuffixes.isEmpty && ipv4Networks.isEmpty
    }

    /// Merge another index (union). Labels are appended in order without duplicates.
    public func merging(_ other: DirectDestinationIndex) -> DirectDestinationIndex {
        let domains = self.domains.union(other.domains)
        var suffixes = domainSuffixes
        for s in other.domainSuffixes where !suffixes.contains(s) {
            suffixes.append(s)
        }
        var networks = ipv4Networks
        for net in other.ipv4Networks where !networks.contains(net) {
            networks.append(net)
        }
        var labels = policyLabels
        for label in other.policyLabels where !labels.contains(label) {
            labels.append(label)
        }
        return DirectDestinationIndex(
            domains: domains,
            domainSuffixes: suffixes,
            ipv4Networks: networks,
            policyLabels: labels
        )
    }

    public func matches(hostOrIP raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return false }
        if let ip = Self.parseIPv4(value) {
            return matches(ipv4: ip)
        }
        return matches(hostname: value)
    }

    public func matches(hostname raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return false }
        if domains.contains(host) { return true }
        for suffix in domainSuffixes {
            if host == suffix || host.hasSuffix("." + suffix) {
                return true
            }
        }
        return false
    }

    public func matches(ipv4: UInt32) -> Bool {
        for net in ipv4Networks {
            let prefix = min(max(net.prefix, 0), 32)
            if prefix == 0 { return true }
            let mask: UInt32 = prefix == 32 ? UInt32.max : ~UInt32((1 << (32 - prefix)) - 1)
            if (ipv4 & mask) == (net.address & mask) {
                return true
            }
        }
        return false
    }

    public static func parseIPv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt32(part), octet <= 255 else { return nil }
            value = (value << 8) | octet
        }
        return value
    }

    public static func parseIPv4Network(_ cidr: String) -> (UInt32, Int)? {
        let trimmed = cidr.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        guard let addr = parseIPv4(pieces[0]) else { return nil }
        if pieces.count == 1 {
            return (addr, 32)
        }
        guard let prefix = Int(pieces[1]), prefix >= 0, prefix <= 32 else { return nil }
        return (addr, prefix)
    }
}

/// Loads DIRECT destination patterns from a local Shadowrocket install (best-effort).
public enum ShadowrocketConfigReader {
    /// Scan the current user's Shadowrocket container for DIRECT rule-sets (e.g. 哔哩哔哩).
    public static func loadDirectIndex(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> DirectDestinationIndex {
        let fm = FileManager.default
        let container = homeDirectory
            .appendingPathComponent("Library/Containers/com.liguangming.Shadowrocket/Data", isDirectory: true)
        let tmp = container.appendingPathComponent("tmp", isDirectory: true)
        let caches = container
            .appendingPathComponent("Library/Caches", isDirectory: true)

        let confURL = newestConf(in: tmp, fm: fm)
        var directGroups = Set<String>()
        var ruleSetURLByGroup: [String: String] = [:]

        if let confURL,
           let text = try? String(contentsOf: confURL, encoding: .utf8) {
            parseConf(
                text,
                directGroups: &directGroups,
                ruleSetURLByGroup: &ruleSetURLByGroup
            )
        }

        // Always try to pick up cached lists named BiliBili when the group is DIRECT.
        var domains = Set<String>()
        var suffixes: [String] = []
        var networks: [IPv4Network] = []
        var labels: [String] = []

        let cacheFiles = (try? fm.contentsOfDirectory(
            at: caches,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for group in directGroups where group != "inline" {
            if !labels.contains(group) { labels.append(group) }
        }

        for file in cacheFiles where file.lastPathComponent.hasPrefix("rule-set-") {
            guard let body = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let name = ruleSetDisplayName(from: body)
            guard shouldLoad(ruleSetName: name, directGroups: directGroups, ruleSetURLByGroup: ruleSetURLByGroup) else {
                continue
            }
            if !name.isEmpty, !labels.contains(name) {
                labels.append(name)
            }
            merge(ruleList: body, domains: &domains, suffixes: &suffixes, networks: &networks)
        }

        return DirectDestinationIndex(
            domains: domains,
            domainSuffixes: suffixes.sorted(),
            ipv4Networks: networks,
            policyLabels: labels
        )
    }

    private static func newestConf(in tmp: URL, fm: FileManager) -> URL? {
        guard let files = try? fm.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let candidates = files.filter { url in
            let name = url.lastPathComponent
            return name == "lazy_group.conf" || name.hasPrefix("lazy_group.conf.bak")
        }
        return candidates.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    private static func parseConf(
        _ text: String,
        directGroups: inout Set<String>,
        ruleSetURLByGroup: inout [String: String]
    ) {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.uppercased().hasPrefix("RULE-SET,") {
                let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 3 else { continue }
                let url = parts[1]
                let group = parts[2]
                ruleSetURLByGroup[group] = url
                continue
            }

            // 哔哩哔哩 = select,DIRECT,PROXY,...,policy-select-name=DIRECT
            guard let eq = line.firstIndex(of: "=") else { continue }
            let group = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let rhs = String(line[line.index(after: eq)...])
            let lower = rhs.lowercased()
            if lower.contains("policy-select-name=direct")
                || lower.hasPrefix("select,direct,")
                || lower == "direct" {
                directGroups.insert(group)
            }

            // Inline DOMAIN-SUFFIX,example.com,DIRECT
            let upper = line.uppercased()
            if upper.hasPrefix("DOMAIN-SUFFIX,") || upper.hasPrefix("DOMAIN,") || upper.hasPrefix("IP-CIDR,") {
                let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 3 else { continue }
                let policy = parts[2].split(separator: ",").first.map(String.init) ?? parts[2]
                if policy.uppercased() == "DIRECT" {
                    directGroups.insert("inline")
                }
            }
        }
    }

    private static func ruleSetDisplayName(from body: String) -> String {
        for raw in body.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.uppercased().hasPrefix("# NAME:") {
                return line.dropFirst(7).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private static func shouldLoad(
        ruleSetName name: String,
        directGroups: Set<String>,
        ruleSetURLByGroup: [String: String]
    ) -> Bool {
        guard !name.isEmpty else { return false }
        if directGroups.contains(name) { return true }
        // Chinese policy group “哔哩哔哩” ↔ cached list NAME: BiliBili
        for group in directGroups {
            if group.contains("哔哩"), name.localizedCaseInsensitiveContains("bili") {
                return true
            }
            if group.localizedCaseInsensitiveCompare(name) == .orderedSame {
                return true
            }
            if let url = ruleSetURLByGroup[group],
               url.localizedCaseInsensitiveContains(name) {
                return true
            }
        }
        return false
    }

    private static func merge(
        ruleList body: String,
        domains: inout Set<String>,
        suffixes: inout [String],
        networks: inout [IPv4Network]
    ) {
        for raw in body.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }
            let kind = parts[0].uppercased()
            let value = parts[1].lowercased()
            switch kind {
            case "DOMAIN":
                domains.insert(value)
            case "DOMAIN-SUFFIX":
                if !suffixes.contains(value) { suffixes.append(value) }
            case "IP-CIDR", "IP-CIDR6":
                if kind == "IP-CIDR", let net = DirectDestinationIndex.parseIPv4Network(value) {
                    networks.append(IPv4Network(address: net.0, prefix: net.1))
                }
            default:
                continue
            }
        }
    }
}

/// Loads DIRECT destination patterns from Clash / Clash Verge / mihomo YAML (best-effort).
public enum ClashConfigReader {
    /// Scan common Clash-family config directories for `...,DIRECT` rules.
    public static func loadDirectIndex(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> DirectDestinationIndex {
        let fm = FileManager.default
        var merged = DirectDestinationIndex.empty
        for root in candidateRoots(homeDirectory: homeDirectory) {
            guard fm.fileExists(atPath: root.path) else { continue }
            let files = yamlFiles(under: root, fm: fm)
            for file in files.prefix(24) {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                merged = merged.merging(parseYAML(text, label: file.deletingPathExtension().lastPathComponent))
            }
        }
        return merged
    }

    /// Parse Clash-like YAML text for DIRECT rules (no full YAML engine).
    public static func parseYAML(_ text: String, label: String = "clash") -> DirectDestinationIndex {
        var domains = Set<String>()
        var suffixes: [String] = []
        var networks: [IPv4Network] = []
        var sawDirect = false

        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("-") {
                line = line.dropFirst().trimmingCharacters(in: .whitespaces)
            }
            // DOMAIN-SUFFIX,example.com,DIRECT  /  DOMAIN,foo.com,DIRECT  /  IP-CIDR,1.2.3.0/24,DIRECT
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { continue }
            let policy = parts[parts.count - 1].uppercased()
            guard policy == "DIRECT" else { continue }
            sawDirect = true
            let kind = parts[0].uppercased()
            let value = parts[1].lowercased()
            switch kind {
            case "DOMAIN":
                domains.insert(value)
            case "DOMAIN-SUFFIX", "DOMAIN-KEYWORD":
                if kind == "DOMAIN-SUFFIX", !suffixes.contains(value) {
                    suffixes.append(value)
                } else if kind == "DOMAIN-KEYWORD" {
                    // Keyword is weaker; treat as suffix-like only when it looks like a domain.
                    if value.contains("."), !suffixes.contains(value) {
                        suffixes.append(value)
                    }
                }
            case "IP-CIDR", "IP-CIDR6":
                if kind == "IP-CIDR", let net = DirectDestinationIndex.parseIPv4Network(value) {
                    networks.append(IPv4Network(address: net.0, prefix: net.1))
                }
            default:
                continue
            }
        }

        guard sawDirect || !domains.isEmpty || !suffixes.isEmpty || !networks.isEmpty else {
            return .empty
        }
        return DirectDestinationIndex(
            domains: domains,
            domainSuffixes: suffixes.sorted(),
            ipv4Networks: networks,
            policyLabels: sawDirect ? [label] : []
        )
    }

    private static func candidateRoots(homeDirectory: URL) -> [URL] {
        let appSupport = homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        return [
            appSupport.appendingPathComponent("io.github.clash-verge-rev.clash-verge-rev", isDirectory: true),
            appSupport.appendingPathComponent("clash-verge", isDirectory: true),
            appSupport.appendingPathComponent("Clash for Windows", isDirectory: true),
            homeDirectory.appendingPathComponent(".config/clash-verge", isDirectory: true),
            homeDirectory.appendingPathComponent(".config/clash", isDirectory: true),
            homeDirectory.appendingPathComponent(".config/mihomo", isDirectory: true),
            homeDirectory.appendingPathComponent(".config/clash.meta", isDirectory: true)
        ]
    }

    private static func yamlFiles(under root: URL, fm: FileManager) -> [URL] {
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            let ext = url.pathExtension.lowercased()
            guard ext == "yaml" || ext == "yml" || name == "config.yaml" || name == "config.yml" else {
                continue
            }
            // Skip huge provider dumps when possible by name.
            if name.contains("provider") || name.contains("geosite") || name.contains("geoip") {
                continue
            }
            files.append(url)
            if files.count >= 40 { break }
        }
        return files
    }
}

/// Aggregates DIRECT indexes from known local proxy clients (Shadowrocket, Clash, …).
public enum LocalProxyConfigReader {
    /// Set `EYESONYOU_SKIP_PROXY_CONFIG_SCAN=1` to skip reads that macOS gates behind
    /// a consent prompt.
    ///
    /// These configs live in other apps' containers, which is TCC-protected. In a
    /// headless or automated run nobody can answer the prompt, so the read blocks
    /// forever; opting out keeps such runs deterministic.
    public static let skipEnvironmentKey = "EYESONYOU_SKIP_PROXY_CONFIG_SCAN"

    public static var isDisabledByEnvironment: Bool {
        let value = ProcessInfo.processInfo.environment[skipEnvironmentKey]?.lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    public static func loadDirectIndex(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> DirectDestinationIndex {
        if isDisabledByEnvironment { return .empty }
        return ShadowrocketConfigReader.loadDirectIndex(homeDirectory: homeDirectory)
            .merging(ClashConfigReader.loadDirectIndex(homeDirectory: homeDirectory))
    }

    /// Load with a deadline, returning `nil` when it did not finish in time.
    ///
    /// A pending TCC prompt makes `open()` block indefinitely, so the caller needs a
    /// way to give up. The worker thread is left to finish on its own — one parked
    /// thread is acceptable; a permanently stalled sampler is not.
    public static func loadDirectIndex(
        timeout: TimeInterval,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> DirectDestinationIndex? {
        if isDisabledByEnvironment { return .empty }

        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        DispatchQueue.global(qos: .utility).async {
            let index = loadDirectIndex(homeDirectory: homeDirectory)
            box.store(index)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: DirectDestinationIndex?

        func store(_ index: DirectDestinationIndex) {
            lock.lock()
            stored = index
            lock.unlock()
        }

        var value: DirectDestinationIndex? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
