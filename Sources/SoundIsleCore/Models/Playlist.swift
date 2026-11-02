import Foundation

public struct Playlist: Identifiable, Codable, Hashable {
    public var id: UUID
    public var name: String
    public var trackIDs: [UUID]

    public init(id: UUID = UUID(), name: String, trackIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
    }
}
