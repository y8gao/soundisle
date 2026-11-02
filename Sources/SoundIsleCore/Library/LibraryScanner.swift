import Foundation

public struct ScanResult {
    public var tracks: [Track]
    public var unreadable: [URL]

    public init(tracks: [Track] = [], unreadable: [URL] = []) {
        self.tracks = tracks
        self.unreadable = unreadable
    }
}

public enum LibraryScanner {
    public static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "m4r", "aac", "wav", "aiff", "aif", "flac", "alac", "mp4",
        "ape", "wma", "ogg", "oga", "opus", "wv", "tta", "dsf", "dff",
    ]

    /// Formats AVFoundation can read directly. Derived by subtraction so it can
    /// never list an extension outside `supportedExtensions`.
    private static let nonNativeExtensions: Set<String> = [
        "ape", "wma", "ogg", "oga", "opus", "wv", "tta", "dsf", "dff",
    ]

    private static let nativeExtensions: Set<String> =
        supportedExtensions.subtracting(nonNativeExtensions)

    public static func scan(
        folders: [URL],
        reader: MetadataReading = AVFoundationMetadataReader()
    ) async -> ScanResult {
        let urls = collectFiles(in: folders).sorted { $0.path < $1.path }

        var byIndex: [Int: AudioMetadata] = [:]
        await withTaskGroup(of: (Int, AudioMetadata?).self) { group in
            for (index, url) in urls.enumerated()
            where nativeExtensions.contains(url.pathExtension.lowercased()) {
                group.addTask {
                    (index, await reader.read(url: url))
                }
            }
            for await (index, metadata) in group {
                if let metadata { byIndex[index] = metadata }
            }
        }

        var tracks: [Track] = []
        var unreadable: [URL] = []
        for (index, url) in urls.enumerated() {
            if nativeExtensions.contains(url.pathExtension.lowercased()) {
                if let metadata = byIndex[index] {
                    tracks.append(TrackFactory.make(url: url, metadata: metadata))
                } else {
                    unreadable.append(url)
                }
            } else {
                tracks.append(TrackFactory.make(url: url, metadata: nil))
            }
        }
        return ScanResult(tracks: tracks, unreadable: unreadable)
    }

    private static func collectFiles(in folders: [URL]) -> [URL] {
        let manager = FileManager.default
        var urls: [URL] = []
        var seen = Set<URL>()
        for folder in folders {
            guard let enumerator = manager.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
                if let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                   values.isRegularFile == false {
                    continue
                }
                let standardized = url.standardizedFileURL
                guard seen.insert(standardized).inserted else { continue }
                urls.append(standardized)
            }
        }
        return urls
    }
}
