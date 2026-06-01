import Foundation

/// Manages yt-dlp and ffmpeg binaries bundled inside the app's support directory.
/// Auto-downloads on first launch, provides manual update for yt-dlp.
@MainActor
final class ToolManager: ObservableObject {
    static let shared = ToolManager()

    @Published var ytDlpPath: String?
    @Published var ffmpegPath: String?
    @Published var isSettingUp = false
    @Published var setupStatus: String = ""
    @Published var setupFailed = false
    @Published var ytDlpVersion: String = ""
    @Published var updateAvailable: String?

    private let toolsDir: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.toolsDir = appSupport.appendingPathComponent("yt-grab")
        try? FileManager.default.createDirectory(at: toolsDir, withIntermediateDirectories: true)

        // Check if already downloaded
        let ytdlp = toolsDir.appendingPathComponent("yt-dlp").path
        let ffmpeg = toolsDir.appendingPathComponent("ffmpeg").path

        if FileManager.default.fileExists(atPath: ytdlp) {
            self.ytDlpPath = ytdlp
        }
        if FileManager.default.fileExists(atPath: ffmpeg) {
            self.ffmpegPath = ffmpeg
        }
    }

    /// Also check common system paths (Homebrew, etc.)
    var resolvedYtDlpPath: String? {
        if let p = ytDlpPath { return p }
        let candidates = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    var resolvedFfmpegPath: String? {
        if let p = ffmpegPath { return p }
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    var isReady: Bool {
        return resolvedYtDlpPath != nil && resolvedFfmpegPath != nil
    }

    // MARK: - Setup (first launch)

    func ensureTools() async {
        guard !isReady else {
            await fetchYtDlpVersion()
            return
        }
        isSettingUp = true
        setupFailed = false

        if resolvedYtDlpPath == nil {
            setupStatus = "Downloading yt-dlp..."
            let ok = await downloadYtDlp()
            if !ok {
                setupStatus = "Failed to download yt-dlp. Check your internet connection."
                setupFailed = true
                isSettingUp = false
                return
            }
        }

        if resolvedFfmpegPath == nil {
            setupStatus = "Downloading ffmpeg..."
            let ok = await downloadFfmpeg()
            if !ok {
                setupStatus = "Failed to download ffmpeg. Check your internet connection."
                setupFailed = true
                isSettingUp = false
                return
            }
        }

        await fetchYtDlpVersion()
        isSettingUp = false
        setupStatus = ""
    }

    // MARK: - Download yt-dlp

    private func downloadYtDlp() async -> Bool {
        let dest = toolsDir.appendingPathComponent("yt-dlp")
        guard let url = await getYtDlpDownloadURL() else { return false }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return false }
            try data.write(to: dest)
            // Make executable
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            ytDlpPath = dest.path
            return true
        } catch {
            return false
        }
    }

    private func getYtDlpDownloadURL() async -> URL? {
        // Fetch latest release from GitHub API
        guard let apiURL = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest") else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: apiURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = json["assets"] as? [[String: Any]] else { return nil }

            // Find the macOS universal binary: yt-dlp_macos
            let binaryName = "yt-dlp_macos"
            guard let asset = assets.first(where: { ($0["name"] as? String) == binaryName }),
                  let downloadUrl = asset["browser_download_url"] as? String,
                  let url = URL(string: downloadUrl) else { return nil }

            // Store the tag for version display
            if let tag = json["tag_name"] as? String {
                ytDlpVersion = tag
            }
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Download ffmpeg

    private func downloadFfmpeg() async -> Bool {
        let dest = toolsDir.appendingPathComponent("ffmpeg")

        // Use the evermeet.cx builds (trusted macOS ffmpeg static binaries)
        // Alternative: use the yt-dlp bundled ffmpeg from GitHub
        guard let url = URL(string: "https://evermeet.cx/ffmpeg/getrelease/zip") else { return false }

        do {
            let (zipData, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return false }

            // Write zip to temp
            let tempZip = toolsDir.appendingPathComponent("ffmpeg.zip")
            try zipData.write(to: tempZip)

            // Unzip using /usr/bin/ditto (available on all macOS)
            let tempExtract = toolsDir.appendingPathComponent("ffmpeg-extract")
            try? FileManager.default.removeItem(at: tempExtract)
            try FileManager.default.createDirectory(at: tempExtract, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-xk", tempZip.path, tempExtract.path]
            try process.run()
            process.waitUntilExit()

            // Find the ffmpeg binary in extracted content
            let extractedBinary = tempExtract.appendingPathComponent("ffmpeg")
            if FileManager.default.fileExists(atPath: extractedBinary.path) {
                try FileManager.default.moveItem(at: extractedBinary, to: dest)
            } else {
                // Look recursively
                let enumerator = FileManager.default.enumerator(at: tempExtract, includingPropertiesForKeys: nil)
                var found = false
                while let fileURL = enumerator?.nextObject() as? URL {
                    if fileURL.lastPathComponent == "ffmpeg" {
                        try FileManager.default.moveItem(at: fileURL, to: dest)
                        found = true
                        break
                    }
                }
                if !found { return false }
            }

            // Make executable
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)

            // Cleanup
            try? FileManager.default.removeItem(at: tempZip)
            try? FileManager.default.removeItem(at: tempExtract)

            ffmpegPath = dest.path
            return true
        } catch {
            return false
        }
    }

    // MARK: - Update yt-dlp

    func updateYtDlp() async -> Bool {
        setupStatus = "Updating yt-dlp..."
        let dest = toolsDir.appendingPathComponent("yt-dlp")

        // Remove old binary
        try? FileManager.default.removeItem(at: dest)

        let success = await downloadYtDlp()
        setupStatus = ""
        updateAvailable = nil
        return success
    }

    func checkForYtDlpUpdate() async {
        guard let apiURL = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: apiURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let latestTag = json["tag_name"] as? String else { return }
            if latestTag != ytDlpVersion && !ytDlpVersion.isEmpty {
                updateAvailable = latestTag
            }
        } catch {}
    }

    private func fetchYtDlpVersion() async {
        guard let path = resolvedYtDlpPath else { return }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                ytDlpVersion = version
            }
        } catch {}
    }
}
