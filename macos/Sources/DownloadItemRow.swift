import SwiftUI

struct DownloadItemRow: View {
    @ObservedObject var item: DownloadItem
    let onCancel: () -> Void
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail (16:9)
            thumbnailView

            // Format badge
            formatBadge

            // Title + status
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                statusView
            }

            Spacer()

            // Action button
            actionButton
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            openFile()
        }
    }

    // MARK: - Thumbnail (16:9, bigger)

    @ViewBuilder
    private var thumbnailView: some View {
        if let image = item.thumbnailImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 80, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: 80, height: 45)
                .overlay {
                    Image(systemName: item.isActive ? "waveform" : "play.rectangle")
                        .foregroundStyle(.tertiary)
                        .font(.title3)
                }
        }
    }

    // MARK: - Format badge

    private var formatBadge: some View {
        Text(item.format.label)
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(badgeColor, in: RoundedRectangle(cornerRadius: 4))
    }

    private var badgeColor: Color {
        switch item.format {
        case .mp3: return .blue
        case .wav: return .purple
        case .mp4: return .green
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusView: some View {
        switch item.status {
        case .queued:
            Label("Queued", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .fetching:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Fetching info...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .downloading(let progress, let speed):
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
                HStack(spacing: 6) {
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.blue)
                    if !speed.isEmpty {
                        Text(speed)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

        case .completed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Done")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
                Text("— double-click to reveal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

        case .failed(let error):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

        case .cancelled:
            HStack(spacing: 4) {
                Image(systemName: "slash.circle")
                    .foregroundStyle(.orange)
                Text("Cancelled")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Action button

    @ViewBuilder
    private var actionButton: some View {
        HStack(spacing: 6) {
            switch item.status {
            case .downloading, .fetching:
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Cancel download")

            case .completed:
                Button(action: openFile) {
                    Image(systemName: "folder.fill")
                        .font(.title3)
                        .foregroundStyle(.blue.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Show in Finder")

                removeButton

            case .failed, .cancelled:
                removeButton

            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var removeButton: some View {
        if let onRemove {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from list")
        }
    }

    private func openFile() {
        guard case .completed = item.status else { return }

        if let filePath = item.outputFilePath,
           FileManager.default.fileExists(atPath: filePath) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
        } else {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let ytGrabDir = downloads.appendingPathComponent("yt-grab")
            NSWorkspace.shared.open(ytGrabDir)
        }
    }
}
