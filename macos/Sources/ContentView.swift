import SwiftUI

struct ContentView: View {
    @State private var url: String = ""
    @State private var selectedFormat: DownloadFormat = .mp3
    @State private var showHistory: Bool = false
    @State private var showUpdateAlert: Bool = false
    @StateObject private var downloadManager = DownloadManager()
    @StateObject private var toolManager = ToolManager.shared
    @StateObject private var appUpdater = AppUpdater.shared
    @FocusState private var urlFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if toolManager.isSettingUp || !toolManager.isReady {
                setupView
            } else {
                headerView
                Divider()
                if downloadManager.items.isEmpty {
                    emptyState
                } else {
                    queueList
                }
                Divider()
                footerView
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.text, .url], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
        .task {
            await toolManager.ensureTools()
            await toolManager.checkForYtDlpUpdate()
            await appUpdater.checkForUpdate()
            urlFieldFocused = true
        }
        .alert("Update available", isPresented: $showUpdateAlert) {
            Button("Download & Install") {
                Task { await appUpdater.downloadAndInstall() }
            }
            Button("Later", role: .cancel) {}
        } message: {
            if let update = appUpdater.updateAvailable {
                Text("yt-grab v\(update.version) is available. You have v1.0.0.")
            }
        }
        .onChange(of: appUpdater.updateAvailable != nil) { _, hasUpdate in
            if hasUpdate {
                showUpdateAlert = true
            }
        }
    }

    // MARK: - Setup screen

    private var setupView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("yt-grab")
                .font(.largeTitle.bold())

            if toolManager.setupFailed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.title2)
                    Text(toolManager.setupStatus)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await toolManager.ensureTools() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.regular)
                    Text(toolManager.setupStatus.isEmpty ? "Checking tools..." : toolManager.setupStatus)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("yt-grab")
                    .font(.title2.bold())
                Spacer()

                if let appUpdate = appUpdater.updateAvailable {
                    Button {
                        Task { await appUpdater.downloadAndInstall() }
                    } label: {
                        Label("v\(appUpdate.version) available", systemImage: "arrow.down.app.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                }

                if let newVersion = toolManager.updateAvailable {
                    Button {
                        Task { await toolManager.updateYtDlp() }
                    } label: {
                        Label("yt-dlp \(newVersion) available", systemImage: "arrow.up.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }

                if !downloadManager.items.filter({ $0.isFinished }).isEmpty {
                    Button("Clear done") {
                        downloadManager.clearCompleted()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                TextField("Paste a YouTube URL...", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .focused($urlFieldFocused)
                    .onSubmit { addToQueue() }

                // Paste button
                Button {
                    if let clip = clipboardContent() {
                        url = clip
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .help("Paste from clipboard")

                // History button
                if !downloadManager.urlHistory.isEmpty {
                    Menu {
                        ForEach(downloadManager.urlHistory, id: \.self) { historyUrl in
                            Button(historyUrl) {
                                url = historyUrl
                            }
                        }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 30)
                    .help("Recent URLs")
                }

                Picker("", selection: $selectedFormat) {
                    ForEach(DownloadFormat.allCases, id: \.self) { format in
                        Text(format.label).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Button(action: addToQueue) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No downloads yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Paste a YouTube URL or drag & drop one here")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    // MARK: - Queue list

    private var queueList: some View {
        List {
            ForEach(downloadManager.items) { item in
                DownloadItemRow(item: item, onCancel: {
                    downloadManager.cancel(item: item)
                })
            }
            .onMove { source, destination in
                downloadManager.moveItem(from: source, to: destination)
            }
            .onDelete { indices in
                downloadManager.removeCompleted(at: indices)
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Text("yt-dlp \(toolManager.ytDlpVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            // Global progress
            let activeCount = downloadManager.items.filter { $0.isActive }.count
            if activeCount > 0 {
                Text("\(activeCount) active • \(Int(downloadManager.globalProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.blue)
                Spacer()
            }

            Text("~/Downloads/yt-grab/")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private func addToQueue() {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        downloadManager.add(url: trimmed, format: selectedFormat)
        url = ""
    }

    // MARK: - Drag & Drop

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.url") {
                provider.loadItem(forTypeIdentifier: "public.url", options: nil) { item, _ in
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        Task { @MainActor in
                            downloadManager.add(url: url.absoluteString, format: selectedFormat)
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier("public.text") {
                provider.loadItem(forTypeIdentifier: "public.text", options: nil) { item, _ in
                    if let text = item as? String {
                        Task { @MainActor in
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.contains("youtube.com") || trimmed.contains("youtu.be") {
                                downloadManager.add(url: trimmed, format: selectedFormat)
                            }
                        }
                    }
                }
            }
        }
    }
}
