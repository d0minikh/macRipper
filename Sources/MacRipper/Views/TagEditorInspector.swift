import SwiftUI
import UniformTypeIdentifiers

/// Right column of the Tag Editor: the tags of the selected songs, of the whole album when no song is selected, or of
/// several albums selected on the Tag Editor page. Fields whose values differ between the songs show "Mixed"; typing
/// into them sets the value for all of them.
struct TagEditorInspector: View {
    let albumIDs: [UUID]
    let selection: Set<UUID>
    @Binding var sheet: TagSheet?
    @EnvironmentObject var editor: TagEditor
    @AppStorage("inspectorTab") private var tab: InspectorTab = .info

    var body: some View {
        let albums = albumIDs.compactMap(editor.album)
        if !albums.isEmpty {
            let ids = albums.count == 1 ? editor.targets(album: albums[0], selection: selection)
                : albums.flatMap { editor.tracks(in: $0).map(\.id) }
            let songsSelected = albums.count == 1 && albums[0].trackIDs.contains(where: selection.contains)
            VStack(spacing: 0) {
                Picker("Inspector", selection: $tab) {
                    ForEach(InspectorTab.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                Divider()
                switch tab {
                case .info: TagInfoForm(ids: ids, albums: albums, songsSelected: songsSelected, sheet: $sheet)
                case .artwork: TagArtworkPanel(ids: ids, albums: albums, songsSelected: songsSelected, sheet: $sheet)
                case .file: TagFileForm(ids: ids)
                }
            }
        }
    }
}

// MARK: - Info

private struct TagInfoForm: View {
    let ids: [UUID]
    let albums: [LibraryAlbum]
    let songsSelected: Bool
    @Binding var sheet: TagSheet?
    @EnvironmentObject var editor: TagEditor

    var body: some View {
        let tracks = editor.tracks(ids)
        let saving = ids.contains(where: editor.saving.contains)
        Form {
            Section {
                Text(scopeText(tracks)).foregroundStyle(.secondary)
            }
            if songsSelected {
                Section {
                    field("Title", \.title, tracks)
                    field("Artist", \.artist, tracks, prompt: tracks.first?.tags.albumArtist ?? "")
                    numberPair("Track", \.track, \.trackTotal, tracks)
                    numberPair("Disc", \.disc, \.discTotal, tracks)
                    field("Composer", \.composer, tracks)
                    field("ISRC", \.isrc, tracks)
                    field("Comment", \.comment, tracks)
                } header: {
                    InspectorHeader(title: tracks.count == 1 ? "Song" : "Songs") {
                        if ids.count == 1, let id = ids.first {
                            Button("Look Up…") { sheet = .songLookup(id) }.controlSize(.small)
                        }
                    }
                }
                .disabled(saving)
            }
            Section {
                field("Album", \.album, tracks)
                field("Album artist", \.albumArtist, tracks)
                field("Sort album artist", \.albumArtistSort, tracks, prompt: "e.g. Beatles, The")
                field("Date", \.date, tracks, prompt: "YYYY-MM-DD")
                field("Original date", \.originalDate, tracks, prompt: "YYYY")
                field("Genre", \.genre, tracks)
                if !songsSelected { numberPair("Disc", \.disc, \.discTotal, tracks) }
                Toggle("Compilation", isOn: Binding(
                    get: { !tracks.isEmpty && tracks.allSatisfy(\.tags.compilation) },
                    set: { value in editor.edit(ids) { $0.compilation = value } }))
            } header: {
                InspectorHeader(title: albums.count == 1 ? "Album" : "Albums") {
                    if albums.count == 1 {
                        Button("Look Up…") { sheet = .albumLookup(ids) }.controlSize(.small)
                    }
                }
            }
            .disabled(saving)

            Section("Release") {
                field("Label", \.label, tracks)
                field("Catalog number", \.catalogNumber, tracks)
                field("Barcode", \.barcode, tracks, prompt: "EAN / UPC")
                field("Country", \.country, tracks, prompt: "Code, e.g. DE")
                field("Media", \.media, tracks, prompt: "CD, Digital Media …")
            }
            .disabled(saving)

            musicBrainz(tracks)

            let modified = tracks.filter(\.isModified).map(\.id)
            if !modified.isEmpty {
                Section {
                    HStack {
                        Button("Revert") { editor.revert(modified) }
                        Spacer()
                        Button("Save \(modified.count == 1 ? "Change" : "\(modified.count) Changes")") {
                            Task { await editor.save(modified) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .disabled(saving)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func scopeText(_ tracks: [LibraryTrack]) -> String {
        if albums.count > 1 {
            return "Changes apply to all \(tracks.count) songs of the \(albums.count) selected albums. Only change what they have in common, such as genre or label."
        }
        if !songsSelected { return "Changes apply to all \(tracks.count) songs of the album. Select songs to edit them on their own." }
        return tracks.count == 1 ? tracks[0].fileName : "Changes apply to the \(tracks.count) selected songs."
    }

    @ViewBuilder
    private func musicBrainz(_ tracks: [LibraryTrack]) -> some View {
        let release = Set(tracks.map(\.tags.musicBrainzReleaseID))
        let recording = Set(tracks.map(\.tags.musicBrainzRecordingID))
        if release != [""] || recording != [""] {
            Section("MusicBrainz") {
                if release.count == 1, let id = release.first, !id.isEmpty,
                   let url = URL(string: "https://musicbrainz.org/release/\(id)") {
                    Link("Open Release on MusicBrainz", destination: url)
                } else if release.count > 1 {
                    Text("The songs belong to different releases.").foregroundStyle(.secondary)
                }
                if tracks.count == 1, let id = recording.first, !id.isEmpty,
                   let url = URL(string: "https://musicbrainz.org/recording/\(id)") {
                    Link("Open Recording on MusicBrainz", destination: url)
                }
                Button("Remove MusicBrainz IDs") {
                    editor.edit(ids) { t in
                        t.musicBrainzReleaseID = ""
                        t.musicBrainzReleaseGroupID = ""
                        t.musicBrainzAlbumArtistID = ""
                        t.musicBrainzArtistID = ""
                        t.musicBrainzRecordingID = ""
                        t.musicBrainzReleaseTrackID = ""
                        t.musicBrainzDiscID = ""
                    }
                }
                .disabled(ids.contains(where: editor.saving.contains))
            }
        }
    }

    private func field(_ title: String, _ keyPath: WritableKeyPath<AudioTags, String>, _ tracks: [LibraryTrack],
                       prompt: String = "") -> some View {
        MultiValueField(title, targets: tracks.map(\.id), values: tracks.map { $0.tags[keyPath: keyPath] },
                        prompt: prompt) { ids, value in
            editor.edit(ids) { $0[keyPath: keyPath] = value }
        }
    }

    private func numberPair(_ title: String, _ number: WritableKeyPath<AudioTags, Int>,
                            _ total: WritableKeyPath<AudioTags, Int>, _ tracks: [LibraryTrack]) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                numberField(title, number, tracks)
                Text("of").foregroundStyle(.secondary)
                numberField("\(title) total", total, tracks)
            }
        }
    }

    private func numberField(_ title: String, _ keyPath: WritableKeyPath<AudioTags, Int>,
                             _ tracks: [LibraryTrack]) -> some View {
        MultiValueField(title, targets: tracks.map(\.id),
                        values: tracks.map { $0.tags[keyPath: keyPath] == 0 ? "" : "\($0.tags[keyPath: keyPath])" }) { ids, value in
            let number = Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
            editor.edit(ids) { $0[keyPath: keyPath] = max(0, number) }
        }
        .labelsHidden()
        .frame(width: 44)
        .multilineTextAlignment(.trailing)
    }
}

/// Text field for one tag of several files. Shows the common value, or "Mixed" when the files differ.
/// The value is committed on Return or when the field loses focus, and only if the user typed something; it applies
/// to the files that were shown when editing began, even if the selection changes before the commit.
struct MultiValueField: View {
    let title: String
    let targets: [UUID]
    let values: [String]
    var prompt = ""
    let commit: ([UUID], String) -> Void
    @ViewState private var text = ""
    @ViewState private var edited = false
    @ViewState private var editingTargets: [UUID] = []
    @FocusState private var focused: Bool

    init(_ title: String, targets: [UUID], values: [String], prompt: String = "",
         commit: @escaping ([UUID], String) -> Void) {
        self.title = title
        self.targets = targets
        self.values = values
        self.prompt = prompt
        self.commit = commit
    }

    private var common: String? {
        let unique = Set(values)
        return unique.count <= 1 ? (values.first ?? "") : nil
    }

    var body: some View {
        TextField(title, text: $text, prompt: Text(common == nil ? "Mixed" : prompt))
            .focused($focused)
            .onAppear { text = common ?? "" }
            .onChange(of: values) { if !focused { text = common ?? "" } }
            .onChange(of: targets) { if !focused { text = common ?? ""; edited = false } }
            .onChange(of: text) { if focused { edited = true } }
            .onChange(of: focused) { _, isFocused in
                if isFocused {
                    editingTargets = targets
                    edited = false
                } else {
                    save()
                }
            }
            .onSubmit(save)
    }

    private func save() {
        guard edited else { return }
        edited = false
        let ids = editingTargets.isEmpty ? targets : editingTargets
        commit(ids, text)
    }
}

// MARK: - Artwork

private struct TagArtworkPanel: View {
    let ids: [UUID]
    let albums: [LibraryAlbum]
    let songsSelected: Bool
    @Binding var sheet: TagSheet?
    @EnvironmentObject var editor: TagEditor
    @ViewState private var dropTargeted = false
    @ViewState private var message: String?
    @ViewState private var error: String?

    var body: some View {
        let tracks = editor.tracks(ids)
        let covers = Set(tracks.map(\.cover))
        let cover = tracks.lazy.compactMap(\.cover).first
        let saving = ids.contains(where: editor.saving.contains)
        Form {
            Section {
                CoverImageView(cover: cover, size: 280)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if dropTargeted { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3) }
                    }
                    .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
                        saving ? false : handleDrop(providers)
                    }
                    .accessibilityLabel("Cover")
                    .padding(.vertical, 6)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if covers.count > 1 {
                        Text("These songs have different covers; a new cover replaces all of them.")
                            .foregroundStyle(.orange)
                    }
                    Text("Drop an image onto the cover to use it for \(songsSelected && ids.count == 1 ? "this song" : scope).")
                        .foregroundStyle(.secondary)
                }
            }
            if let cover {
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
            Section {
                Button("Find Covers…") { sheet = .covers(ids) }
                    .disabled(albums.count > 1)
                    .help(albums.count > 1 ? "Covers are searched for one album at a time" : "")
                Button("Choose File…", action: chooseFile)
                if cover != nil {
                    Button("Remove Cover", role: .destructive) { editor.setCover(nil, for: ids) }
                }
                if !songsSelected, cover != nil {
                    Button("Save as \(coverFileName) in \(albums.count == 1 ? "Folder" : "Folders")") {
                        do {
                            let saved = try albums.compactMap { try editor.saveCoverFile($0) }
                            message = saved.count == 1 ? "Saved \(saved[0].lastPathComponent) next to the music."
                                : "Saved the covers of \(saved.count) albums next to their music."
                            error = nil
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .help("Copies the cover into the album's folder, where many players and servers look for it")
                }
            }
            .disabled(saving)
            if let message { Text(message).foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
    }

    private var scope: String {
        songsSelected ? "the selected songs" : albums.count == 1 ? "the whole album" : "all \(albums.count) selected albums"
    }

    private var coverFileName: String {
        let name = editor.configStore.config.audioCoverFileName
        return (name.isEmpty ? "cover" : name) + ".jpg"
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
            try editor.useCoverFile(url, for: ids)
            error = nil
            message = nil
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

// MARK: - File

private struct TagFileForm: View {
    let ids: [UUID]
    @EnvironmentObject var editor: TagEditor

    var body: some View {
        let tracks = editor.tracks(ids)
        Form {
            if tracks.count == 1, let track = tracks.first {
                Section("File") {
                    Text(track.url.path)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(4)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([track.url]) }
                }
                Section("Audio") {
                    LabeledContent("Format", value: track.info.format)
                    if !track.info.summary.isEmpty { LabeledContent("Properties", value: track.info.summary) }
                    LabeledContent("Length", value: duration(track.info.duration))
                    LabeledContent("File size", value: track.info.fileSize.formatted(.byteCount(style: .file)))
                }
            } else {
                Section("Files") {
                    LabeledContent("Songs", value: "\(tracks.count)")
                    LabeledContent("Formats", value: Set(tracks.map(\.info.format)).sorted().joined(separator: ", "))
                    LabeledContent("Length", value: duration(tracks.reduce(0) { $0 + $1.info.duration }))
                    LabeledContent("Size", value: tracks.reduce(Int64(0)) { $0 + $1.info.fileSize }.formatted(.byteCount(style: .file)))
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(tracks.map(\.url)) }
                }
            }
            let modified = tracks.filter(\.isModified)
            Section("Status") {
                if ids.contains(where: editor.saving.contains) {
                    Label("Saving…", systemImage: "arrow.down.doc")
                } else if modified.isEmpty {
                    Label("Saved – the files match the tags shown", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("\(modified.count) file\(modified.count == 1 ? " has" : "s have") unsaved changes", systemImage: "circle.fill")
                        .foregroundStyle(.orange)
                    Button("Revert Changes") { editor.revert(modified.map(\.id)) }
                }
                ForEach(tracks.filter { $0.error != nil }) { track in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.fileName).bold()
                        Text(track.error ?? "").foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? DiscTitle.format(seconds: s) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
