# 声屿 SoundIsle

一个面向本地音乐库的 macOS 播放器：递归扫描文件夹、播放列表与搜索、菜单栏/媒体键/迷你窗、桌面歌词、标签编辑与乱码修复、按模板整理文件、非原生格式后台转码，以及六套主题与频谱。

> 截图占位：`docs/screenshots/main.png`（尚未提供）。

## 环境要求

- macOS 12.0 或更高版本（Intel 与 Apple Silicon 均可）。
- Xcode Command Line Tools（Swift 5.8+）；构建 TagLib 还需要 `cmake` 与 `git`。
- 可选：`ffmpeg`，仅用于播放/转码 AVFoundation 不支持的格式。

## 构建

```bash
# 1. 构建静态 TagLib（首次或 Vendor/taglib 缺失时；脚本可重复执行）
bash Scripts/build-taglib.sh

# 2. 运行单元测试
swift test

# 3. 生成 build/声屿.app（同时包含 x86_64 与 arm64）
bash Scripts/build-app.sh --universal

# 仅构建当前机器架构
bash Scripts/build-app.sh
```

`--universal` 会分别用 `.build/x86_64` 与 `.build/arm64` 两个 scratch 路径构建，再用 `lipo -create` 合并，并检查 `lipo -archs` 同时包含两种架构。`Scripts/build-taglib.sh` 同样会生成通用静态库；如果只安装了单架构 TagLib，通用构建会提示先运行该脚本。构建完成后应用会做 ad-hoc 签名。

产物：`build/声屿.app`。

## 依赖说明

- **TagLib 1.13.1**：由 `Scripts/build-taglib.sh` 下载并编译为静态库，链接进应用，不随包分发动态库。
- **FFmpeg**：外部命令行工具，不打包进应用。只有 `ape/wma/ogg/opus/wv/tta/dsf/dff` 等非原生格式需要它；mp3/m4a/m4r/aac/wav/aiff/flac/mp4/alac 不依赖 FFmpeg。
  - 推荐安装：`brew install ffmpeg`。
  - 应用会依次查找：设置中的自定义路径 → `/usr/local/bin`、`/opt/homebrew/bin` → 当前 `PATH`。
  - 在「设置 → 缓存 → FFmpeg 路径」可手动选择 `ffmpeg` 可执行文件；同目录下的 `ffprobe` 用于读取非原生格式时长。
  - 从 Finder 启动时应用通常拿不到 shell 的 `PATH`，因此 Homebrew 或自定义路径最可靠。

## 数据目录

应用数据保存在：

```
~/Library/Application Support/SoundIsle/
├── library.json       # 曲库索引（含 .bak 备份）
├── playlists.json     # 播放列表
├── settings.json      # 设置与上次播放位置
├── covers/            # 封面缓存
├── lyrics/            # 在线歌词缓存与手动覆盖
├── transcode/         # 非原生格式转码缓存（ALAC）
└── undo/              # 标签编辑与整理撤销记录
```

`library.json` 损坏时应用会回退到 `.bak`；即使索引完全不可读，播放列表与设置仍保存在各自文件中。转码缓存可在设置中清理，不会删除原始音乐文件。

## 许可说明

- **TagLib**：GNU LGPL-2.1 或 MPL-1.1（以 TagLib 上游为准）。本项目以静态库方式链接，源码与构建脚本见 TagLib 官方仓库及 `Scripts/build-taglib.sh`。
- **FFmpeg**：许可证取决于具体构建。常见的 `--enable-gpl` 静态构建（如 evermeet.cx）为 GPL；其他构建可能为 LGPL。FFmpeg 未随应用分发，由用户自行安装，请按其构建对应的许可证使用。
- 本项目自身代码未声明额外许可证。

## 已知限制

- 不打包 FFmpeg；缺少 FFmpeg 时非原生格式无法播放，但原生格式不受影响。
- 不做实时文件夹监听：外部增删文件后需要手动「重新扫描」。
- 不做在线音乐/流媒体；在线歌词仅通过 LRCLIB 查询。
- 整理文件的「复制」模式会在目标位置新增副本；再次扫描源文件夹时可能出现重复条目。
- 没有 ID3v2 标签块的 WAV 为只读（TagLib 1.13 无法为其新建 ID3v2 块）。
- WMA/ASF 的「专辑歌手」与封面字段为只读。
- 应用使用 ad-hoc 签名，未做公证；首次打开可能需要右键「打开」，或执行 `xattr -dr com.apple.quarantine build/声屿.app`。每次重新构建后系统权限记录可能重置。
- 应用不采集麦克风输入，也没有安装输入节点或输入 tap，`Info.plist` 未声明 `NSMicrophoneUsageDescription`。如果 macOS 仍然弹出麦克风权限请求，选择「不允许」不影响播放。
- 歌词悬浮窗与迷你窗默认在屏幕录制/截图中隐藏；可在设置中关闭该行为。
