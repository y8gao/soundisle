import Foundation

public struct LibraryIndex: Codable {
    public var tracks: [Track]
    public var folders: [URL]

    public init(tracks: [Track] = [], folders: [URL] = []) {
        self.tracks = tracks
        self.folders = folders
    }
}
