import SwiftUI

struct ContentView: View {
    @State private var url: String = ""
    @State private var selectedFormat: DownloadFormat = .mp3
    @State private var showUpdateAlert: Bool = false
    @State private var isDragTargeted: Bool = false
    @State private var alwaysOnTop: Bool = false
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
        .frame(minWidth: 620, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(dragOverlay)
        .onDrop(of: [.text, .url], isTargeted: $isDragTargeted) { providers in
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
        .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Drag overlay

    @ViewBuilder
    private var dragOverlay: some View {
        if isDragTargeted {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue, lineWidth: 3)
                .background(Color.blue.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(4)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.blue)
                        Text("Drop URL here")
                            .font(.headline)
                            .foregroundStyle(.blue)
                    }
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: isDragTargeted)
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

                // App update badge
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

                // yt-dlp update badge
                if let newVersion = toolManager.updateAvailable {
                    Button {
                        Task { await toolManager.updateYtDlp() }
                    } label: {
                        Label("yt-dlp \(newVersion)", systemImage: "arrow.up.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }

                // Always on top toggle
                Button {
                    alwaysOnTop.toggle()
                    setWindowLevel(alwaysOnTop)
                } label: {
                    Image(systemName: alwaysOnTop ? "pin.fill" : "pin")
                }
                .buttonStyle(.bordered)
                .help(alwaysOnTop ? "Unpin from top" : "Keep on top")

                // Clear completed
                if downloadManager.items.contains(where: { $0.isFinished }) {
                    Button("Clear done") {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            downloadManager.clearCompleted()
                        }
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

                // History
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
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "music.note.list")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)

            Text("No downloads yet")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Label("Paste a YouTube URL above", systemImage: "doc.on.clipboard")
                Label("Drag & drop a URL from your browser", systemImage: "hand.draw")
                Label("Press Enter to add to queue", systemImage: "return")
            }
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
                }, onRemove: {
                    withAnimation {
                        downloadManager.remove(item: item)
                    }
                })
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }
            .onMove { source, destination in
                downloadManager.moveItem(from: source, to: destination)
            }
            .onDelete { indices in
                downloadManager.removeCompleted(at: indices)
            }
        }
        .listStyle(.inset)
        .animation(.easeInOut(duration: 0.25), value: downloadManager.items.count)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 12) {
            Text("yt-dlp \(toolManager.ytDlpVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            // Queue counter
            let total = downloadManager.items.count
            let active = downloadManager.items.filter { $0.isActive }.count
            if total > 0 {
                HStack(spacing: 4) {
                    if active > 0 {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text("\(active) downloading")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("•")
                            .foregroundStyle(.tertiary)
                    }
                    Text("\(total) item\(total == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Output folder link
            Button(action: {
                NSWorkspace.shared.open(downloadManager.outputDir)
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "folder")
                        .font(.caption2)
                    Text("~/Downloads/")
                        .font(.caption)
                }
                .foregroundStyle(.blue)
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func addToQueue() {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            downloadManager.add(url: trimmed, format: selectedFormat)
        }
        url = ""
    }

    private func setWindowLevel(_ onTop: Bool) {
        guard let window = NSApp.windows.first else { return }
        window.level = onTop ? .floating : .normal
    }

    // MARK: - Drag & Drop

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.url") {
                provider.loadItem(forTypeIdentifier: "public.url", options: nil) { item, _ in
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        Task { @MainActor in
                            withAnimation {
                                downloadManager.add(url: url.absoluteString, format: selectedFormat)
                            }
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier("public.text") {
                provider.loadItem(forTypeIdentifier: "public.text", options: nil) { item, _ in
                    if let text = item as? String {
                        Task { @MainActor in
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.contains("youtube.com") || trimmed.contains("youtu.be") {
                                withAnimation {
                                    downloadManager.add(url: trimmed, format: selectedFormat)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
