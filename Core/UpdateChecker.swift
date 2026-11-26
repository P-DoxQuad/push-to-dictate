import Foundation

enum UpdateCheckResult {
    case upToDate(current: String)
    case updateAvailable(current: String, latest: String,
                         releaseURL: URL, downloadURL: URL?)
    case error(String)
}

struct ReleaseInfo {
    let version: String
    let publishedDate: Date?
    let releaseURL: URL
    let downloadURL: URL?
}

enum UpdateChecker {
    private static let allReleasesAPIURL =
        URL(string: "https://api.github.com/repos/P-DoxQuad/push-to-dictate/releases")!
    private static let releasesPageURL =
        URL(string: "https://github.com/P-DoxQuad/push-to-dictate/releases")!

    private static let requestTimeout: TimeInterval = 10

    // TEMPORARY: when true, checkForUpdates bypasses the network and returns a
    // synthetic updateAvailable result so the UI flow can be exercised without
    // a real newer release on GitHub. Remove before shipping.
    static let simulateUpdateAvailable = false
    static let simulatedLatestVersion = "2026.99.0"

    static var installedVersion: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    static func checkForUpdates(completion: @escaping (UpdateCheckResult) -> Void) {
        let current = installedVersion

        if simulateUpdateAvailable {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                completion(.updateAvailable(current: current,
                                            latest: simulatedLatestVersion,
                                            releaseURL: releasesPageURL,
                                            downloadURL: nil))
            }
            return
        }

        // Use the full /releases endpoint (not /releases/latest) so model-
        // asset releases and other non-app releases can be filtered out
        // client-side via the CalVer tag check in fetchAllReleases. The
        // first element of the filtered list is the latest app release.
        fetchAllReleases { releases, errorMessage in
            if let msg = errorMessage {
                completion(.error(msg))
                return
            }
            guard let latest = releases?.first else {
                completion(.upToDate(current: current))
                return
            }
            switch compareVersions(latest.version, current) {
            case .orderedDescending:
                completion(.updateAvailable(
                    current: current,
                    latest: latest.version,
                    releaseURL: latest.releaseURL,
                    downloadURL: latest.downloadURL))
            case .orderedSame, .orderedAscending:
                completion(.upToDate(current: current))
            }
        }
    }

    // Fetches every release from the GitHub API (not just the latest).
    // Returns the list on success; a non-nil error message on failure.
    // Called by the Updates tab's Fetch button. Results are not cached;
    // the caller controls fetch frequency.
    static func fetchAllReleases(
        completion: @escaping ([ReleaseInfo]?, String?) -> Void) {
        var request = URLRequest(url: allReleasesAPIURL)
        request.timeoutInterval = requestTimeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            let result = parseAllReleases(data: data, response: response, error: error)
            DispatchQueue.main.async { completion(result.releases, result.error) }
        }
        task.resume()
    }

    private static func parseAllReleases(data: Data?,
                                          response: URLResponse?,
                                          error: Error?)
        -> (releases: [ReleaseInfo]?, error: String?) {
        if let error = error {
            return (nil, "Couldn't reach GitHub: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            return (nil, "Couldn't reach GitHub.")
        }
        guard http.statusCode == 200 else {
            return (nil, "GitHub returned status \(http.statusCode).")
        }
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let array = json as? [[String: Any]] else {
            return (nil, "Could not parse releases list.")
        }
        // GitHub emits ISO 8601 timestamps like "2026-11-24T12:34:56Z".
        // ISO8601DateFormatter is 10.12+, so parse with DateFormatter
        // configured for the UTC form. `XXX` handles both "Z" and
        // "+00:00" style suffixes.
        let isoFmt = DateFormatter()
        isoFmt.locale = Locale(identifier: "en_US_POSIX")
        isoFmt.timeZone = TimeZone(identifier: "UTC")
        isoFmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        var out: [ReleaseInfo] = []
        for dict in array {
            guard let tag = dict["tag_name"] as? String,
                  let htmlURLString = dict["html_url"] as? String,
                  let htmlURL = URL(string: htmlURLString) else { continue }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            // Exclude non-app releases (e.g. model-asset distributions
            // published under the same repo). App releases are tagged as
            // CalVer YYYY.MM.PATCH or YYYY.MM.PATCH.N.
            if !isAppVersionTag(version) { continue }
            var pubDate: Date? = nil
            if let s = dict["published_at"] as? String {
                pubDate = isoFmt.date(from: s)
            }
            let dl = pickFullAssetURL(from: dict["assets"])
            out.append(ReleaseInfo(version: version,
                                   publishedDate: pubDate,
                                   releaseURL: htmlURL,
                                   downloadURL: dl))
        }
        return (out, nil)
    }

    // True when the stripped-tag text matches the app's CalVer pattern:
    // YYYY.MM.PATCH, optionally with a fourth .N for same-version respins.
    // Year is four digits, month is one or two, patch is one or more.
    private static func isAppVersionTag(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count == 3 || parts.count == 4 else { return false }
        func isPositiveInt(_ p: Substring, width: ClosedRange<Int>) -> Bool {
            guard width.contains(p.count) else { return false }
            return p.allSatisfy { $0 >= "0" && $0 <= "9" }
        }
        guard isPositiveInt(parts[0], width: 4...4) else { return false }
        guard isPositiveInt(parts[1], width: 1...2) else { return false }
        guard isPositiveInt(parts[2], width: 1...3) else { return false }
        if parts.count == 4 {
            guard isPositiveInt(parts[3], width: 1...3) else { return false }
        }
        return true
    }

    // Pick the single asset whose filename ends with "-Full.zip". Zero or
    // multiple matches return nil; caller falls back to Open Release Page.
    private static func pickFullAssetURL(from assets: Any?) -> URL? {
        guard let array = assets as? [[String: Any]] else { return nil }
        let matches = array.filter {
            if let name = $0["name"] as? String {
                return name.hasSuffix("-Full.zip")
            }
            return false
        }
        guard matches.count == 1 else { return nil }
        guard let urlString = matches[0]["browser_download_url"] as? String,
              let url = URL(string: urlString) else { return nil }
        return url
    }

    // Component-wise integer compare of dot-separated CalVer strings.
    // Missing components (e.g. "2026.11.0" vs "2026.11.0.1") pad with 0.
    // Each component is parsed as its leading run of digits, so suffixes like
    // "-Full" or "-rc1" on the final component are ignored instead of causing
    // an Int() parse failure that silently zeroes the component.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let aParts = a.split(separator: ".").map { leadingInt($0) }
        let bParts = b.split(separator: ".").map { leadingInt($0) }
        let count = max(aParts.count, bParts.count)
        for i in 0..<count {
            let ai = i < aParts.count ? aParts[i] : 0
            let bi = i < bParts.count ? bParts[i] : 0
            if ai > bi { return .orderedDescending }
            if ai < bi { return .orderedAscending }
        }
        return .orderedSame
    }

    private static func leadingInt<S: StringProtocol>(_ s: S) -> Int {
        let digits = s.prefix(while: { $0 >= "0" && $0 <= "9" })
        return Int(String(digits)) ?? 0
    }
}
