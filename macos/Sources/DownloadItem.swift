import Foundation
import SwiftUI

enum DownloadStatus: Sendable {
    case queued
    case fetching  // getting metadata
    case downloading(progress: Double, speed: String)
    case completed(path: String)
    case failed(error: String)
    case cancelled
}

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: String
    let format: DownloadFormat
    let addedAt: Date

    @Published var title: String
    @Published var status: DownloadStatus
    @Published var thumbnailURL: String?
    @Published var thumbnailImage: NSImage?
    @Published var outputFilePath: String?

    var process: Process?

    init(url: String, format: DownloadFormat) {
        self.url = url
        self.format = format
        self.addedAt = Date()
        self.title = url
        self.status = .queued
    }

    var isActive: Bool {
        switch status {
        case .fetching, .downloading: return true
        default: return false
        }
    }

    var isFinished: Bool {
        switch status {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    var progress: Double {
        switch status {
        case .downloading(let p, _): return p
        case .completed: return 1.0
        default: return 0
        }
    }
}
