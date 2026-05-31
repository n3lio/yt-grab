# YouTube Grabber by n3lio

Download YouTube videos and music in one double-click. No terminal, no manual setup.

## Installation

1. Go to the [**Releases**](https://github.com/n3lio/yt-grab/releases/latest) page
2. Download `yt-grab-X.X.X-setup.exe`
3. Double-click, follow the installer (under 30 seconds)
4. Launch **YouTube Grabber** from the Desktop or Start Menu

> **yt-dlp** and **ffmpeg** are downloaded automatically on first launch. Nothing to install manually.

## Requirements

- Windows 10 or 11

That's it.

## Usage

1. Paste a YouTube URL in the top field (video, playlist, Shorts) — or drag & drop from your browser
2. Pick a format: **MP3** (320k), **WAV** (lossless) or **MP4** (best quality)
3. Options: full playlist, subtitles, metadata + cover art
4. Click **+ Add** or press **Enter**
5. Click **⬇ Download all**

You can queue multiple URLs before starting — the queue processes them in order with real-time progress and speed.

## Features

- Multi-item queue with thumbnail, progress bar and speed indicator
- Auto-preview (title, channel, duration, thumbnail) as soon as you paste a URL
- Last 10 URLs history
- Drag & drop from the browser
- Queue reordering (▲▼)
- Auto-resume if the app crashes
- One-click yt-dlp update from within the app
- Auto-update: notified when a new version is available, downloads and installs in one click
- Windows notification when all downloads are done
- Clean uninstall via Programs and Features

## Stack

PowerShell 5.1 + WPF, compiled to `.exe` via [ps2exe](https://github.com/MScholtes/PS2EXE). Installer built with [Inno Setup 6](https://jrsoftware.org/isinfo.php). Build and release automated via GitHub Actions.
