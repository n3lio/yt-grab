import SwiftUI

struct DownloadItemRow: View {
    @ObservedObject var item: DownloadItem
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            thumbnailView

            // Format badge
            formatBadge

            // Title + status
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                statusView
            }

            Spacer()

            // Action button
            actionButton
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            openFile()
        }
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnailView: some View {
        if let image = item.thumbnailImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 48, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 48, height: 36)
                .overlay {
                    Image(systemName: "play.rectangle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
        }
    }

    // MARK: - Format badge

    private var formatBadge: some View {
        Text(item.format.label)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badgeColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
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
            Text("Queued")
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
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                HStack {
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if !speed.isEmpty {
                        Text("• \(speed)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

        case .completed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Done — double-click to reveal")
                    .font(.caption)
                    .foregroundStyle(.green)
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
        switch item.status {
        case .downloading, .fetching:
            Button(action: onCancel) {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Cancel download")

        case .completed:
            Button(action: openFile) {
                Image(systemName: "folder")
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")

        default:
            EmptyView()
        }
    }

    private func openFile() {
        guard case .completed = item.status else { return }

        if let filePath = item.outputFilePath,
           FileManager.default.fileExists(atPath: filePath) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
        } else {
            // Fallback: open the output directory
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let ytGrabDir = downloads.appendingPathComponent("yt-grab")
            NSWorkspace.shared.open(ytGrabDir)
        }
    }
}
