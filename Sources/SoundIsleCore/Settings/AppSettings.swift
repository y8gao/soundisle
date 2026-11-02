import Foundation

public struct AppSettings: Codable, Equatable {
    public var themePreset: String = "deepBlue"
    public var themeMode: String = "system"
    public var customAccentHex: String?
    public var lyricsOpacity: Double = 0.26
    public var lyricsOutline: Bool = false
    public var lyricsLineMode: String = "two"
    public var lyricsLocked: Bool = false
    public var rowStyle: String = "index"
    public var showMainSpectrum: Bool = false
    public var hideFromScreenCapture: Bool = true
    public var keepRunningOnClose: Bool = true
    public var miniAlwaysOnTop: Bool = true
    public var onlineLyricsEnabled: Bool = true
    public var playbackMode: String = "sequential"
    public var lastQueue: [UUID] = []
    public var lastTrackID: UUID?
    public var lastPosition: TimeInterval = 0
    public var ffmpegPath: String?

    public init() {}

    /// Missing keys fall back to the default so a settings file written by an
    /// older version never resets every preference at once.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        themePreset = try container.decodeIfPresent(String.self, forKey: .themePreset) ?? "deepBlue"
        themeMode = try container.decodeIfPresent(String.self, forKey: .themeMode) ?? "system"
        customAccentHex = try container.decodeIfPresent(String.self, forKey: .customAccentHex)
        lyricsOpacity = try container.decodeIfPresent(Double.self, forKey: .lyricsOpacity) ?? 0.26
        lyricsOutline = try container.decodeIfPresent(Bool.self, forKey: .lyricsOutline) ?? false
        lyricsLineMode = try container.decodeIfPresent(String.self, forKey: .lyricsLineMode) ?? "two"
        lyricsLocked = try container.decodeIfPresent(Bool.self, forKey: .lyricsLocked) ?? false
        rowStyle = try container.decodeIfPresent(String.self, forKey: .rowStyle) ?? "index"
        showMainSpectrum = try container.decodeIfPresent(Bool.self, forKey: .showMainSpectrum) ?? false
        hideFromScreenCapture = try container.decodeIfPresent(Bool.self, forKey: .hideFromScreenCapture) ?? true
        keepRunningOnClose = try container.decodeIfPresent(Bool.self, forKey: .keepRunningOnClose) ?? true
        miniAlwaysOnTop = try container.decodeIfPresent(Bool.self, forKey: .miniAlwaysOnTop) ?? true
        onlineLyricsEnabled = try container.decodeIfPresent(Bool.self, forKey: .onlineLyricsEnabled) ?? true
        playbackMode = try container.decodeIfPresent(String.self, forKey: .playbackMode) ?? "sequential"
        lastQueue = try container.decodeIfPresent([UUID].self, forKey: .lastQueue) ?? []
        lastTrackID = try container.decodeIfPresent(UUID.self, forKey: .lastTrackID)
        lastPosition = try container.decodeIfPresent(TimeInterval.self, forKey: .lastPosition) ?? 0
        ffmpegPath = try container.decodeIfPresent(String.self, forKey: .ffmpegPath)
    }
}
