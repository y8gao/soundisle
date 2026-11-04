import Foundation

public struct AppSettings: Codable, Equatable {
    public var themePreset: String = "celadon"
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
    /// Custom lyrics provider endpoint; `nil` uses LRCLIB's default.
    public var lyricsEndpoint: String?
    public var playbackMode: String = "repeatAll"
    public var lastQueue: [UUID] = []
    public var lastTrackID: UUID?
    public var lastPosition: TimeInterval = 0
    public var ffmpegPath: String?
    /// UI language: "system", "zh" or "en". Applied at launch through
    /// `AppleLanguages`; changing it needs a restart.
    public var appLanguage: String = "system"

    public init() {}

    /// Missing keys fall back to the default so a settings file written by an
    /// older version never resets every preference at once.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        themePreset = try container.decodeIfPresent(String.self, forKey: .themePreset) ?? "celadon"
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
        lyricsEndpoint = try container.decodeIfPresent(String.self, forKey: .lyricsEndpoint)
        // Sequential playback was removed from the UI; a settings file written
        // by an older version migrates to repeat-all on load.
        let storedMode = try container.decodeIfPresent(String.self, forKey: .playbackMode) ?? "repeatAll"
        playbackMode = storedMode == "sequential" ? "repeatAll" : storedMode
        lastQueue = try container.decodeIfPresent([UUID].self, forKey: .lastQueue) ?? []
        lastTrackID = try container.decodeIfPresent(UUID.self, forKey: .lastTrackID)
        lastPosition = try container.decodeIfPresent(TimeInterval.self, forKey: .lastPosition) ?? 0
        ffmpegPath = try container.decodeIfPresent(String.self, forKey: .ffmpegPath)
        appLanguage = try container.decodeIfPresent(String.self, forKey: .appLanguage) ?? "system"
    }
}
