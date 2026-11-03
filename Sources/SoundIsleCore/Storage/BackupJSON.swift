import Foundation

/// Small JSON file helper for the undo stores: atomic replacement, a `.bak`
/// copy of the last decodable version, and a load result that tells the caller
/// whether it recovered from that backup or found corrupt data.
enum BackupJSON {
    enum Source: Equatable {
        case primary
        case backup
        /// A file existed but neither it nor its `.bak` could be decoded.
        case corrupt
        /// Nothing was written yet, which is not a failure.
        case missing
    }

    struct Loaded<Value> {
        var value: Value?
        var source: Source
    }

    static func load<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        manager: FileManager = .default
    ) -> Loaded<T> {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: url),
           let value = try? decoder.decode(T.self, from: data) {
            return Loaded(value: value, source: .primary)
        }
        let backup = url.appendingPathExtension("bak")
        if let data = try? Data(contentsOf: backup),
           let value = try? decoder.decode(T.self, from: data) {
            return Loaded(value: value, source: .backup)
        }
        let anyFileExists = manager.fileExists(atPath: url.path)
            || manager.fileExists(atPath: backup.path)
        return Loaded(value: nil, source: anyFileExists ? .corrupt : .missing)
    }

    /// Writes atomically and rotates the previous decodable version into
    /// `.bak`. A corrupt current file must never overwrite the last good copy.
    static func save<T: Codable>(
        _ value: T,
        to url: URL,
        manager: FileManager = .default
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let current = try? Data(contentsOf: url),
           (try? JSONDecoder().decode(T.self, from: current)) != nil {
            let backup = url.appendingPathExtension("bak")
            try? manager.removeItem(at: backup)
            try manager.copyItem(at: url, to: backup)
        }
        try data.write(to: url, options: .atomic)
    }

    /// Removes both the current file and its backup, so clearing a history
    /// cannot resurrect entries from `.bak` on the next launch.
    static func remove(from url: URL, manager: FileManager = .default) throws {
        for candidate in [url, url.appendingPathExtension("bak")]
        where manager.fileExists(atPath: candidate.path) {
            try manager.removeItem(at: candidate)
        }
    }
}
