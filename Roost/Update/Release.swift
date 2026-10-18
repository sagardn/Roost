import Foundation

/// One published release, as GitHub describes it.
///
/// Only the fields an updater needs are decoded. GitHub's release payload is
/// large and changes shape over time; asking for four keys and ignoring the
/// rest means a new field upstream cannot break an update.
struct Release: Equatable {
    let version: Version
    let tag: String
    let notes: String
    /// The disk image to install.
    let downloadURL: URL
    /// `<asset>.sha256`, when the release publishes one. Roost's own workflow
    /// always does; the type stays honest about it being optional so a release
    /// made by hand is not undownloadable.
    let checksumURL: URL?

    /// What the release feed looks like on the wire.
    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    enum DecodeError: LocalizedError, Equatable {
        case unreadableTag(String)
        case noAsset(named: String)
        case draft

        var errorDescription: String? {
            switch self {
            case .unreadableTag(let tag):
                return "The latest release is tagged \"\(tag)\", which is not a version number."
            case .noAsset(let name):
                return "The latest release has no \(name) to download."
            case .draft:
                return "The latest release is a draft."
            }
        }
    }

    /// Reads a GitHub `releases/latest` payload.
    ///
    /// Fails loudly rather than returning "nothing to do". A feed that cannot
    /// be read is a problem to show the user, not a reason to tell them they
    /// are up to date -- which is what the old string comparison did with an
    /// unparseable tag.
    static func decode(_ data: Data, assetNamed assetName: String) throws -> Release {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        if payload.draft == true { throw DecodeError.draft }

        guard let version = Version(payload.tag_name) else {
            throw DecodeError.unreadableTag(payload.tag_name)
        }
        guard let asset = payload.assets.first(where: { $0.name == assetName }) else {
            throw DecodeError.noAsset(named: assetName)
        }
        let checksum = payload.assets.first { $0.name == assetName + ".sha256" }

        return Release(version: version,
                       tag: payload.tag_name,
                       notes: payload.body ?? "",
                       downloadURL: asset.browser_download_url,
                       checksumURL: checksum?.browser_download_url)
    }
}
