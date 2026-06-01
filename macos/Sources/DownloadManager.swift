import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class DownloadManager: ObservableObject {
    @Published var items: [DownloadItem] = []
    @Published var urlHistory: [String] = []

    private let maxConcurrent = 2
    private let maxHistory = 10
    let outputDir: URL
    private let configURL: URL

    init() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        self.outputDir = downloads.appendingPathComponent("yt-grab")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let configDir = appSupport.appendingPathComponent("yt-grab")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        self.configURL = configDir.appendingPathComponent("config.json")

        loadConfig()
        requestNotificationPermission()
    }

    // MARK: - Public

    func add(url: String, format: DownloadFormat) {
        let item = DownloadItem(url: url, format: format)
        items.insert(item, at: 0)
        addToHistory(url)
        persistQueue()
        processQueue()
    }

    func cancel(item: DownloadItem) {
        item.process?.terminate()
        item.process = nil
        item.status = .cancelled
        persistQueue()
        processQueue()
    }

    func remove(item: DownloadItem) {
        guard item.isFinished else { return }
        items.removeAll { $0.id == item.id }
    }

    func removeCompleted(at indices: IndexSet) {
        let toRemove = indices.filter { items[$0].isFinished }
        items.remove(atOffsets: IndexSet(toRemove))
    }

    func moveItem(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    func clearCompleted() {
        items.removeAll { $0.isFinished }
    }

    // MARK: - Global progress (for Dock badge)

    var globalProgress: Double {
        let active = items.filter { $0.isActive }
        guard !active.isEmpty else { return 0 }
        return active.reduce(0.0) { $0 + $1.progress } / Double(active.count)
    }

    // MARK: - Queue processing

    private func processQueue() {
        let activeCount = items.filter { $0.isActive }.count
        let slotsAvailable = maxConcurrent - activeCount

        guard slotsAvailable > 0 else { return }

        let queued = items.filter {
            if case .queued = $0.status { return true }
            return false
        }

        for item in queued.prefix(slotsAvailable) {
            startDownload(item: item)
        }

        updateDockProgress()
    }

    // MARK: - Download execution

    private func startDownload(item: DownloadItem) {
        item.status = .fetching

        Task {
            // Step 1: fetch metadata
            let metadata = await fetchMetadata(url: item.url)
            if let meta = metadata {
                item.title = meta.title
                item.thumbnailURL = meta.thumbnail
                // Load thumbnail image
                if let thumbURL = meta.thumbnail, let url = URL(string: thumbURL) {
                    await loadThumbnail(for: item, from: url)
                }
            }

            // Step 2: download
            await runDownload(item: item)

            // Step 3: notify + persist
            if case .completed = item.status {
                sendNotification(title: item.title, format: item.format)
            }
            persistQueue()
            updateDockProgress()
        }
    }

    private func loadThumbnail(for item: DownloadItem, from url: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = NSImage(data: data) {
                item.thumbnailImage = image
            }
        } catch {}
    }

    private func fetchMetadata(url: String) async -> VideoMetadata? {
        guard let ytdlp = ToolManager.shared.resolvedYtDlpPath else { return nil }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.arguments = ["--dump-json", "--no-download", url]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let title = json["title"] as? String ?? "Unknown"
            let thumbnail = json["thumbnail"] as? String
            return VideoMetadata(title: title, thumbnail: thumbnail)
        } catch {
            return nil
        }
    }

    private func runDownload(item: DownloadItem) async {
        guard let ytdlp = ToolManager.shared.resolvedYtDlpPath else {
            item.status = .failed(error: "yt-dlp not found. Restart the app to download it.")
            processQueue()
            return
        }

        let process = Process()
        let pipe = Pipe()

        var args = item.format.ytDlpArgs
        args += ["--newline", "--progress"]

        // Point yt-dlp to our bundled ffmpeg
        if let ffmpegPath = ToolManager.shared.resolvedFfmpegPath {
            let ffmpegDir = URL(fileURLWithPath: ffmpegPath).deletingLastPathComponent().path
            args += ["--ffmpeg-location", ffmpegDir]
        }

        // Embed metadata + thumbnail for audio
        if item.format != .mp4 {
            args += ["--embed-metadata", "--embed-thumbnail"]
        }

        let outputTemplate = outputDir.appendingPathComponent("%(title)s.%(ext)s").path
        args += ["-o", outputTemplate]
        args += [item.url]

        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        process.currentDirectoryURL = outputDir

        item.process = process
        item.status = .downloading(progress: 0, speed: "")

        do {
            try process.run()
        } catch {
            item.status = .failed(error: error.localizedDescription)
            processQueue()
            return
        }

        // Read output line by line for progress
        let handle = pipe.fileHandleForReading

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task.detached { [weak item] in
                var buffer = Data()
                var lastOutputFile: String?

                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)

                    while let newlineRange = buffer.range(of: Data("\n".utf8)) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                        buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

                        if let line = String(data: lineData, encoding: .utf8) {
                            // Check for destination line
                            if line.contains("[Merger]") || line.contains("[ExtractAudio]") || line.contains("[download] Destination:") {
                                if let path = Self.parseOutputPath(line) {
                                    lastOutputFile = path
                                }
                            }

                            let parsed = Self.parseProgress(line)
                            if let parsed {
                                await MainActor.run {
                                    guard let item else { return }
                                    item.status = .downloading(
                                        progress: parsed.progress,
                                        speed: parsed.speed
                                    )
                                }
                            }
                        }
                    }
                }

                process.waitUntilExit()

                await MainActor.run { [weak item] in
                    guard let item else {
                        continuation.resume()
                        return
                    }
                    if process.terminationStatus == 0 {
                        item.outputFilePath = lastOutputFile
                        item.status = .completed(path: lastOutputFile ?? item.title)
                    } else if case .cancelled = item.status {
                        // already cancelled
                    } else {
                        item.status = .failed(error: "yt-dlp exited with code \(process.terminationStatus)")
                    }
                    continuation.resume()
                }
            }
        }

        item.process = nil
        processQueue()
    }

    // MARK: - Progress parsing

    private struct ProgressInfo: Sendable {
        let progress: Double
        let speed: String
    }

    private nonisolated static func parseProgress(_ line: String) -> ProgressInfo? {
        guard line.contains("%") else { return nil }

        var progress: Double = 0
        var speed: String = ""

        if let percentRange = line.range(of: #"\d+\.?\d*%"#, options: .regularExpression) {
            let percentStr = line[percentRange].dropLast()
            progress = (Double(percentStr) ?? 0) / 100.0
        }

        if let speedRange = line.range(of: #"at\s+[\d.]+\w+/s"#, options: .regularExpression) {
            speed = String(line[speedRange]).replacingOccurrences(of: "at ", with: "")
        }

        guard progress > 0 else { return nil }
        return ProgressInfo(progress: progress, speed: speed)
    }

    private nonisolated static func parseOutputPath(_ line: String) -> String? {
        // Lines like: [download] Destination: /path/to/file.mp3
        // or: [ExtractAudio] Destination: /path/to/file.mp3
        if let range = line.range(of: "Destination: ") {
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: - Dock progress

    private func updateDockProgress() {
        let active = items.filter { $0.isActive }
        if active.isEmpty {
            NSApp.dockTile.badgeLabel = nil
            // Reset dock progress
            NSApp.dockTile.contentView = nil
            NSApp.dockTile.display()
        } else {
            let percent = Int(globalProgress * 100)
            NSApp.dockTile.badgeLabel = "\(percent)%"
            NSApp.dockTile.display()
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        // UNUserNotificationCenter requires a proper app bundle; skip if not bundled
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private nonisolated func sendNotification(title: String, format: DownloadFormat) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Download complete"
        content.body = "\(title) (\(format.label))"
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - History

    private func addToHistory(_ url: String) {
        urlHistory.removeAll { $0 == url }
        urlHistory.insert(url, at: 0)
        if urlHistory.count > maxHistory {
            urlHistory = Array(urlHistory.prefix(maxHistory))
        }
        saveConfig()
    }

    // MARK: - Persistence

    private func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let history = json["history"] as? [String] {
            urlHistory = history
        }
        // Restore queued items from last session
        if let queue = json["queue"] as? [[String: String]] {
            for entry in queue {
                guard let url = entry["url"], let formatRaw = entry["format"],
                      let format = DownloadFormat(rawValue: formatRaw) else { continue }
                let item = DownloadItem(url: url, format: format)
                if let title = entry["title"], !title.isEmpty {
                    item.title = title
                }
                items.append(item)
            }
            // Auto-resume restored items
            if !items.isEmpty {
                processQueue()
            }
        }
    }

    private func saveConfig() {
        // Persist history + pending queue items (queued/downloading but not finished)
        let pendingItems = items.filter { !$0.isFinished }.map { item in
            ["url": item.url, "format": item.format.rawValue, "title": item.title]
        }
        let json: [String: Any] = ["history": urlHistory, "queue": pendingItems]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? data.write(to: configURL)
    }

    /// Save queue state periodically (called on add/cancel/complete)
    func persistQueue() {
        saveConfig()
    }
}

struct VideoMetadata {
    let title: String
    let thumbnail: String?
}
