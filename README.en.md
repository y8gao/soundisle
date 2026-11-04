# SoundIsle

A native macOS player for your local music library: recursive folder scanning, playlists and search, menu-bar/media-key/mini-player control, desktop lyrics, tag editing with mojibake repair, template-based file organizing, background transcoding for non-native formats, six themes, and a live spectrum.

> Screenshot placeholder: `docs/screenshots/main.png` (not included yet).

Chinese README: [README.md](README.md).

## Requirements

- macOS 12.0 or later (Intel and Apple Silicon).
- Xcode Command Line Tools (Swift 5.8+); building TagLib also needs `cmake` and `git`.
- Optional: `ffmpeg`, only for formats AVFoundation cannot decode.

## Build

```bash
# 1. Build static TagLib (first run or when Vendor/taglib is missing; safe to re-run)
bash Scripts/build-taglib.sh

# 2. Run unit tests
swift test

# 3. Build build/声屿.app as a universal binary (x86_64 + arm64)
bash Scripts/build-app.sh --universal

# Build only for the current machine's architecture
bash Scripts/build-app.sh
```

`--universal` builds both architectures in separate scratch paths, merges them with `lipo -create`, and verifies both slices with `lipo -archs`. The bundle is ad-hoc signed.

Output: `build/声屿.app` (the display name follows the system language; it is **SoundIsle** in English).

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| `Space` | Play / pause (main window, not while typing) |
| `⌘←` / `⌘→` | Previous / next track |
| `←` / `→` | Seek back / forward 5 seconds |
| `⌘F` | Focus search |
| `⌘,` | Open Settings |

The mini player is a non-activating panel so it does not steal focus; use its buttons or the system media keys while another app is active.

## Localization

- Follows the system language by default.
- Settings → Appearance → Language can override it to 中文 or English. Changing the language requires restarting SoundIsle.
- The English display name is **SoundIsle**; the Chinese name is **声屿**.
- Music metadata and user content are shown as stored and are never translated.

## Dependencies

- **TagLib 1.13.1**: downloaded and built as a static library by `Scripts/build-taglib.sh`; linked into the app, no dynamic TagLib is shipped.
- **FFmpeg**: external command-line tool, not bundled. It is only needed for `ape/wma/ogg/opus/wv/tta/dsf/dff` and similar non-native formats; mp3/m4a/m4r/aac/wav/aiff/flac/mp4/alac do not need it.
  - Recommended install: `brew install ffmpeg`.
  - Lookup order: custom path in Settings → `/usr/local/bin`, `/opt/homebrew/bin` → current `PATH`.
  - Choose the `ffmpeg` executable in Settings → Cache → FFmpeg path. A sibling `ffprobe` is used for non-native durations.
  - Apps launched from Finder usually do not inherit the shell `PATH`; a Homebrew install or an explicit path is the most reliable choice.

## Data directory

```
~/Library/Application Support/SoundIsle/
├── library.json       # library index (with .bak backup)
├── playlists.json     # playlists
├── settings.json      # settings and last playback position
├── covers/            # artwork cache
├── lyrics/            # online lyrics cache and manual overrides
├── transcode/         # ALAC transcode cache
└── undo/              # tag-edit and organizer undo records
```

If `library.json` is corrupt, the app falls back to `.bak`. Playlists and settings live in separate files and survive an index rebuild. The transcode cache can be cleared in Settings without touching the original audio files.

## Licenses

- **TagLib**: GNU LGPL-2.1 or MPL-1.1 (see upstream). Linked statically; source and build script are in the TagLib repository and `Scripts/build-taglib.sh`.
- **FFmpeg**: the license depends on the build. Common `--enable-gpl` static builds (for example evermeet.cx) are GPL; other builds may be LGPL. FFmpeg is not distributed with this app; install it yourself and follow its license.
- This project's own source declares no additional license.

## Known limitations

- FFmpeg is not bundled. Non-native formats cannot play without it; native formats are unaffected.
- No live folder watching; use “Rescan” after changing files outside the app.
- No streaming or online music. Online lyrics use LRCLIB by default; a compatible custom lyrics endpoint (including one that returns direct LRC text) can be configured in Settings.
- Copy mode for the organizer creates a second copy at the destination; a later rescan of the source folder can show duplicate entries.
- WAV files without an existing ID3v2 chunk are read-only (TagLib 1.13 cannot create one).
- WMA/ASF album-artist and artwork fields are read-only.
- Media keys and the Now Playing panel only reach SoundIsle while it is the system Now Playing app; otherwise macOS may route them to another player such as Apple Music.
- The app is ad-hoc signed and not notarized. On first launch you may need to right-click → Open, or run `xattr -dr com.apple.quarantine build/声屿.app`. Rebuilding can reset system permission records.
- The app does not record microphone input and installs no input node or input tap; `Info.plist` does not declare `NSMicrophoneUsageDescription`. If macOS still asks for microphone access, denying it does not affect playback.
- The lyrics overlay and mini player are hidden from screen recording/screenshots by default; this can be disabled in Settings.
