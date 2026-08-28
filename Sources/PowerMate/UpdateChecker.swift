import AppKit
import os.log

/// Asks GitHub for the newest release tag. This is the app's only network
/// code: a single anonymous HTTPS GET for public release metadata, carrying
/// no identifiers and no payload. Nothing about the user or the Mac is
/// sent, and nothing from the response is stored beyond the version and
/// release page URL held in memory.
final class UpdateChecker {
    struct Update {
        let version: String
        let pageURL: URL
    }

    /// The newest known release, when it is newer than the running app.
    private(set) var available: Update?
    /// Called on the main queue when a check finishes. nil means up to date.
    var onResult: ((Result<Update?, Error>) -> Void)?

    private static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/perimtr/powermate/releases/latest")!
    private let session: URLSession
    private var inFlight = false

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = ["Accept": "application/vnd.github+json"]
        session = URLSession(configuration: configuration)
    }

    /// The version to compare against; a debug default can stand in for the
    /// bundle version so the newer-available path is testable (see the
    /// verification recipes).
    var currentVersion: String {
        UserDefaults.standard.string(forKey: "debugUpdateCheckVersion")
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    }

    func check() {
        guard !inFlight else { return }
        inFlight = true
        session.dataTask(with: Self.latestReleaseURL) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.finish(data: data, response: response, error: error)
            }
        }.resume()
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private func finish(data: Data?, response: URLResponse?, error: Error?) {
        inFlight = false
        if let error {
            logger.info("update check failed: \(error.localizedDescription, privacy: .public)")
            onResult?(.failure(error))
            return
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let data,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              let page = URL(string: release.htmlURL)
        else {
            logger.info("update check failed: unexpected response")
            onResult?(.failure(URLError(.badServerResponse)))
            return
        }
        let latest = release.tagName.hasPrefix("v")
            ? String(release.tagName.dropFirst()) : release.tagName
        if Self.isVersion(latest, newerThan: currentVersion) {
            let update = Update(version: latest, pageURL: page)
            available = update
            logger.info("update available: \(latest, privacy: .public) (running \(self.currentVersion, privacy: .public))")
            onResult?(.success(update))
        } else {
            available = nil
            logger.info("update check: up to date (latest \(latest, privacy: .public), running \(self.currentVersion, privacy: .public))")
            onResult?(.success(nil))
        }
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
