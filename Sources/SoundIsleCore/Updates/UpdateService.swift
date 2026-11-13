import Foundation

/// What a check came back with. `failed` means every source was unreachable
/// or unreadable — it is not "no update", which matters because the settings
/// row says different things for the two.
public enum UpdateCheck: Equatable {
    case update(UpdateRelease)
    case upToDate
    case failed
}

/// Asks each source in turn for the latest release. The site's own JSON comes
/// first because Cloudflare is reachable in places GitHub is not; the GitHub
/// API is the fallback, so a stale site mirror never hides a release.
public struct UpdateService {
    public enum Source: Equatable {
        /// The site's `latest.json` (see `UpdateReleaseDecoder`).
        case manifest(URL)
        /// `https://api.github.com/repos/<owner>/<repo>/releases/latest`.
        case github(URL)
    }

    public static let manifestURL = URL(string: "https://y8gao.pages.dev/downloads/latest.json")!
    public static let githubURL = URL(string: "https://api.github.com/repos/y8gao/soundisle/releases/latest")!

    public static let defaultSources: [Source] = [
        .manifest(manifestURL),
        .github(githubURL)
    ]

    private let sources: [Source]
    private let session: URLSession
    private let current: AppVersion

    public init(
        current: AppVersion,
        sources: [Source] = UpdateService.defaultSources,
        session: URLSession = .shared
    ) {
        self.current = current
        self.sources = sources
        self.session = session
    }

    public func check() async -> UpdateCheck {
        for source in sources {
            guard let release = await fetch(source) else { continue }
            // The first source that answers decides: a higher version from a
            // slower source would only make the answer depend on timing.
            return release.version > current ? .update(release) : .upToDate
        }
        return .failed
    }

    private func fetch(_ source: Source) async -> UpdateRelease? {
        let url: URL
        switch source {
        case .manifest(let value), .github(let value):
            url = value
        }
        guard url.scheme?.lowercased() == "https" else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("SoundIsle/\(current.raw)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return UpdateReleaseDecoder.decode(data)
        } catch {
            return nil
        }
    }
}
