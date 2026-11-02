# 声屿（SoundIsle）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一款 macOS 12+ 原生本地音乐播放器「声屿」：本地库管理、低资源播放、桌面歌词、迷你模式、菜单栏、六套磨砂玻璃皮肤、标签编辑与乱码修复、按标签整理文件、系统不支持格式的后台转码。

**Architecture:** Swift Package 分为 `SoundIsleCore`（模型、扫描、播放、歌词、标签、整理、转码等可测试逻辑）与 `SoundIsle`（SwiftUI/AppKit 界面、窗口、菜单栏）。播放用 AVAudioEngine + AVAudioPlayerNode，FFT 由 Accelerate 驱动；TagLib 通过 C++ 桥接静态链接；不支持格式由本机 ffmpeg CLI 转成 ALAC 缓存。应用由脚本打包成 `.app`，不依赖 Xcode 工程文件。

**Tech Stack:** Swift 5.8.1 / SwiftUI + AppKit / AVFoundation / Accelerate / XCTest / TagLib 1.13.1（静态）/ ffmpeg CLI（外部依赖）/ SwiftPM。

**Spec:** `docs/superpowers/specs/2026-11-02-local-music-player-design.md`

## Global Constraints

- 最低 macOS 12.0；Xcode 14.3.1；Swift 5.8.1；最终产出 Intel + Apple Silicon 通用二进制。
- 应用显示名「声屿」，内部模块/目录 `SoundIsle`，Bundle ID `com.local.soundisle`。
- 界面文案全中文；代码标识符英文。
- 运行时第三方依赖只允许 TagLib（静态链接）与 ffmpeg CLI（仅转码时调用，不打包）。
- 不使用数据库；所有持久化是 JSON，原子写入并保留上一版 `.bak`。
- 网络只用于 LRCLIB 歌词查询；断网时播放、库管理、标签编辑必须完整可用。
- 数据目录 `~/Library/Application Support/SoundIsle/`。
- 播放空闲 CPU < 1%，播放时 < 3%，常驻内存 < 150MB。
- 不修改用户原始文件，除非用户显式执行标签写入或文件整理；两者都必须有撤销记录。
- 每个任务结束提交一次；提交信息用 `feat:` / `test:` / `chore:` 前缀。

## Review Focus

1. **文件名解析**：中文下载文件名有空格、连字符、多个点、前置曲目号（如 `强军战歌.Live.-阎维文.mp3`），解析错误会让整个库的歌名/歌手颠倒。—— Task 2 测试覆盖。
2. **索引损坏**：`library.json` 或播放列表文件损坏时不能静默丢失用户播放列表或撤销记录。—— Task 3 测试覆盖。
3. **锁定歌词无法退出**：锁定后鼠标穿透且置顶；菜单栏/主窗口解锁入口必须始终可达，不能把用户困住。—— Task 8 手工验收覆盖。
4. **编辑/整理导致文件损失**：标签写坏、整理覆盖同名文件、撤销记录丢失。—— Task 11、12 测试与手工验收覆盖。
5. **不支持格式卡死**：ffmpeg 缺失或转码失败时，界面不能无限等待；必须给出明确提示并允许跳过。—— Task 13 测试与手工验收覆盖。

---

### Task 1: 脚手架、应用入口与打包脚本

**Files:**
- Create: `Package.swift`
- Create: `Sources/SoundIsle/SoundIsleApp.swift`
- Create: `Sources/SoundIsle/AppDelegate.swift`
- Create: `Sources/SoundIsleCore/AppInfo.swift`
- Create: `Tests/SoundIsleCoreTests/AppInfoTests.swift`
- Create: `Resources/Info.plist`
- Create: `Scripts/build-app.sh`
- Create: `.gitignore`

**Interfaces:**
- Consumes: 无。
- Produces: `AppInfo.displayName == "声屿"`；`AppInfo.bundleIdentifier == "com.local.soundisle"`；可运行 `build/声屿.app`。

- [ ] **Step 1: 写失败的冒烟测试**

`Tests/SoundIsleCoreTests/AppInfoTests.swift`

```swift
import XCTest
@testable import SoundIsleCore

final class AppInfoTests: XCTestCase {
    func testDisplayNameAndBundleID() {
        XCTAssertEqual(AppInfo.displayName, "声屿")
        XCTAssertEqual(AppInfo.bundleIdentifier, "com.local.soundisle")
        XCTAssertEqual(AppInfo.minimumMacOS, "12.0")
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter AppInfoTests`
Expected: 编译失败，`AppInfo` 未定义。

- [ ] **Step 3: 创建包与入口**

`Package.swift`：`swift-tools-version:5.8`，平台 `.macOS(.v12)`；targets：`SoundIsleCore`（library）、`SoundIsle`（executable，依赖 core）、`SoundIsleCoreTests`。`Sources/SoundIsleCore/AppInfo.swift` 定义三个静态常量。`SoundIsleApp.swift` 用 `@main struct SoundIsleApp: App`，窗口显示占位文本「声屿」。`AppDelegate` 实现 `applicationShouldTerminateAfterLastWindowClosed` 返回 `false`。

- [ ] **Step 4: 写打包脚本与 Info.plist**

`Scripts/build-app.sh`：`swift build -c release`，创建 `build/声屿.app/Contents/{MacOS,Resources}`，复制可执行文件为 `Contents/MacOS/SoundIsle`，复制 `Resources/Info.plist`，`codesign --force --sign -`。Info.plist 含 `CFBundleName=声屿`、`CFBundleIdentifier=com.local.soundisle`、`LSMinimumSystemVersion=12.0`、`NSHighResolutionCapable=true`、`CFBundlePackageType=APPL`、`CFBundleExecutable=SoundIsle`。

`.gitignore`：`.build/`、`build/`、`Vendor/`、`.superpowers/`、`.DS_Store`。

- [ ] **Step 5: 初始化 git 并验证应用能启动**

Run:
```bash
git init && git add . && git commit -m "chore: scaffold SoundIsle package"
swift build
bash Scripts/build-app.sh
open "build/声屿.app"
```
Expected: 出现标题为「声屿」的窗口；Dock 有图标。

- [ ] **Step 6: 提交**

```bash
git add Package.swift Sources Resources Scripts .gitignore Tests
git commit -m "feat: add app scaffold and bundle script"
```

---

### Task 2: 模型、文件名解析、元数据读取与目录扫描

**Files:**
- Create: `Sources/SoundIsleCore/Models/Track.swift`
- Create: `Sources/SoundIsleCore/Models/Playlist.swift`
- Create: `Sources/SoundIsleCore/Library/FilenameParser.swift`
- Create: `Sources/SoundIsleCore/Library/MetadataReader.swift`
- Create: `Sources/SoundIsleCore/Library/LibraryScanner.swift`
- Test: `Tests/SoundIsleCoreTests/FilenameParserTests.swift`
- Test: `Tests/SoundIsleCoreTests/LibraryScannerTests.swift`

**Interfaces:**
- Produces:
  - `struct Track: Identifiable, Codable, Hashable`，字段：`id: UUID`、`url: URL`、`title: String`、`artist: String`、`album: String`、`albumArtist: String?`、`year: Int?`、`trackNumber: Int?`、`genre: String?`、`duration: TimeInterval`、`fileSize: Int64`、`modifiedAt: Date`、`artworkFileName: String?`、`isMissing: Bool`（默认 `false`）。
  - `struct Playlist: Identifiable, Codable, Hashable`，字段：`id: UUID`、`name: String`、`trackIDs: [UUID]`。
  - `struct ParsedFilename: Equatable`：`title: String`、`artist: String?`、`trackNumber: Int?`。
  - `enum FilenameParser { static func parse(filename: String) -> ParsedFilename }`。
  - `struct AudioMetadata`：`title/artist/album/albumArtist: String?`、`year/trackNumber: Int?`、`genre: String?`、`duration: TimeInterval`、`artworkData: Data?`。
  - `protocol MetadataReading { func read(url: URL) async -> AudioMetadata? }`；`struct AVFoundationMetadataReader: MetadataReading`。
  - `struct ScanResult { var tracks: [Track]; var unreadable: [URL] }`
  - `enum LibraryScanner { static let supportedExtensions: Set<String>; static func scan(folders: [URL], reader: MetadataReading = AVFoundationMetadataReader()) async -> ScanResult }`。
  - `enum TrackFactory { static func make(url: URL, metadata: AudioMetadata?, id: UUID = UUID()) -> Track }`。

- [ ] **Step 1: 写文件名解析的失败测试**

`Tests/SoundIsleCoreTests/FilenameParserTests.swift`

```swift
func testTitleArtistWithoutSpaces() {
    let p = FilenameParser.parse(filename: "母亲-阎维文.mp3")
    XCTAssertEqual(p.title, "母亲")
    XCTAssertEqual(p.artist, "阎维文")
}
func testArtistTitleWithSpacedHyphen() {
    let p = FilenameParser.parse(filename: "牛奶咖啡 - 咖喱咖喱.mp3")
    XCTAssertEqual(p.artist, "牛奶咖啡")
    XCTAssertEqual(p.title, "咖喱咖喱")
}
func testTrackNumberPrefix() {
    let p = FilenameParser.parse(filename: "01 母亲.mp3")
    XCTAssertEqual(p.trackNumber, 1)
    XCTAssertEqual(p.title, "母亲")
}
func testMultipleDotsAndHyphen() {
    let p = FilenameParser.parse(filename: "强军战歌.Live.-阎维文.mp3")
    XCTAssertEqual(p.title, "强军战歌.Live.")
    XCTAssertEqual(p.artist, "阎维文")
}
func testNoSeparatorKeepsWholeName() {
    let p = FilenameParser.parse(filename: "新闻联播开场曲.mp3")
    XCTAssertEqual(p.title, "新闻联播开场曲")
    XCTAssertNil(p.artist)
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter FilenameParserTests`
Expected: `FilenameParser` 未定义。

- [ ] **Step 3: 实现模型与解析器**

规则顺序：去扩展名 → 匹配开头 `^(\d{1,3})[.\s-]+` 提取曲目号 → 若含 `" - "` 按最后一个切分（左歌手右标题）→ 否则若含 `-` 按最后一个切分（左标题右歌手）→ 否则整串为标题。`TrackFactory` 用元数据非空字段覆盖文件名推断；元数据缺失时用推断值，仍为空则标题用去扩展名文件名。

- [ ] **Step 4: 运行解析测试确认通过**

Run: `swift test --filter FilenameParserTests`
Expected: 5 个测试全部 PASS。

- [ ] **Step 5: 写扫描与元数据的失败测试**

`Tests/SoundIsleCoreTests/LibraryScannerTests.swift` 用 `AVAudioFile` 在临时目录生成 1 秒静音 `.wav`，断言 `scan(...).tracks` 返回 1 个 `Track`，`title` 为文件名去扩展名，`duration` 在 `0.9...1.1`；再放一个扩展名合法但内容损坏的 `.mp3`，断言它进入 `unreadable` 且不阻塞合法文件。再写一个 `testMergePrefersMetadata`：`TrackFactory.make` 传入标题/歌手元数据时覆盖文件名推断。

- [ ] **Step 6: 运行测试确认失败，然后实现**

Run: `swift test --filter LibraryScannerTests`
Expected: 失败。实现 `AVFoundationMetadataReader`：用 `AVURLAsset` 的 `load(.commonMetadata)` 与 `load(.duration)`，映射 `title/artist/album/albumArtist/year/trackNumber/genre` 与 `data(for: .commonKeyArtwork)`。`LibraryScanner` 用 `FileManager.enumerator` 递归，按扩展名集合过滤（mp3、m4a、m4r、aac、wav、aiff、flac、alac、mp4、ape、wma、ogg、oga、opus、wv、tta、dsf、dff），排序后并发读取元数据。

- [ ] **Step 7: 运行全部测试并提交**

Run: `swift test --filter 'FilenameParserTests|LibraryScannerTests'`
Expected: PASS。

```bash
git add Sources Tests
git commit -m "feat: add track models, filename parsing and library scanning"
```

---

### Task 3: 索引与播放列表持久化、增量扫描

**Files:**
- Create: `Sources/SoundIsleCore/Models/LibraryData.swift`
- Create: `Sources/SoundIsleCore/Library/IndexStore.swift`
- Create: `Sources/SoundIsleCore/Library/LibraryStore.swift`
- Create: `Sources/SoundIsleCore/Settings/AppSettings.swift`
- Test: `Tests/SoundIsleCoreTests/LibraryStoreTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `Track`、`Playlist`、`LibraryScanner`。
- Produces:
  - `struct LibraryIndex: Codable { var tracks: [Track]; var folders: [URL] }`
  - `final class IndexStore`：`init(directory: URL)`、`func loadIndex() -> LibraryIndex`、`func saveIndex(_:) throws`、`func loadPlaylists() -> [Playlist]`、`func savePlaylists(_:) throws`、`func loadSettings() -> AppSettings`、`func saveSettings(_:) throws`。所有写入原子 + `.bak`。
  - `final class LibraryStore`：`init(directory: URL)`、`var index: LibraryIndex`、`var playlists: [Playlist]`、`var settings: AppSettings`、`func load()`、`func addFolder(_ url: URL) async`、`func removeFolder(_ url: URL)`、`func rescan(reader: MetadataReading = AVFoundationMetadataReader()) async`、`func updateTrack(_ track: Track)`、`func removeMissingTracks()`。
  - `struct AppSettings: Codable`：`themePreset: String = "deepBlue"`、`themeMode: String = "system"`、`customAccentHex: String?`、`lyricsOpacity: Double = 0.26`、`lyricsOutline: Bool = false`、`lyricsLineMode: String = "two"`、`rowStyle: String = "index"`、`showMainSpectrum: Bool = false`、`hideFromScreenCapture: Bool = true`、`keepRunningOnClose: Bool = true`、`miniAlwaysOnTop: Bool = true`、`onlineLyricsEnabled: Bool = true`、`playbackMode: String = "sequential"`、`lastQueue: [UUID] = []`、`lastTrackID: UUID?`、`lastPosition: TimeInterval = 0`、`ffmpegPath: String?`。

- [ ] **Step 1: 写持久化的失败测试**

`LibraryStoreTests`（用临时目录）：
- 保存 1 个 `Track` + 1 个 `Playlist` 后重新加载，字段一致。
- 把 `library.json` 写坏（写入 `"{"`）后调用 `loadIndex()`，应返回空索引，不抛异常；再断言 `playlists.json` 内容仍在。
- 写坏 `playlists.json` 但保留 `playlists.json.bak`，加载应恢复 `.bak` 内容。

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter LibraryStoreTests`
Expected: 类型未定义。

- [ ] **Step 3: 实现原子写入与备份**

`IndexStore.write(_ data: Data, to url: URL)`：先写 `url.tmp`，若 `url` 存在则复制为 `url.bak`，再用 `FileManager.replaceItemAt` 替换。读取失败时优先 `.bak`，再返回默认值。索引损坏只影响 `library.json`，不触碰 `playlists.json` / `settings.json` / `undo/`。

- [ ] **Step 4: 实现增量扫描**

`LibraryStore.rescan`：对每个已导入文件夹扫描，用 `url + fileSize + modifiedAt` 与现有曲目比对；新文件加入，变化文件更新元数据但保留 `id`；已消失文件标记 `isMissing = true` 并保留在索引与播放列表中；提供 `missingTracks: [Track]` 与 `unreadableURLs: [URL]` 供设置页展示（支持重新定位或移除）。封面数据写入 `covers/<track.id>.jpg` 并更新 `artworkFileName`。保留播放列表与设置。

- [ ] **Step 5: 运行测试并提交**

Run: `swift test --filter LibraryStoreTests`
Expected: PASS。

```bash
git add Sources Tests
git commit -m "feat: persist library index, playlists and settings safely"
```

---

### Task 4: 播放队列与音频引擎

**Files:**
- Create: `Sources/SoundIsleCore/Playback/PlaybackQueue.swift`
- Create: `Sources/SoundIsleCore/Playback/PlayerEngine.swift`
- Test: `Tests/SoundIsleCoreTests/PlaybackQueueTests.swift`

**Interfaces:**
- Consumes: `Track`、`Track.id`。
- Produces:
  - `enum PlaybackMode: String, Codable, CaseIterable { case sequential, repeatAll, repeatOne, shuffle }`
  - `struct PlaybackQueue`：`init(trackIDs: [UUID], currentIndex: Int = 0, mode: PlaybackMode = .sequential)`、`var currentID: UUID?`、`mutating func next() -> UUID?`、`mutating func previous() -> UUID?`、`mutating func setMode(_:)`、`mutating func replace(with trackIDs: [UUID], startAt index: Int)`。
  - `final class PlayerEngine: ObservableObject`：`@Published private(set) var isPlaying: Bool`、`@Published private(set) var position: TimeInterval`、`@Published private(set) var duration: TimeInterval`、`@Published private(set) var spectrum: [Float]`；`func load(url: URL) throws`、`func play()`、`func pause()`、`func seek(to:)`、`func setVolume(_:)`、`var onFinish: (() -> Void)?`。

- [ ] **Step 1: 写队列测试**

```swift
func testSequentialStopsAtEnd() {
    var q = PlaybackQueue(trackIDs: [a, b], mode: .sequential)
    XCTAssertEqual(q.next(), b)
    XCTAssertNil(q.next())
}
func testRepeatAllWraps() {
    var q = PlaybackQueue(trackIDs: [a, b], mode: .repeatAll)
    XCTAssertEqual(q.next(), b)
    XCTAssertEqual(q.next(), a)
}
func testRepeatOneStays() {
    var q = PlaybackQueue(trackIDs: [a, b], mode: .repeatOne)
    XCTAssertEqual(q.next(), a)
}
func testShuffleCyclesThroughAllTracksOnce() {
    var q = PlaybackQueue(trackIDs: [a, b, c], mode: .shuffle)
    var seen = Set<UUID>()
    for _ in 0..<3 { if let id = q.next() { seen.insert(id) } }
    XCTAssertEqual(seen.count, 3)
}
func testPreviousFromFirstWrapsOnlyWhenRepeating() {
    var q = PlaybackQueue(trackIDs: [a, b], mode: .repeatAll)
    XCTAssertEqual(q.previous(), b)
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter PlaybackQueueTests`
Expected: 未定义。

- [ ] **Step 3: 实现队列**

随机模式维护一个洗牌后的顺序数组，每轮用尽后重新洗牌。`replace` 保留当前模式。

- [ ] **Step 4: 实现 `PlayerEngine`**

`AVAudioEngine` + `AVAudioPlayerNode`；`load` 用 `AVAudioFile`，`scheduleSegment` 从当前帧开始；位置由 `playerNode.lastRenderTime` 与 `playerTime(forNodeTime:)` 计算。`seek` 停止、按新帧调度、若原来在播放则恢复。`mainMixerNode.installTap` 取 1024 帧，计算 24 段频谱发布到 `spectrum`。`onFinish` 在调度完成回调里调用。

- [ ] **Step 5: 手工验证播放**

Run: `swift test --filter PlaybackQueueTests`（PASS）；再在 Task 5 的界面里播放 `~/Music` 中的 mp3，确认出声、进度更新、暂停/恢复。

- [ ] **Step 6: 提交**

```bash
git add Sources Tests
git commit -m "feat: add playback queue and AVAudioEngine player"
```

---

### Task 5: 主窗口界面骨架

**Files:**
- Create: `Sources/SoundIsle/Views/MainWindowView.swift`
- Create: `Sources/SoundIsle/Views/SidebarView.swift`
- Create: `Sources/SoundIsle/Views/TrackListView.swift`
- Create: `Sources/SoundIsle/Views/PlayerBarView.swift`
- Create: `Sources/SoundIsle/Views/SettingsView.swift`
- Create: `Sources/SoundIsle/UI/Icons.swift`
- Create: `Sources/SoundIsle/UI/AppModel.swift`
- Modify: `Sources/SoundIsle/SoundIsleApp.swift`

**Interfaces:**
- Consumes: `LibraryStore`、`Track`、`PlaybackQueue`、`PlayerEngine`。
- Produces: `@MainActor final class AppModel: ObservableObject`，持有 `library: LibraryStore`、`engine: PlayerEngine`、`queue: PlaybackQueue`，方法 `openFolders() -> [URL]`、`play(trackID:)`、`togglePlayPause()`、`next()/previous()`、`rescan()`。
  - `Icons`：返回 `Image` 的静态属性/方法，统一 20px 网格、1.75 描边、圆角端点；`play/pause` 为实心。

- [ ] **Step 1: 搭建三块布局**

主窗口 900×600，`HStack`：左侧 190px 侧栏（全部音乐、导入文件夹、用户播放列表、添加文件夹按钮），中间曲目列表（标题栏 + 行），底部 76px 播放条。窗口背景按深空蓝深色版；磨砂面板用 `.background(.ultraThinMaterial)` 叠加半透明色。

- [ ] **Step 2: 播放条按定稿比例实现**

中心列固定 360px：播放键 38px、上一首/下一首按钮 34px（图标 20px）、间距 20px、进度条高 4px 且与中心列同宽；左侧 42px 封面 + 标题/歌手；右侧 18px 音量/歌词图标与细音量滑杆。

- [ ] **Step 3: 接通导入与播放**

「添加文件夹」用 `NSOpenPanel` 选择目录，同时支持把文件/文件夹拖进窗口（`onDrop` 解析 `URL`）→ `AppModel` 扫描 → 列表显示；点击行播放/暂停；快捷键：空格播放暂停、←/→ 快退/快进 5 秒、⌘F 聚焦搜索。启动时 `LibraryStore.load()` 并增量扫描。

- [ ] **Step 3b: 恢复上次状态**

播放队列、当前曲目与播放位置写入设置（`lastQueue: [UUID]`、`lastTrackID: UUID?`、`lastPosition: TimeInterval`）；启动时恢复但保持暂停，不自动播放。`SettingsView` 先建空壳（音乐文件夹、缓存、歌词、外观四个分组标题），后续任务填充。

- [ ] **Step 4: 手工验收**

Run:
```bash
swift build && bash Scripts/build-app.sh && open "build/声屿.app"
```
Expected: 导入 `~/Music` 后看到 115 首；点击《母亲》出声；播放条进度走动；暂停/继续正常。把一首已导入文件改名后重新扫描，该曲目标为缺失且播放列表条目仍在。

- [ ] **Step 5: 提交**

```bash
git add Sources
git commit -m "feat: add main window, library sidebar and player bar"
```

---

### Task 6: 播放列表、搜索与排序

**Files:**
- Create: `Sources/SoundIsleCore/Library/TrackQuery.swift`
- Create: `Sources/SoundIsleCore/Playlists/PlaylistStore.swift`
- Modify: `Sources/SoundIsle/Views/SidebarView.swift`
- Modify: `Sources/SoundIsle/Views/TrackListView.swift`
- Modify: `Sources/SoundIsleCore/Library/LibraryStore.swift`
- Test: `Tests/SoundIsleCoreTests/TrackQueryTests.swift`
- Test: `Tests/SoundIsleCoreTests/PlaylistStoreTests.swift`

**Interfaces:**
- Produces:
  - `enum TrackSort: String, CaseIterable { case title, artist, album, duration, dateAdded }`
  - `enum TrackQuery { static func apply(_ tracks: [Track], query: String, sort: TrackSort, ascending: Bool) -> [Track] }`：查询匹配标题/歌手/专辑/文件名，大小写不敏感。
  - `final class PlaylistStore`：`init(playlists: [Playlist] = [], persist: (( [Playlist] ) throws -> Void)? = nil)`、`func create(name:) -> Playlist`、`func rename(id:to:)`、`func delete(id:)`、`func add(trackIDs:to:)`、`func remove(trackID:from:)`、`func move(from:to:in:)`；所有变更写回 `IndexStore.savePlaylists`。

- [ ] **Step 1: 写查询与播放列表测试**

```swift
func testSearchMatchesArtistAndFilename() {
    let result = TrackQuery.apply([mother, motherland], query: "阎维文", sort: .title, ascending: true)
    XCTAssertEqual(result.map(\.title), ["母亲"])
}
func testSortByDurationAscending() {
    let result = TrackQuery.apply([long, short], query: "", sort: .duration, ascending: true)
    XCTAssertEqual(result.map(\.title), [short.title, long.title])
}
func testPlaylistReorder() {
    var store = PlaylistStore(playlists: [p])
    store.move(from: 0, to: 1, in: p.id)
    XCTAssertEqual(store.playlists[0].trackIDs, [b, a])
}
```

- [ ] **Step 2: 运行确认失败，然后实现**

Run: `swift test --filter 'TrackQueryTests|PlaylistStoreTests'`
Expected: 失败 → 实现 → PASS。

- [ ] **Step 3: 接入界面**

侧栏显示「全部音乐、最近添加（按 modifiedAt 倒序）、导入文件夹、用户播放列表」；右键菜单重命名/删除；曲目可拖入播放列表；顶部搜索框实时过滤；表头点击切换排序；播放列表内拖拽排序。播放条左侧增加顺序/列表循环/单曲循环/随机四个模式按钮（互斥，切换写入设置）。曲目行按 `rowStyle` 显示序号或内嵌封面缩略图。

- [ ] **Step 4: 手工验收**

Expected: 搜索「红歌」「阎维文」能过滤；新建「工作时听的」并拖入歌曲；重启后播放列表仍在；排序切换正确。

- [ ] **Step 5: 提交**

```bash
git add Sources Tests
git commit -m "feat: add playlists, search and sorting"
```

---

### Task 7: 菜单栏、媒体键与迷你模式

**Files:**
- Create: `Sources/SoundIsle/MenuBarController.swift`
- Create: `Sources/SoundIsle/MediaKeys.swift`
- Create: `Sources/SoundIsle/MiniPlayerWindowController.swift`
- Create: `Sources/SoundIsle/Views/MiniPlayerView.swift`
- Modify: `Sources/SoundIsle/AppDelegate.swift`
- Modify: `Sources/SoundIsle/UI/AppModel.swift`

**Interfaces:**
- Consumes: `AppModel`、`PlayerEngine`、`PlaybackQueue`。
- Produces: `MiniPlayerWindowController.show()/hide()/toggle()`；菜单栏菜单项：当前歌曲、播放/暂停、上一首、下一首、显示迷你窗、显示/隐藏歌词、锁定/解锁歌词、显示主窗口、退出。

- [ ] **Step 1: 实现菜单栏**

`NSStatusItem` 使用模板图标（`NSImage(systemSymbolName: "music.note")`）；菜单每次 `menuWillOpen` 刷新当前歌曲与播放状态。关闭主窗口时应用继续运行（受 `settings.keepRunningOnClose` 控制）。

- [ ] **Step 2: 实现媒体键**

`MPRemoteCommandCenter.shared()` 注册 `play/pause/togglePlayPause/nextTrack/previousTrack`，更新 `MPNowPlayingInfoCenter` 的标题、歌手、时长、已播时间。

- [ ] **Step 3: 实现迷你窗**

无边框 `NSPanel`，宽 520 高 66，圆角 32，磨砂；内容：44px 封面、标题/歌手、实时频谱、时间、上一首/播放/下一首、展开按钮、底部 2px 进度；可拖动并记忆位置；`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`；`level = .floating`（受 `miniAlwaysOnTop` 控制）；`sharingType` 受 `hideFromScreenCapture` 控制，默认不参与录屏。

- [ ] **Step 4: 手工验收**

Expected: 菜单栏图标可播放/暂停/切歌；按 F8 能暂停；迷你窗显示、拖动、展开回主窗口；关闭主窗口后音乐继续。

- [ ] **Step 5: 提交**

```bash
git add Sources
git commit -m "feat: add menu bar, media keys and mini player"
```

---

### Task 8: 歌词解析、同名 lrc 与悬浮歌词窗

**Files:**
- Create: `Sources/SoundIsleCore/Lyrics/LRCParser.swift`
- Create: `Sources/SoundIsleCore/Lyrics/LyricsSidecar.swift`
- Create: `Sources/SoundIsleCore/Lyrics/LyricsFont.swift`
- Create: `Sources/SoundIsle/LyricsOverlayWindowController.swift`
- Create: `Sources/SoundIsle/Views/LyricsOverlayView.swift`
- Modify: `Sources/SoundIsle/UI/AppModel.swift`
- Test: `Tests/SoundIsleCoreTests/LRCParserTests.swift`
- Test: `Tests/SoundIsleCoreTests/LyricsFontTests.swift`
- Test: `Tests/SoundIsleCoreTests/LyricsSidecarTests.swift`

**Interfaces:**
- Produces:
  - `struct LyricLine: Equatable { let time: TimeInterval; let text: String }`
  - `struct Lyrics: Equatable { var lines: [LyricLine]; var isSynced: Bool; func index(at time: TimeInterval) -> Int? }`
  - `enum LRCParser { static func parse(_ text: String) -> Lyrics }`：支持一行多个 `[mm:ss.xx]`、`[offset:±ms]`；无时间戳时返回 `isSynced=false`，每行 `time=0`。
  - `enum LyricsSidecar { static func find(for track: Track) -> URL? }`：同目录下与音频同名的 `.lrc`（大小写与括号宽松匹配）。
  - `enum LyricsFont { static func size(forWidth width: CGFloat) -> CGFloat }`：线性映射 320→18、900→36，范围外 clamp。
  - `LyricsOverlayWindowController`：`show()/hide()/toggleLock()/isLocked`；窗口 `level = .floating`、`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`、`isMovableByWindowBackground = true`；锁定时 `ignoresMouseEvents = true`。

- [ ] **Step 1: 写解析与字号测试**

```swift
func testMultipleTimestamps() {
    let l = LRCParser.parse("[00:12.50][01:20.00]一条大河波浪宽\n[00:15.00]风吹稻花香两岸")
    XCTAssertEqual(l.lines.map(\.time), [12.5, 15, 80])
    XCTAssertEqual(l.lines[0].text, "一条大河波浪宽")
}
func testOffsetApplied() {
    let l = LRCParser.parse("[offset:500]\n[00:10.00]歌词")
    XCTAssertEqual(l.lines[0].time, 10.5)
}
func testPlainTextMarkedUnsynced() {
    let l = LRCParser.parse("第一行\n第二行")
    XCTAssertFalse(l.isSynced)
    XCTAssertEqual(l.lines.count, 2)
}
func testFontScaling() {
    XCTAssertEqual(LyricsFont.size(forWidth: 320), 18)
    XCTAssertEqual(LyricsFont.size(forWidth: 900), 36)
    XCTAssertEqual(LyricsFont.size(forWidth: 200), 18)
    XCTAssertEqual(LyricsFont.size(forWidth: 1200), 36)
}
```

- [ ] **Step 2: 运行确认失败，实现并跑通**

Run: `swift test --filter 'LRCParserTests|LyricsFontTests|LyricsSidecarTests'`
Expected: 失败 → 实现 → PASS。`LyricsSidecarTests` 在临时目录创建 `母亲-阎维文.mp3` 与 `母亲-阎维文.LRC`，断言能匹配。

- [ ] **Step 3: 实现悬浮歌词窗**

无边框透明 `NSPanel`，磨砂背景（`NSVisualEffectView` + 半透明色），默认不透明度 0.26（设置里可调）；支持单行 / 双行（当前句 + 下一句）切换；可选文字描边（浅色桌面用）。宽度变化时用 `LyricsFont.size(forWidth:)` 更新字号；右下角拖拽改大小；未锁定时悬停显示按钮（解锁、A−、A+、透明度、关闭）；锁定后全部隐藏并鼠标穿透；记忆位置/尺寸/透明度/模式/锁定；默认 `sharingType = .none`（受 `hideFromScreenCapture` 控制）。

- [ ] **Step 4: 接入播放进度**

`AppModel` 根据 `engine.position` 用 `Lyrics.index(at:)` 更新当前行；切歌时优先加载同名 `.lrc`，没有则显示「暂无歌词」与「导入歌词…」入口。

- [ ] **Step 5: 手工验收（含锁定逃生）**

Expected: 播放有 `.lrc` 的歌显示同步歌词；拖动边缘字号变化；锁定后鼠标可点击歌词后面的窗口；从菜单栏和主窗口都能解锁；跨桌面/全屏仍显示；录屏时默认不出现。

- [ ] **Step 6: 提交**

```bash
git add Sources Tests
git commit -m "feat: add lrc parsing and floating lyrics overlay"
```

---

### Task 9: 在线歌词、手动导入与缓存

**Files:**
- Create: `Sources/SoundIsleCore/Lyrics/LRCLIBClient.swift`
- Create: `Sources/SoundIsleCore/Lyrics/LyricsCache.swift`
- Create: `Sources/SoundIsleCore/Lyrics/LyricsService.swift`
- Modify: `Sources/SoundIsle/UI/AppModel.swift`
- Modify: `Sources/SoundIsle/Views/LyricsOverlayView.swift`
- Test: `Tests/SoundIsleCoreTests/LyricsServiceTests.swift`
- Test: `Tests/SoundIsleCoreTests/LRCLIBClientTests.swift`

**Interfaces:**
- Produces:
  - `protocol LyricsFetching { func fetch(title: String, artist: String, duration: TimeInterval) async throws -> Lyrics? }`
  - `struct LRCLIBClient: LyricsFetching`：GET `https://lrclib.net/api/get?track_name=…&artist_name=…&duration=…`，优先 `syncedLyrics`，其次 `plainLyrics`；可注入 `URLSession`。
  - `final class LyricsCache`：`init(directory: URL)`、`func load(title:artist:duration:) -> Lyrics?`、`func save(_ lyrics: Lyrics, title:artist:duration:) throws`、`func saveOverride(_ lyrics: Lyrics, for trackID: UUID) throws`、`func loadOverride(for trackID: UUID) -> Lyrics?`。
  - `enum LyricsOrigin: String, Codable { case override, sidecar, online, none }`
  - `struct ResolvedLyrics { var lyrics: Lyrics; var origin: LyricsOrigin; var sourceURL: URL? }`
  - `final class LyricsService`：`init(cache: LyricsCache, client: LyricsFetching)`、`func resolve(for track: Track) async -> ResolvedLyrics?`。优先级：override > 同名 lrc > 在线缓存 > 在线查询。

- [ ] **Step 1: 写优先级与缓存测试**

用假 `LyricsFetching` 返回固定歌词；断言 override 存在时不再调用网络；无 override 有 sidecar 时用 sidecar；都没有时调用一次网络并写缓存，第二次调用不访问网络。缓存用临时目录 roundtrip。

- [ ] **Step 2: 写 LRCLIB 解析测试**

用 `URLProtocol` 子类拦截请求，返回：
```json
{"syncedLyrics":"[00:01.00]第一句\n[00:02.00]第二句","plainLyrics":"第一句\n第二句"}
```
断言 `fetch` 返回 `isSynced == true` 且两行。再测 404 返回 nil。

- [ ] **Step 3: 运行确认失败，实现并跑通**

Run: `swift test --filter 'LyricsServiceTests|LRCLIBClientTests'`
Expected: 失败 → 实现 → PASS。

- [ ] **Step 4: 接入界面**

「更换歌词…」在歌词窗菜单与主窗口菜单都可用：选择 `.lrc`/`.txt` → 保存为 override → 立即刷新；提供「恢复自动匹配」清除 override。播放切歌时异步 `resolve`，不阻塞 UI；失败静默，提供重试按钮。

- [ ] **Step 5: 手工验收**

Expected: 无 `.lrc` 的歌能在线匹配（有网时）；匹配后离线再播仍显示（缓存）；导入的歌词覆盖自动结果；恢复自动后回到原来源。

- [ ] **Step 6: 提交**

```bash
git add Sources Tests
git commit -m "feat: add online lyrics matching, cache and manual override"
```

---

### Task 10: TagLib 静态库、C++ 桥接与标签读写

**Files:**
- Create: `Scripts/build-taglib.sh`
- Create: `Sources/CTagLib/include/CTagLib.h`
- Create: `Sources/CTagLib/taglib_bridge.cpp`
- Create: `Sources/SoundIsleCore/Tags/TagService.swift`
- Modify: `Package.swift`
- Test: `Tests/SoundIsleCoreTests/TagServiceTests.swift`

**Interfaces:**
- Produces:
  - C API（`CTagLib.h`）：
    - `char *soundisle_read_tags(const char *path);`
    - `int soundisle_write_tags(const char *path, const char *json, char **error);`
    - `void soundisle_free(char *ptr);`
  - `struct TagFields: Codable, Equatable`：`title/artist/album/albumArtist/genre: String?`、`year/trackNumber: Int?`、`artworkBase64: String?`；所有字段默认值为 `nil`，便于局部编辑。
  - `final class TagService`：`func read(from url: URL) -> TagFields?`、`func write(_ fields: TagFields, to url: URL) throws`、`static func jsonData(from fields: TagFields) -> Data`。
  - 读取返回 JSON：`{"title":…,"artist":…,"album":…,"albumArtist":…,"year":…,"trackNumber":…,"genre":…,"artworkBase64":…}`；缺失字段为 `null`。

- [ ] **Step 1: 写构建脚本**

`Scripts/build-taglib.sh`：若 `Vendor/taglib/lib/libtag.a` 不存在，则 `git clone --depth 1 --branch v1.13.1 https://github.com/taglib/taglib.git Vendor/taglib-src`，用 `cmake -DBUILD_SHARED_LIBS=OFF -DWITH_MP4=ON -DWITH_APE=ON` 构建并安装到 `Vendor/taglib`。`Package.swift` 的 `CTagLib` target 设置 `publicHeadersPath: "include"`、`headerSearchPath("Vendor/taglib/include")` 与 linker `-L Vendor/taglib/lib -ltag -lz`。

- [ ] **Step 2: 写桥接与 Swift 封装**

`taglib_bridge.cpp` 用 TagLib 的 `FileRef` / `Tag` / `MP4`、`APE` 等；读标签组装 JSON（封面读 `Tag::picture` 后 base64）；写标签解析 JSON 并 `save()`；错误信息写入 `*error`（`strdup`）。Swift 端用 `Codable` 解析，注意 `soundisle_free` 释放字符串。

- [ ] **Step 3: 写测试**

```swift
func testReadMissingFileReturnsNil() {
    XCTAssertNil(TagService().read(from: URL(fileURLWithPath: "/tmp/does-not-exist.mp3")))
}
func testJSONRoundTrip() throws {
    let f = TagFields(title: "母亲", artist: "阎维文", album: "战士情歌", year: 2004, trackNumber: 1, genre: nil, artworkBase64: nil)
    let data = TagService.jsonData(from: f)
    let back = try JSONDecoder().decode(TagFields.self, from: data)
    XCTAssertEqual(back, f)
}
func testWriteToNonAudioFileThrows() {
    let url = temporaryFile(named: "not-audio.mp3")
    XCTAssertThrowsError(try TagService().write(TagFields(title: "x"), to: url))
}
func testRoundTripOnRealCopy() throws {
    guard let src = ProcessInfo.processInfo.environment["SOUNDISLE_TEST_AUDIO"] else {
        throw XCTSkip("set SOUNDISLE_TEST_AUDIO to an mp3 to run")
    }
    let copy = copyToTemp(src)
    let service = TagService()
    var fields = service.read(from: copy) ?? TagFields()
    fields.title = "测试标题"
    try service.write(fields, to: copy)
    XCTAssertEqual(service.read(from: copy)?.title, "测试标题")
}
```

- [ ] **Step 4: 运行与手工验证**

Run:
```bash
bash Scripts/build-taglib.sh
swift test --filter TagServiceTests
SOUNDISLE_TEST_AUDIO="$HOME/Music/红歌/母亲-阎维文.mp3" swift test --filter testRoundTripOnRealCopy
```
Expected: 前三个 PASS；真实文件测试 PASS（只改临时副本）。

- [ ] **Step 5: 提交**

```bash
git add Scripts Sources Package.swift Tests
git commit -m "feat: link TagLib and add tag read/write bridge"
```

---

### Task 11: 乱码修复、批量标签编辑与撤销

**Files:**
- Create: `Sources/SoundIsleCore/Tags/MojibakeRepair.swift`
- Create: `Sources/SoundIsleCore/Tags/TagEditUndoStore.swift`
- Create: `Sources/SoundIsle/Views/TagEditorView.swift`
- Modify: `Sources/SoundIsle/UI/AppModel.swift`
- Modify: `Sources/SoundIsle/Views/MainWindowView.swift`
- Test: `Tests/SoundIsleCoreTests/MojibakeRepairTests.swift`
- Test: `Tests/SoundIsleCoreTests/TagEditUndoStoreTests.swift`

**Interfaces:**
- Produces:
  - `enum MojibakeRepair { static func repaired(_ text: String) -> String? }`：检测 Latin-1 误解码，尝试 UTF-8 与 GB18030，返回中文字符比例更高的结果；无明显改善返回 nil。
  - `struct TagUndoEntry: Codable { var url: URL; var before: TagFields; var after: TagFields; var date: Date }`
  - `final class TagEditUndoStore`：`init(directory: URL, limit: Int = 50)`、`func record(_ entry:) throws`、`func undoLast() throws -> TagUndoEntry?`、`var entries: [TagUndoEntry]`。

- [ ] **Step 1: 写乱码与撤销测试**

```swift
func testRepairUTF8MisreadAsLatin1() {
    let bytes = Data([0xE6,0xAF,0x8D,0xE4,0xBA,0xB2]) // 母亲
    let broken = String(data: bytes, encoding: .isoLatin1)!
    XCTAssertEqual(MojibakeRepair.repaired(broken), "母亲")
}
func testRepairGB18030MisreadAsLatin1() {
    let bytes = Data([0xC4,0xB8,0xC7,0xD7]) // 母亲 GBK
    let broken = String(data: bytes, encoding: .isoLatin1)!
    XCTAssertEqual(MojibakeRepair.repaired(broken), "母亲")
}
func testNormalChineseUnchanged() {
    XCTAssertNil(MojibakeRepair.repaired("母亲"))
}
```

撤销测试：临时目录记录两条，`undoLast()` 返回第二条；超过 50 条丢弃最旧；重新初始化后仍能读取。

- [ ] **Step 2: 运行确认失败，实现并跑通**

Run: `swift test --filter 'MojibakeRepairTests|TagEditUndoStoreTests'`
Expected: 失败 → 实现 → PASS。GB18030 用 `CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))`。

- [ ] **Step 3: 实现编辑界面**

右键「编辑标签…」打开 sheet：显示标题/歌手/专辑/专辑歌手/年份/曲目号/流派/封面；多选时显示批量字段（留空不修改）；每个文本字段旁有「修复乱码」按钮，预览后应用；该格式不支持写封面时封面控件禁用并给出说明；保存时调用 `TagService.write`，记录 before/after 到撤销库，成功后刷新库索引。设置页提供「清空编辑撤销记录」。

- [ ] **Step 4: 手工验收**

Expected: 复制一首歌到临时目录，改标题与歌手后重新扫描显示新值；撤销恢复旧值；构造的 GBK 乱码字段可一键还原；批量修改 3 首歌的专辑成功。

- [ ] **Step 5: 提交**

```bash
git add Sources Tests
git commit -m "feat: add tag editing, mojibake repair and undo"
```

---

### Task 12: 按标签整理文件（预览 + 撤销）

**Files:**
- Create: `Sources/SoundIsleCore/Organize/FileOrganizer.swift`
- Create: `Sources/SoundIsleCore/Organize/OrganizeTemplate.swift`
- Create: `Sources/SoundIsleCore/Organize/OrganizeUndoStore.swift`
- Create: `Sources/SoundIsle/Views/OrganizerPreviewView.swift`
- Modify: `Sources/SoundIsle/UI/AppModel.swift`
- Modify: `Sources/SoundIsle/Views/TrackListView.swift`
- Test: `Tests/SoundIsleCoreTests/FileOrganizerTests.swift`

**Interfaces:**
- Produces:
  - `enum OrganizeTemplate { static func render(template: String, track: Track, root: URL) -> URL }`：变量 `{artist}` `{album}` `{albumArtist}` `{title}` `{track}` `{year}` `{ext}`；未知值回退「未知歌手/未知专辑」；非法字符替换（`/` → `、`，`:` → `-`）。
  - `struct OrganizePlanItem: Equatable { var source: URL; var destination: URL; var conflictResolved: Bool }`
  - `final class FileOrganizer`：`init(undo: OrganizeUndoStore)`、`func plan(_ tracks: [Track], template: String, root: URL, copy: Bool) -> [OrganizePlanItem]`、`func apply(_ items: [OrganizePlanItem], copy: Bool) throws`、`func undoLast() throws`。
  - `final class OrganizeUndoStore`：`func record(_ items: [OrganizePlanItem], copy: Bool) throws`、`func undoLast() throws -> [OrganizePlanItem]?`。

- [ ] **Step 1: 写整理测试**

在临时目录建 `a.mp3`、`b.mp3` 与一个 `destination/母亲.mp3` 冲突文件。测试：
- 模板渲染：`{artist}/{album}/{track} {title}` → `阎维文/战士情歌/1 母亲.mp3`。
- 非法字符：artist `刀郎/云朵` → 目录名 `刀郎、云朵`。
- 冲突：已存在同名目标 → 自动加 ` (2)`，不覆盖原文件。
- `apply(copy: true)` 后源文件仍在、目标存在。
- `undoLast()` 后目标删除、源文件恢复原位。

- [ ] **Step 2: 运行确认失败，实现并跑通**

Run: `swift test --filter FileOrganizerTests`
Expected: 失败 → 实现 → PASS。

- [ ] **Step 3: 实现预览界面**

选中歌曲右键「整理文件…」：模板下拉（内置 `歌手/专辑/曲目 歌名`、`歌手 - 歌名`）、目标根目录选择、移动/复制单选；展示原路径 → 新路径表格与冲突提示；确认后执行并记录撤销；菜单「撤销上次整理」。跨磁盘移动时先复制到目标，再弹出确认询问是否删除源文件。

- [ ] **Step 4: 手工验收**

Expected: 预览路径正确；执行后文件移动；取消不产生任何变化；撤销后文件回到原位置；同名不被覆盖。执行与撤销后都更新 `LibraryStore` 中对应 `Track.url`（保留 `id`），并触发一次轻量扫描刷新路径。

- [ ] **Step 5: 提交**

```bash
git add Sources Tests
git commit -m "feat: add tag-based file organizer with preview and undo"
```

---

### Task 13: 不支持格式的后台转码

**Files:**
- Create: `Sources/SoundIsleCore/Transcode/TranscodeCache.swift`
- Create: `Sources/SoundIsleCore/Transcode/FFmpegLocator.swift`
- Create: `Sources/SoundIsleCore/Transcode/TranscodeQueue.swift`
- Modify: `Sources/SoundIsle/UI/AppModel.swift`
- Modify: `Sources/SoundIsle/Playback/PlayerEngine.swift`
- Test: `Tests/SoundIsleCoreTests/TranscodeCacheTests.swift`
- Test: `Tests/SoundIsleCoreTests/FFmpegLocatorTests.swift`

**Interfaces:**
- Produces:
  - `enum TranscodeCache { static let version = 1; static func key(url: URL, fileSize: Int64, modifiedAt: Date, version: Int = version) -> String; static func cacheURL(for track: Track, root: URL) -> URL }`：key 为 `path|size|mtime|version` 的 SHA256 前 32 位，缓存文件 `<key>.m4a`。
  - `enum FFmpegLocator { static func find(customPath: String? = nil) -> URL? }`：依次检查设置里的自定义路径、`/usr/local/bin/ffmpeg`、`/opt/homebrew/bin/ffmpeg`、`PATH`。
  - `enum TranscodeError: Error { case ffmpegMissing, failed(String) }`
  - `final class TranscodeQueue`：`init(cacheRoot: URL, ffmpeg: URL?)`、`func cachedURL(for track: Track) -> URL?`、`func enqueue(_ track: Track, priority: Bool)`、`func ensureCached(_ track: Track) async throws -> URL`、`var isProcessing: Bool`。
  - `enum AudioFormatSupport { static func isNative(_ url: URL) -> Bool }`：原生集合 mp3/m4a/m4r/aac/wav/aiff/aif/flac/mp4/alac。
  - `struct FFprobeReader { static func duration(of url: URL, ffmpeg: URL) -> TimeInterval? }`：对非原生格式用 `ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1` 取时长；扫描时为这类曲目补时长（标签仍由文件名/TagLib 提供）。

- [ ] **Step 1: 写缓存键与原生格式测试**

```swift
func testKeyStableAndSensitiveToMtime() {
    let url = URL(fileURLWithPath: "/tmp/a.ape")
    let k1 = TranscodeCache.key(url: url, fileSize: 10, modifiedAt: Date(timeIntervalSince1970: 1))
    let k2 = TranscodeCache.key(url: url, fileSize: 10, modifiedAt: Date(timeIntervalSince1970: 1))
    let k3 = TranscodeCache.key(url: url, fileSize: 10, modifiedAt: Date(timeIntervalSince1970: 2))
    XCTAssertEqual(k1, k2); XCTAssertNotEqual(k1, k3)
}
func testNativeFormatDetection() {
    XCTAssertTrue(AudioFormatSupport.isNative(URL(fileURLWithPath: "/a/b.mp3")))
    XCTAssertFalse(AudioFormatSupport.isNative(URL(fileURLWithPath: "/a/b.ape")))
}
func testMissingFFmpegIsReported() async {
    let q = TranscodeQueue(cacheRoot: tmp, ffmpeg: nil)
    do { _ = try await q.ensureCached(track); XCTFail("should throw") }
    catch TranscodeError.ffmpegMissing {}
}
```

- [ ] **Step 2: 运行确认失败，实现并跑通**

Run: `swift test --filter 'TranscodeCacheTests|FFmpegLocatorTests'`
Expected: 失败 → 实现 → PASS。

- [ ] **Step 3: 实现转码队列**

低优先级 `DispatchQueue` 串行执行：`ffmpeg -y -i <src> -vn -c:a alac <dest>.tmp.m4a`，成功后 rename 为目标。播放请求优先插队，最多并 1 个进程。失败时删除临时文件并返回错误。扫描完成后把非原生曲目批量入队。

- [ ] **Step 4: 接入播放**

`AppModel.play`：原生格式直接播；非原生若缓存已存在则播缓存，否则把该曲目插队并显示「正在准备…」，完成后自动开始。其他曲目在后台转换，完成后续播无感。扫描时对非原生文件调用 `FFprobeReader` 补时长（ffmpeg 缺失则时长暂记 0）。`SettingsView` 的缓存分组显示缓存占用、「清理缓存」、FFmpeg 路径（自动检测结果、选择文件、重新检测）。ffmpeg 缺失时，点播非原生格式显示横幅：「需要 FFmpeg 才能播放此格式」，附复制 `brew install ffmpeg`、重新检测、手动选择路径；不转圈、不阻塞其他歌曲。

- [ ] **Step 5: 手工验收**

Expected: 准备一个 ape 或 dsf 文件，播放时出现「正在准备…」并在几秒后播放；之后再次播放立即开始；删除 ffmpeg 后提示安装命令且原生格式仍可播。

- [ ] **Step 6: 提交**

```bash
git add Sources Tests
git commit -m "feat: add background transcode queue for unsupported formats"
```

---

### Task 14: 主题皮肤、自定义强调色与频谱

**Files:**
- Create: `Sources/SoundIsleCore/Theme/ThemePalette.swift`
- Create: `Sources/SoundIsleCore/Playback/SpectrumAnalyzer.swift`
- Create: `Sources/SoundIsle/UI/ThemeEnvironment.swift`
- Create: `Sources/SoundIsle/Views/SettingsView.swift`
- Modify: `Sources/SoundIsle/Views/MainWindowView.swift`
- Modify: `Sources/SoundIsle/Views/MiniPlayerView.swift`
- Modify: `Sources/SoundIsle/Views/LyricsOverlayView.swift`
- Modify: `Sources/SoundIsle/SoundIsleApp.swift`
- Test: `Tests/SoundIsleCoreTests/ThemePaletteTests.swift`
- Test: `Tests/SoundIsleCoreTests/SpectrumAnalyzerTests.swift`

**Interfaces:**
- Produces:
  - `enum ThemePreset: String, Codable, CaseIterable { case deepBlue, morning, inkAmber, celadon, berry, seaSalt }`
  - `enum ThemeMode: String, Codable, CaseIterable { case system, light, dark }`
  - `struct ThemeTokens: Equatable { var accentHex: String; var isDark: Bool }`
  - `enum ThemeCatalog { static func tokens(for preset: ThemePreset, isDark: Bool) -> ThemeTokens }`：深空蓝深 `#7AA2FF` / 浅 `#3E6FE0`；晨光橙 `#C2703D`；墨黑琥珀 `#F5B942`；青瓷 `#4FB89A`；莓紫 `#B48CF2`；海盐 `#3E8FB0`。
  - `enum ThemeResolver { static func isDark(mode: ThemeMode, systemIsDark: Bool) -> Bool }`
  - `enum AccentContrast { static func textColor(on hex: String) -> String }`：根据亮度返回 `#000000` 或 `#FFFFFF`。
  - `struct SpectrumAnalyzer { static func computeBands(samples: [Float], sampleRate: Double, bandCount: Int = 24) -> [Float] }`：静音全 0；正弦波能量落在对应频段。`PlayerEngine` 内部持有平滑后的 `[Float]` 并通过 `@Published spectrum` 暴露。

- [ ] **Step 1: 写主题与频谱测试**

```swift
func testDeepBlueLightAccent() {
    XCTAssertEqual(ThemeCatalog.tokens(for: .deepBlue, isDark: false).accentHex, "#3E6FE0")
    XCTAssertEqual(ThemeCatalog.tokens(for: .deepBlue, isDark: true).accentHex, "#7AA2FF")
}
func testSystemModeResolution() {
    XCTAssertTrue(ThemeResolver.isDark(mode: .system, systemIsDark: true))
    XCTAssertFalse(ThemeResolver.isDark(mode: .light, systemIsDark: true))
}
func testSilenceGivesZeroBands() {
    let bands = SpectrumAnalyzer.computeBands(samples: [Float](repeating: 0, count: 1024), sampleRate: 44100)
    XCTAssertEqual(bands.count, 24)
    XCTAssertTrue(bands.allSatisfy { $0 == 0 })
}
func testSineEnergyIsNonZero() {
    let samples = (0..<1024).map { sin(2 * .pi * 1000 * Float($0) / 44100) }
    let bands = SpectrumAnalyzer.computeBands(samples: samples, sampleRate: 44100)
    XCTAssertGreaterThan(bands.max()!, 0.1)
}
```

- [ ] **Step 2: 运行确认失败，实现并跑通**

Run: `swift test --filter 'ThemePaletteTests|SpectrumAnalyzerTests'`
Expected: 失败 → 实现 → PASS。频谱用 vDSP FFT，24 段对数频率 40Hz–16kHz，归一化并做衰减平滑。

- [ ] **Step 3: 接入主题**

`ThemeEnvironment` 提供 `ThemeTokens` 与背景渐变；主窗口/迷你窗/歌词窗/播放条全部从 tokens 取强调色；系统外观用 `@Environment(\.colorScheme)` 与设置里的 mode；自定义强调色用 `ColorPicker`，文字色由 `AccentContrast` 计算。

- [ ] **Step 4: 接入频谱**

迷你条内嵌 24 段频谱（默认开）；主窗口播放条底部淡波受 `showMainSpectrum` 控制；歌词窗不加。`PlayerEngine.spectrum` 驱动 `MiniPlayerView`。

- [ ] **Step 5: 手工验收**

Expected: 设置里六套皮肤切换即时生效；跟随系统切换明暗；自定义强调色后按钮文字对比度正常；播放时迷你条频谱跳动，暂停后衰减到静止。设置页同时显示缺失文件、无法读取文件、转码缓存占用，并可清理缓存与标签撤销记录。

- [ ] **Step 6: 提交**

```bash
git add Sources Tests
git commit -m "feat: add theme presets, custom accent and spectrum visualizer"
```

---

### Task 15: 通用二进制打包、README 与整体验收

**Files:**
- Modify: `Scripts/build-app.sh`
- Modify: `Package.swift`（如有必要）
- Create: `README.md`
- Create: `docs/acceptance-checklist.md`

**Interfaces:**
- Consumes: 全部前置任务。
- Produces: `build/声屿.app` 同时含 `x86_64` 与 `arm64`；README 说明构建、依赖、许可证、已知限制。

- [ ] **Step 1: 通用二进制构建**

`Scripts/build-app.sh --universal`：分别用 `swift build -c release --arch x86_64 --scratch-path .build/x86_64` 与 `--arch arm64 --scratch-path .build/arm64` 构建，用 `lipo -create` 合并，`lipo -archs` 输出必须包含 `x86_64 arm64`；再次 ad-hoc 签名。

- [ ] **Step 2: 写 README 与许可证说明**

README 包含：项目简介、截图占位、构建命令、`brew install ffmpeg` 依赖说明、数据目录、TagLib (LGPL-2.1/MPL-1.1) 与 FFmpeg 许可说明、已知限制（不打包 ffmpeg、不做实时文件夹监听、不做在线音乐）。生成一个简洁占位应用图标（`Resources/AppIcon.icns`，深蓝底 + 白色音符），构建脚本复制进 bundle。

- [ ] **Step 3: 整体验收**

逐项执行并记录到 `docs/acceptance-checklist.md`：
1. 导入 `~/Music` 与 `红歌`，曲目数与标题/歌手正确。
2. 播放 mp3、flac、m4a、wav 正常；ape/dsf 转码后可播。
3. 搜索、排序、播放列表、重启恢复、播放位置恢复（不自动播放）。
4. 菜单栏、媒体键、迷你窗、关闭主窗口继续播放。
5. 歌词：同名 `.lrc` 优先、在线匹配、手动导入、锁定穿透、菜单栏解锁、缩放字号跟随、跨桌面/全屏、录屏隐藏。
6. 标签：改单曲、批量改、乱码修复、撤销。
7. 整理：预览、移动、冲突编号、撤销。
8. 主题：六套切换、跟随系统、自定义强调色。
9. 性能：空闲 CPU < 1%、播放 < 3%、内存 < 150MB（活动监视器记录）。
10. 杀进程后重启，播放列表与设置不丢失；手工写坏 `library.json` 后播放列表仍在。

- [ ] **Step 4: 提交与打标签**

```bash
git add README.md Scripts docs/acceptance-checklist.md
git commit -m "chore: add universal build, README and acceptance checklist"
git tag v0.1.0
```

---

## Self-Review

- **Spec coverage:** 导入/扫描/坏文件（T2）、索引/缺失文件/封面缓存（T3）、列表与播放列表/最近添加/模式（T3/T6）、播放与媒体键/快捷键（T4/T7）、歌词三级来源与悬浮窗/单双行/描边（T8/T9）、迷你与菜单栏（T7）、皮肤与频谱（T14）、标签编辑/乱码/撤销/封面禁用（T10/T11）、整理/跨盘移动（T12）、转码与非原生时长（T13）、打包/图标/验收（T15）。
- **Review Focus 对应：** 文件名解析（T2）、索引损坏（T3）、锁定歌词逃生（T8 手工）、文件安全（T11/T12）、ffmpeg 缺失（T13）。
- **命名一致性：** `Track`、`Playlist`、`TagFields`、`TagUndoEntry`、`OrganizePlanItem`、`TranscodeQueue`、`ThemeTokens` 在各任务中同名同字段。
