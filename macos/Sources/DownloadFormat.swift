import Foundation

enum DownloadFormat: String, CaseIterable, Sendable {
    case mp3
    case wav
    case mp4

    var label: String {
        switch self {
        case .mp3: return "MP3"
        case .wav: return "WAV"
        case .mp4: return "MP4"
        }
    }

    var ytDlpArgs: [String] {
        switch self {
        case .mp3:
            return ["--extract-audio", "--audio-format", "mp3", "--audio-quality", "0"]
        case .wav:
            return ["--extract-audio", "--audio-format", "wav"]
        case .mp4:
            return ["-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best"]
        }
    }

    var fileExtension: String {
        return rawValue
    }
}
