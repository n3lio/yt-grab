import Foundation
import SwiftUI

/// Checks GitHub Releases for a newer version of the app and offers to download the DMG.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    @Published var updateAvailable: AppUpdate?
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0

    private let currentVersion = "2.2.5"
    private let githubRepo = "n3lio/yt-grab"

    struct AppUpdate {
        let version: String
        let downloadURL: URL
        let releaseNotes: String
    }

    func checkForUpdate() async {
        guard let url = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest") else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else { return }

            let latestVersion = tagName.replacingOccurrences(of: "v", with: "")

            // Compare versions
            guard isNewer(latestVersion, than: currentVersion) else { return }

            // Find the .dmg asset
            guard let dmgAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
                  let downloadUrl = dmgAsset["browser_download_url"] as? String,
                  let url = URL(string: downloadUrl) else { return }

            let body = json["body"] as? String ?? ""

            updateAvailable = AppUpdate(
                version: latestVersion,
                downloadURL: url,
                releaseNotes: body
            )
        } catch {}
    }

    func downloadAndInstall() async {
        guard let update = updateAvailable else { return }
        isDownloading = true
        downloadProgress = 0

        do {
            let (localURL, _) = try await URLSession.shared.download(from: update.downloadURL)

            // Move to Downloads
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let destURL = downloads.appendingPathComponent("yt-grab-\(update.version).dmg")
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: localURL, to: destURL)

            // Open the DMG
            NSWorkspace.shared.open(destURL)

            isDownloading = false

            // Quit the app so user can install the new version
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApp.terminate(nil)
            }
        } catch {
            isDownloading = false
        }
    }

    // MARK: - Version comparison

    private func isNewer(_ new: String, than current: String) -> Bool {
        let newParts = new.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(newParts.count, currentParts.count) {
            let n = i < newParts.count ? newParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if n > c { return true }
            if n < c { return false }
        }
        return false
    }
}
