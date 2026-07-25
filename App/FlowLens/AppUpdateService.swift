import Foundation
import AppKit

/// Checks GitHub Releases for a newer EyesOnYou build and optionally downloads the asset.
enum AppUpdateService {
    static let githubOwner = "Johnnydaszhu"
    static let githubRepo = "FlowLens"

    static var releasesAPIURL: URL {
        if let url = URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/latest") {
            return url
        }
        return URL(fileURLWithPath: "/")
    }

    static var releasesPageURL: URL {
        if let url = URL(string: "https://github.com/\(githubOwner)/\(githubRepo)/releases/latest") {
            return url
        }
        return URL(fileURLWithPath: "/")
    }

    struct ReleaseInfo: Equatable {
        let tagName: String
        let version: String
        let htmlURL: URL
        let assetURL: URL?
        let assetName: String?
        let publishedAt: String?
    }

    enum CheckError: LocalizedError, Equatable {
        case badResponse
        case decodeFailed
        case noRelease
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .badResponse: return "Bad GitHub response"
            case .decodeFailed: return "Could not parse release JSON"
            case .noRelease: return "No GitHub release published yet"
            case .invalidURL: return "Invalid download URL"
            }
        }
    }

    static func currentAppVersion() -> String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmed = short?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "0.1.0" : trimmed
    }

    static func normalizedVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("v") {
            s = String(s.dropFirst())
        }
        if let dash = s.firstIndex(of: "-") {
            s = String(s[..<dash])
        }
        if let plus = s.firstIndex(of: "+") {
            s = String(s[..<plus])
        }
        return s
    }

    /// true when `remote` is strictly newer than `local`.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = normalizedVersion(remote)
            .split(separator: ".")
            .map { Int($0) ?? 0 }
        let l = normalizedVersion(local)
            .split(separator: ".")
            .map { Int($0) ?? 0 }
        let n = max(r.count, l.count)
        for i in 0..<n {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    /// Fetch latest GitHub release. Completion always on main queue.
    static func fetchLatestRelease(completion: @escaping (Result<ReleaseInfo, Error>) -> Void) {
        let api = releasesAPIURL
        guard api.scheme == "https" else {
            DispatchQueue.main.async { completion(.failure(CheckError.invalidURL)) }
            return
        }

        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("EyesOnYou-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            let finish: (Result<ReleaseInfo, Error>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }
            if let error {
                finish(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                finish(.failure(CheckError.badResponse))
                return
            }
            if http.statusCode == 404 {
                finish(.failure(CheckError.noRelease))
                return
            }
            guard (200...299).contains(http.statusCode), let data else {
                finish(.failure(CheckError.badResponse))
                return
            }
            do {
                let info = try decodeRelease(data)
                finish(.success(info))
            } catch {
                finish(.failure(error))
            }
        }
        task.resume()
    }

    private static func decodeRelease(_ data: Data) throws -> ReleaseInfo {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CheckError.decodeFailed
        }
        let tag = (json["tag_name"] as? String) ?? ""
        guard !tag.isEmpty else { throw CheckError.decodeFailed }
        let html = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPageURL
        let published = json["published_at"] as? String

        var assetURL: URL?
        var assetName: String?
        if let assets = json["assets"] as? [[String: Any]] {
            let preferred = preferredAsset(from: assets)
            if let name = preferred?["name"] as? String,
               let urlString = preferred?["browser_download_url"] as? String,
               let url = URL(string: urlString) {
                assetName = name
                assetURL = url
            }
        }

        return ReleaseInfo(
            tagName: tag,
            version: normalizedVersion(tag),
            htmlURL: html,
            assetURL: assetURL,
            assetName: assetName,
            publishedAt: published
        )
    }

    private static func preferredAsset(from assets: [[String: Any]]) -> [String: Any]? {
        let exts = ["dmg", "pkg", "zip"]
        for ext in exts {
            if let hit = assets.first(where: {
                (($0["name"] as? String) ?? "").lowercased().hasSuffix(".\(ext)")
            }) {
                return hit
            }
        }
        return assets.first
    }

    /// Download asset to ~/Downloads. Completion on main.
    static func downloadAsset(
        from url: URL,
        suggestedName: String?,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let name = suggestedName ?? url.lastPathComponent
        let dest = downloads.appendingPathComponent(name)

        let task = URLSession.shared.downloadTask(with: url) { tempURL, _, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let tempURL else {
                DispatchQueue.main.async { completion(.failure(CheckError.badResponse)) }
                return
            }
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tempURL, to: dest)
                DispatchQueue.main.async { completion(.success(dest)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
        task.resume()
    }

    static func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
