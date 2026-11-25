import Foundation

enum UpdateCheckResult {
    case upToDate(current: String)
    case updateAvailable(current: String, latest: String,
                         releaseURL: URL, downloadURL: URL?)
    case error(String)
}

enum UpdateChecker {
    private static let releasesAPIURL =
        URL(string: "https://api.github.com/repos/P-DoxQuad/push-to-dictate/releases/latest")!
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

        var request = URLRequest(url: releasesAPIURL)
        request.timeoutInterval = requestTimeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            let result = parseResponse(current: current,
                                       data: data,
                                       response: response,
                                       error: error)
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
    }

    private static func parseResponse(current: String,
                                      data: Data?,
                                      response: URLResponse?,
                                      error: Error?) -> UpdateCheckResult {
        if let error = error {
            return .error("Couldn't reach GitHub: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            return .error("Couldn't reach GitHub.")
        }
        guard http.statusCode == 200 else {
            return .error("GitHub returned status \(http.statusCode).")
        }
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = json as? [String: Any] else {
            return .error("Could not parse release metadata.")
        }
        guard let tag = dict["tag_name"] as? String,
              let htmlURLString = dict["html_url"] as? String,
              let htmlURL = URL(string: htmlURLString) else {
            return .error("Release metadata missing tag or URL.")
        }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let downloadURL = pickFullAssetURL(from: dict["assets"])

        switch compareVersions(latest, current) {
        case .orderedDescending:
            return .updateAvailable(current: current, latest: latest,
                                    releaseURL: htmlURL, downloadURL: downloadURL)
        case .orderedSame, .orderedAscending:
            return .upToDate(current: current)
        }
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
