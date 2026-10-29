import SwiftUI
import UniformTypeIdentifiers

// MARK: - Info

/// Album tags of an audio CD in the inspector. Editable before the rip and afterwards (then written back on request).
struct AudioInfoForm: View {
    let job: Job
    @Binding var showSearch: Bool
    @EnvironmentObject var manager: JobManager
    @ViewState private var loadingEdition = false
    @ViewState private var editionError: String?

    private var editable: Bool {
        switch job.status {
        case .identifying, .waiting: true
        case .success: !manager.retagging.contains(job.id)
        default: false
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Album artist", text: jobBinding(manager, job, \.artist))
                TextField("Album", text: jobBinding(manager, job, \.album))
                TextField("Date", text: infoBinding(\.date), prompt: Text("YYYY-MM-DD"))
                TextField("Original date", text: infoBinding(\.originalDate), prompt: Text("YYYY"))
                TextField("Genre", text: infoBinding(\.genre))
                Toggle("Compilation", isOn: infoBinding(\.compilation))
            } header: {
                InspectorHeader(title: "Album") {
                    if editable { Button("Search…") { showSearch = true }.controlSize(.small) }
                }
            }
            .disabled(!editable)

            Section("Release") {
                TextField("Label", text: infoBinding(\.label))
                TextField("Catalog number", text: infoBinding(\.catalogNumber))
                TextField("Barcode", text: infoBinding(\.barcode), prompt: Text("EAN / UPC"))
                TextField("Country", text: infoBinding(\.country), prompt: Text("Code, e.g. DE"))
                LabeledContent("Disc") {
                    HStack(spacing: 6) {
                        TextField("Disc", value: infoBinding(\.discNumber), format: .number)
                            .labelsHidden().frame(width: 40).multilineTextAlignment(.trailing)
                        Text("of").foregroundStyle(.secondary)
                        TextField("Discs", value: infoBinding(\.discTotal), format: .number)
                            .labelsHidden().frame(width: 40).multilineTextAlignment(.trailing)
                    }
                }
                TextField("Comment", text: infoBinding(\.comment), axis: .vertical).lineLimit(1...3)
            }
            .disabled(!editable)

            let editions = manager.audioCandidates(job.id)
            if !job.musicBrainzReleaseID.isEmpty || editions.count > 1 {
                Section("MusicBrainz") {
                    if editable, editions.count > 1 {
                        Picker("Edition", selection: Binding(
                            get: { job.musicBrainzReleaseID },
                            set: { id in if let release = editions.first(where: { $0.id == id }) { choose(release) } })) {
                            ForEach(editions) { release in
                                Text(release.editionSummary.isEmpty ? release.title : release.editionSummary).tag(release.id)
                            }
                        }
                        .disabled(loadingEdition)
                    }
                    if let url = URL(string: "https://musicbrainz.org/release/\(job.musicBrainzReleaseID)"),
                       !job.musicBrainzReleaseID.isEmpty {
                        Link("Open Release on MusicBrainz", destination: url)
                    }
                    if let editionError { Text(editionError).foregroundStyle(.red) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func choose(_ release: AudioRelease) {
        loadingEdition = true
        editionError = nil
        Task {
            do { try await manager.chooseRelease(job.id, release) } catch { editionError = error.localizedDescription }
            loadingEdition = false
        }
    }

    private func infoBinding<T>(_ keyPath: WritableKeyPath<AudioAlbumInfo, T>) -> Binding<T> {
        let snapshot = job
        return Binding(
            get: { (manager.job(snapshot.id)?.audioInfo ?? snapshot.audioInfo ?? AudioAlbumInfo())[keyPath: keyPath] },
            set: { value in
                manager.setIdentification(snapshot.id) { job in
                    var info = job.audioInfo ?? AudioAlbumInfo()
                    info[keyPath: keyPath] = value
                    job.audioInfo = info
                    if keyPath == \AudioAlbumInfo.date { job.year = String(info.date.prefix(4)) }
                }
            })
    }
}

// MARK: - Artwork

struct ArtworkPanel: View {
    let job: Job
    @EnvironmentObject var manager: JobManager
    @ViewState private var showCovers = false
    @ViewState private var dropTargeted = false
    @ViewState private var error: String?

    private var editable: Bool {
        switch job.status {
        case .identifying, .waiting: true
        case .success: !manager.retagging.contains(job.id)
        default: false
        }
    }

    var body: some View {
        Form {
            Section {
                CoverImageView(cover: job.audioInfo?.cover, size: 280)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if dropTargeted {
                            RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3)
                        }
                    }
                    .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
                        editable ? handleDrop(providers) : false
                    }
                    .help(editable ? "Drop an image here to use it as cover" : "")
                    .accessibilityLabel("Album cover")
                    .padding(.vertical, 6)
            } footer: {
                if editable {
                    Text("Drop an image onto the cover to replace it.").foregroundStyle(.secondary)
                }
            }
            if let cover = job.audioInfo?.cover {
                Section("Image") {
                    LabeledContent("Size", value: "\(cover.width) × \(cover.height) px")
                    LabeledContent("Format", value: cover.format.uppercased())
                    LabeledContent("File size", value: Int64(cover.bytes).formatted(.byteCount(style: .file)))
                    LabeledContent("Source", value: cover.source)
                    if min(cover.width, cover.height) < 1000 {
                        Label("Low resolution – look for a larger cover", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            if editable {
                Section {
                    Button("Find Covers…") { showCovers = true }
                    Button("Choose File…", action: chooseFile)
                    if let cover = job.audioInfo?.cover {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([cover.url]) }
                        Button("Remove Cover", role: .destructive) { manager.removeCover(job.id) }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showCovers) {
            CoverPickerSheet(load: { await manager.coverCandidates(job.id) },
                             use: { try await manager.useCover(job.id, $0) })
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a cover image (ideally square, at least 1000 × 1000 px)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        use(url)
    }

    private func use(_ url: URL) {
        do {
            try manager.useCoverFile(job.id, url)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in use(url) } }
            }
            return true
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            guard let data else { return }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dropped-cover-\(UUID().uuidString)")
            try? data.write(to: tmp)
            Task { @MainActor in
                use(tmp)
                try? FileManager.default.removeItem(at: tmp)
            }
        }
        return true
    }
}

struct CoverImageView: View {
    let cover: CoverImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let cover, let image = CoverCache.image(for: cover, points: size) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        .id(cover?.path ?? "none")
    }
}

/// Grid of cover candidates from Cover Art Archive and Apple Music.
struct CoverPickerSheet: View {
    let load: () async -> [CoverCandidate]
    let use: (CoverCandidate) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var candidates: [CoverCandidate] = []
    @ViewState private var loading = true
    @ViewState private var applying: CoverCandidate?
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a Cover").font(.headline)
            Text("Covers from Cover Art Archive (this edition and the album) and Apple Music (up to 3000 × 3000 px). The original file is kept without recompression.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red) }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], spacing: 16) {
                    ForEach(candidates) { candidate in
                        Button { apply(candidate) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                AsyncImage(url: candidate.thumbnailURL) { image in
                                    image.resizable().scaledToFit()
                                } placeholder: {
                                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                .frame(width: 170, height: 170)
                                .background(.quaternary.opacity(0.4))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    if applying == candidate {
                                        ProgressView().padding(8).glassEffect(.regular, in: .circle)
                                    }
                                }
                                Text(candidate.source).font(.caption.bold())
                                Text(candidate.caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text(candidate.expectedSize.map { "\($0) × \($0) px" } ?? "Original size")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(width: 170, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(applying != nil)
                        .accessibilityLabel("\(candidate.source), \(candidate.caption)")
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if loading {
                    ProgressView("Searching covers…")
                } else if candidates.isEmpty {
                    ContentUnavailableView("No Covers Found", systemImage: "photo",
                                           description: Text("Choose an image file or drop one onto the cover."))
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 640, height: 560)
        .task {
            candidates = await load()
            loading = false
        }
    }

    private func apply(_ candidate: CoverCandidate) {
        applying = candidate
        error = nil
        Task {
            do {
                try await use(candidate)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            applying = nil
        }
    }
}

// MARK: - Retag

struct RetagBanner: View {
    let job: Job
    @EnvironmentObject var manager: JobManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: manager.retagErrors[job.id] == nil ? "tag" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(manager.retagErrors[job.id] == nil ? Color.accentColor : .red)
            VStack(alignment: .leading, spacing: 2) {
                if manager.retagging.contains(job.id) {
                    Text("Writing tags…").bold()
                } else if let error = manager.retagErrors[job.id] {
                    Text("Writing tags failed").bold()
                    Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Text("Tags changed").bold()
                    Text("The ripped files still have the old tags. Writing updates tags and cover, and renames files and folder to match.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if manager.retagging.contains(job.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Write Tags to Files") { Task { await manager.writeTagsToFiles(job.id) } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
