import Foundation

/// One downloadable file of a release. `sha256` is what the updater verifies
/// before it touches the installed app, so a source that cannot provide one
/// (the GitHub API carries no checksums) can still be used to *announce* a
/// version but never to install it silently.
public struct UpdateAsset: Equatable {
    public let url: URL
    public let sha256: String?
    public let size: Int?

    public init(url: URL, sha256: String? = nil, size: Int? = nil) {
        self.url = url
        self.sha256 = sha256
        self.size = size
    }
}

public struct UpdateRelease: Equatable {
    public let version: AppVersion
    public let pageURL: URL?
    public let notes: String?
    public let zip: UpdateAsset?
    public let dmg: UpdateAsset?

    public init(
        version: AppVersion,
        pageURL: URL? = nil,
        notes: String? = nil,
        zip: UpdateAsset? = nil,
        dmg: UpdateAsset? = nil
    ) {
        self.version = version
        self.pageURL = pageURL
        self.notes = notes
        self.zip = zip
        self.dmg = dmg
    }

    /// The release can be installed in place only when there is something to
    /// unpack and a checksum to prove it arrived intact.
    public var installable: UpdateAsset? {
        guard let zip, zip.sha256?.isEmpty == false else { return nil }
        return zip
    }
}

/// Reads either shape of release payload: the site's own `latest.json`, or
/// GitHub's `/releases/latest`. Both are JSON objects whose fields are read
/// defensively — a field that moved must not take the whole check down.
public enum UpdateReleaseDecoder {
    public static func decode(_ data: Data) -> UpdateRelease? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return nil }
        return release(from: root)
    }

    private static func release(from root: [String: Any]) -> UpdateRelease? {
        let versionText = (root["version"] as? String)
            ?? (root["tag_name"] as? String)
            ?? (root["name"] as? String)
        guard let versionText, let version = AppVersion(versionText) else { return nil }

        let notes = (root["notes"] as? String) ?? (root["body"] as? String)
        let page = url(root["page"] as? String) ?? url(root["html_url"] as? String)

        // The site names its assets; GitHub hands back a list.
        if let assets = root["assets"] as? [[String: Any]] {
            return UpdateRelease(
                version: version,
                pageURL: page,
                notes: notes,
                zip: named(assets, suffix: ".zip"),
                dmg: named(assets, suffix: ".dmg")
            )
        }

        return UpdateRelease(
            version: version,
            pageURL: page,
            notes: notes,
            zip: asset(root["zip"] as? [String: Any]),
            dmg: asset(root["dmg"] as? [String: Any])
        )
    }

    private static func asset(_ object: [String: Any]?) -> UpdateAsset? {
        guard let object,
              let url = url(object["url"] as? String) ?? url(object["browser_download_url"] as? String)
        else { return nil }
        let digest = (object["sha256"] as? String)?.lowercased()
        return UpdateAsset(url: url, sha256: digest, size: object["size"] as? Int)
    }

    private static func named(_ assets: [[String: Any]], suffix: String) -> UpdateAsset? {
        guard let match = assets.first(where: {
            ($0["name"] as? String)?.lowercased().hasSuffix(suffix) == true
        }) else { return nil }
        return asset(match)
    }

    private static func url(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), url.scheme != nil else { return nil }
        return url
    }
}
