import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            // Logo
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.red)
                    .frame(width: 64, height: 64)

                Image(systemName: "play.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
            }

            // App info
            Text("YouTube Grabber")
                .font(.title.bold())

            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                .font(.subheadline)
                .foregroundStyle(.blue)

            Text("by n3lio")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.horizontal, 40)

            Text("Powered by yt-dlp + ffmpeg")
                .font(.caption)
                .foregroundStyle(.secondary)

            Link("github.com/n3lio/yt-grab", destination: URL(string: "https://github.com/n3lio/yt-grab")!)
                .font(.caption)

            Spacer()

            Button("Close") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(30)
        .frame(width: 350, height: 400)
    }
}
