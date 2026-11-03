# 声屿 SoundIsle 验收清单

- 验收日期：2026-11-03
- 环境：macOS 13.7.8（x86_64）、Swift 5.8.1 / Xcode 14.3.1、FFmpeg 9.0.2（`/Users/gaoyang/bin/ffmpeg`，仅本机验证，未打包）
- 构建产物：`build/声屿.app`（`lipo -archs` = `x86_64 arm64`，ad-hoc 签名）
- 测试数据：`~/Music`（117 首，含 `红歌` 30 首）为只读导入；标签/整理/转码使用 `/tmp/si-accept` 下的副本；验收后已恢复 `~/Library/Application Support/SoundIsle/` 原始数据。

## 构建与测试

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| `bash Scripts/build-taglib.sh` | 通过 | 输出 `TagLib 静态库已安装（x86_64 arm64）` |
| `swift test` | 通过 | `Executed 199 tests, with 2 tests skipped and 0 failures` |
| `bash Scripts/build-app.sh --universal` | 通过 | 两次 `swift build` 后 `lipo -create`；输出 `架构: x86_64 arm64` |
| 通用二进制 | 通过 | `lipo -archs build/声屿.app/Contents/MacOS/SoundIsle` → `x86_64 arm64` |
| 版本与图标 | 通过 | Info.plist `CFBundleShortVersionString=0.1.0`、`CFBundleVersion=1`、`CFBundleIconFile=AppIcon`；`Contents/Resources/AppIcon.icns` 存在（330 KB） |
| 签名 | 通过 | `codesign -dv` → `Signature=adhoc`、`Format=app bundle with Mach-O universal (x86_64 arm64)`；`codesign --verify --deep --strict build/声屿.app` 退出码 0 |

> **最终产物状态（交付前最后一次构建）**：`build/声屿.app` 为通用二进制，`lipo -archs` 输出 `x86_64 arm64`，`codesign --verify --deep --strict` 通过。交付前的最后一步必须是 `bash Scripts/build-app.sh --universal`；普通 `bash Scripts/build-app.sh` 只生成当前机器架构，不能作为最终产物。

## 十项验收

| # | 项目 | 结果 | 证据 |
| --- | --- | --- | --- |
| 1 | 导入 `~/Music` 与 `红歌`，曲目数与标题/歌手正确 | 通过 | 侧栏显示 `Music 117`；`红歌` 为 `~/Music` 子目录，递归扫描得到 30 首；抽查标题/歌手：`为了谁/董文华`、`什么也不说/郁钧剑`、`茶花开了/王睿卓`、`强军战歌.Live./阎维文`，与索引一致 |
| 2 | 播放 mp3、flac、m4a、wav；ape/dsf 转码后可播 | 部分通过 | mp3（伴奏：编花篮）、flac（茶花开了）、m4a（后海酒吧）、wav（天空之城）均显示曲目并进入播放（播放键变为暂停）。无 ape/dsf 样本，未实测；其与非原生 WMA 共用同一条转码路径。WMA 实测见下 |
| 2a | 真实 FFmpeg 转码：首次显示「正在准备…」后播放，重播即时 | 通过 | 清空缓存后播放 8 秒 WMA：截图捕获 `正在准备《test》…`；`transcode/94b5….m4a` 由 FFmpeg 9.0.2 生成，`ffprobe` 显示 `codec_name=alac`、`duration=7.988095`；播放器显示 `test 0:00/0:08` 且为暂停键。重播时在 0.8 秒内进入播放、无准备提示，缓存文件 mtime 未变（未被重新转码） |
| 2b | FFmpeg 缺失时的提示与原生格式回退 | 通过 | 将 `ffmpegPath` 指向不存在的路径并清空缓存后播放 WMA，显示 `需要 FFmpeg 才能播放此格式（《test》）。`，并提供 `复制 brew install ffmpeg / 重新检测 / 选择 FFmpeg… / 原生格式仍可正常播放`；随后播放 mp3 正常（播放键变为暂停）。之后已恢复真实 FFmpeg 路径 |
| 3 | 搜索、排序、播放列表、重启恢复、播放位置恢复（不自动播放） | 通过 | 搜索「茶花」过滤为 2 首；按歌手排序后列表顺序改变；播放列表「工作时听的」显示 2 首；播放到 0:11 暂停后退出重启，播放器恢复 `强军战歌.Live. 0:11` 且保持暂停（播放键为「播放」），播放列表仍为 2 首 |
| 4 | 菜单栏、媒体键、迷你窗、关闭主窗口继续播放 | 通过 | 菜单栏状态项菜单显示当前曲目与「暂停/播放、上一首、下一首」；模拟 `NX_KEYTYPE_PLAY` 使播放/暂停切换，模拟 `NX_KEYTYPE_NEXT` 切到下一首；迷你窗存在（520×66）；关闭主窗口后进程存活、迷你窗仍在、菜单显示「暂停」（继续播放），可从菜单「显示主窗口」恢复 |
| 5 | 歌词：同名 `.lrc` 优先、在线匹配、手动导入、锁定穿透、菜单栏解锁、缩放字号跟随、跨桌面/全屏、录屏隐藏 | 部分通过 | 同名 `.lrc`：`侧车测试.lrc` 的四行歌词直接显示；在线匹配：`茶花开了` 无 sidecar，在线取得拼音歌词并写入 `lyrics/` 缓存；手动导入：选择 `override.lrc` 后显示「手动导入第一行/第二行」，菜单「恢复自动匹配」变为可用，恢复后回到 sidecar；锁定：悬浮窗控制按钮消失、菜单变为「解锁歌词」，从菜单解锁后按钮恢复。录屏隐藏：悬浮窗与迷你窗均在窗口列表中存在，但 `screencapture` 截图中不可见（`sharingType = .none`）。字号跟随窗口宽度由 `LyricsFontTests` 与代码保证，未手工测量；跨桌面/全屏由 `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` 保证，未实际切换 Space 验证 |
| 6 | 标签：改单曲、批量改、乱码修复、撤销 | 部分通过 | 单曲：把临时副本标题改为「验收标题A」，`ffprobe` 读到新标题且列表即时更新；撤销：设置中「撤销最近一次标签编辑」后文件标题标签被移除。乱码写回：对真实乱码文件点击「修复乱码」显示 `修复预览：天空之城`，应用并保存后 `ffprobe` 读到 `title=天空之城`。**曲库显示修复（最终修复轮）**：`TrackFactory` 对标题/歌手/专辑/专辑歌手统一调用 `MojibakeRepair`，`LibraryStore.load()` 一次性修复旧 `library.json`；UTF-8 与 GBK 误码（如 `天空之城`、`阿宝`）无需重扫即可显示为可读中文，`Beyoncé’s` 等真实拉丁文本不误改。新增右键「修复乱码标签…」可在可写格式上预览并写回，同时记录撤销。批量编辑未完成手工操作（UI 多选自动化受限），由 `TagServiceTests`/`TagEditUndoStoreTests` 覆盖。另确认无 ID3v2 的 WAV 显示只读提示 |
| 7 | 整理：预览、移动、冲突编号、撤销 | 通过 | 预览显示源/目标路径；目标目录预置同名文件时显示 `1 个同名冲突已自动编号`、目标为 `标签测试二 (2).mp3`、标记「同名已避让」；执行后源文件消失、目标文件生成；文件菜单「撤销上次整理」后源文件恢复、新建副本删除，状态显示 `已恢复 1 个文件到原位置。` |
| 8 | 主题：六套切换、跟随系统、自定义强调色 | 通过 | 依次点击六套皮肤，`settings.json` 记录 `deepBlue / morning / inkAmber / celadon / berry / seaSalt`，界面同步变色；明暗模式记录 `light / dark / system`；自定义强调色打开系统颜色面板，「恢复默认」后 `customAccentHex` 为空。具体色值换算由 `ThemePaletteTests` 覆盖 |
| 9 | 性能：空闲 CPU < 1%、播放 < 3%、内存 < 150MB | 通过 | 采样工具为 `top -l 4 -s 2 -pid` 与 `ps`，**未使用「活动监视器」**（命令行环境无法驱动其界面）。空闲 0.3–0.4% CPU；播放 mp3 时 1.7–2.0% CPU；`ps` RSS 约 94 MB，`top` 常驻约 48 MB，均低于 150 MB。未开启频谱；开启频谱会增加少量 CPU，未纳入本次门槛 |
| 10 | 杀进程重启后播放列表与设置不丢失；写坏 `library.json` 后播放列表仍在 | 通过 | 正常退出重启后播放列表「工作时听的」2 首、设置与上次曲目/位置均恢复。备份数据目录后，将 `library.json` 与 `library.json.bak` 都写入非法内容再启动：曲库为空，但侧栏仍显示「工作时听的 2」，`playlists.json` 与 `settings.json` 保持完整；测试后已从备份恢复 |

## 未能完全手工验证 / 已知问题

1. **APE/DSF 播放**：没有可用样本，未实测；代码走与 WMA 相同的 `TranscodeQueue` 路径。
2. **批量标签编辑**：多选手势的自动化不稳定，未完成手工批量保存；相关核心逻辑有单元测试覆盖。
3. **歌词字号缩放与跨 Space/全屏**：分别由 `LyricsFontTests` 和窗口 `collectionBehavior` 保证，未做人工视觉/多桌面验证。
4. **媒体键边界**：当声屿不是系统当前 Now Playing 应用时，模拟播放键曾唤起 Apple Music；在声屿正在播放/暂停的会话中，媒体键控制正常。属于系统媒体键路由行为，已在 README 的已知限制中说明。
5. **ad-hoc 签名**：未公证，首次打开可能需要右键「打开」或移除 quarantine 属性。
