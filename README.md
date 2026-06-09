# yt-grab

Download YouTube videos and music in one click. No terminal, no manual setup.

Available for **Windows** and **macOS**.

---

## Download

Go to the [**Releases**](https://github.com/n3lio/yt-grab/releases/latest) page and grab the file for your OS:

| Platform | File to download | Requirements |
|----------|-----------------|--------------|
| **Windows** | `yt-grab-X.X.X-setup.exe` | Windows 10 or 11 |
| **macOS** | `yt-grab-X.X.X.dmg` | macOS 14 (Sonoma) or later |

> **yt-dlp** and **ffmpeg** are downloaded automatically on first launch. Nothing to install manually.

> **Note:** Windows may show a SmartScreen warning ("Unknown publisher"). This is normal for indie software — click **More info** → **Run anyway**. On macOS, right-click → Open the first time.

---

## Installation

### Windows
1. Download `yt-grab-X.X.X-setup.exe` from Releases
2. Double-click, follow the installer (under 30 seconds)
3. Launch **YouTube Grabber** from the Desktop or Start Menu

### macOS
1. Download `yt-grab-X.X.X.dmg` from Releases
2. Open the DMG, drag **yt-grab** to Applications
3. Launch from Applications (right-click > Open the first time)

---

## Usage

1. Paste a YouTube URL (or drag & drop from your browser)
2. Pick a format: **MP3** (320k), **WAV** (lossless) or **MP4** (best quality)
3. Press **Enter** or click **+**
4. Done — files land in your Downloads folder

Queue multiple URLs — they process in order with real-time progress and speed.

---

## Features

- Multi-item queue with thumbnails, progress bar and speed
- Auto-preview (title + thumbnail) when you add a URL
- Last 10 URLs history
- Drag & drop from the browser
- Queue reordering
- Auto-resume if the app crashes (queue persisted to disk)
- One-click yt-dlp update from within the app
- Auto-update: notified when a new version is available
- System notification when downloads complete
- Metadata + cover art embedded in audio files

---

## Stack

| | Windows | macOS |
|---|---------|-------|
| **Language** | PowerShell 5.1 + WPF | Swift + SwiftUI |
| **Packaging** | ps2exe (.exe) + Inno Setup | .app bundle + DMG |
| **CI/CD** | GitHub Actions | GitHub Actions |
| **Min OS** | Windows 10 | macOS 14 (Sonoma) |

---

## Development

```
yt-grab/
├── windows/          # Windows version (PowerShell/WPF)
│   ├── yt-grab.ps1   # Main app (~2300 lines)
│   └── installer.iss  # Inno Setup script
├── macos/            # macOS version (SwiftUI)
│   ├── Sources/       # Swift source files
│   └── scripts/       # Build scripts
└── .github/workflows/ # CI: release-windows.yml + release-macos.yml
```

### Release process
1. Bump version in `windows/yt-grab.ps1` + `windows/installer.iss` + `macos/Sources/AppUpdater.swift` + `macos/Resources/Info.plist`
2. Commit, tag: `git tag v1.1.0 && git push --tags`
3. GitHub Actions builds both platforms and publishes a single Release with both installers

---

Made by [n3lio](https://github.com/n3lio)
