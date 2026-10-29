import SwiftUI

// MARK: - Album

/// Finds the MusicBrainz release of existing files, matches the files to its tracks and takes over its tags.
struct ReleaseLookupSheet: View {
    let ids: [UUID]
    @EnvironmentObject var editor: TagEditor
    @Environment(\.dismiss) private var dismiss
    @ViewState private var query = ""
    @ViewState private var results: [AudioRelease] = []
    @ViewState private var error: String?
    @ViewState private var searching = false
    @ViewState private var loadingRelease: String?
    @ViewState private var release: AudioRelease?
    @ViewState private var mapping: [UUID: ReleaseTrackRef] = [:]
    @ViewState private var useCover = true
    @ViewState private var applying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let release {
                matchStep(release)
            } else {
                searchStep
            }
        }
        .padding()
        .frame(width: 720, height: 560)
        .onAppear(perform: prefill)
    }

    // MARK: Search

    private var searchStep: some View {
        Group {
            Text("Look Up Album on MusicBrainz").font(.headline)
            HStack {
                TextField("Artist and album, or a MusicBrainz release link", text: $query).onSubmit(search)
                Button("Search", action: search).keyboardShortcut(.defaultAction).disabled(query.isEmpty || searching)
            }
            Text("\(ids.count) file\(ids.count == 1 ? "" : "s"). Releases with \(ids.count) tracks on a disc are listed first; after choosing one you can check which file gets which track.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            List(results) { release in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(release.artist) – \(release.title)").bold()
                        Text(release.editionSummary.isEmpty ? "No edition details" : release.editionSummary)
                            .font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text("\(release.trackCount) tracks")
                            if release.discTotal > 1 { Text("\(release.discTotal) discs") }
                            if !release.barcode.isEmpty { Text("Barcode \(release.barcode)") }
                            if release.hasFrontCover { Label("Cover", systemImage: "photo").labelStyle(.titleAndIcon) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if loadingRelease == release.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Choose") { choose(release) }.disabled(loadingRelease != nil)
                    }
                }
                .padding(.vertical, 2)
            }
            .overlay {
                if searching { ProgressView() }
                else if results.isEmpty, !query.isEmpty { ContentUnavailableView.search(text: query) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: Matching

    private func matchStep(_ release: AudioRelease) -> some View {
        let files = editor.tracks(ids)
        let refs = allTracks(release)
        let multiDisc = Set(refs.map(\.0.disc)).count > 1
        let used = Dictionary(grouping: mapping.values, by: { $0 }).filter { $0.value.count > 1 }.keys
        return Group {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(release.artist) – \(release.title)").font(.headline)
                Text(release.editionSummary).font(.callout).foregroundStyle(.secondary)
            }
            Text("\(mapping.count) of \(files.count) files matched. Check the assignment; files left unchanged keep their tags.")
                .font(.caption).foregroundStyle(.secondary)
            List(files) { file in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.displayTitle).lineLimit(1)
                        Text(file.fileName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Picker("Track for \(file.fileName)", selection: Binding(
                        get: { mapping[file.id] },
                        set: { mapping[file.id] = $0 })) {
                        Text("Leave unchanged").tag(ReleaseTrackRef?.none)
                        Divider()
                        ForEach(refs, id: \.0) { ref, track in
                            Text(ReleaseMatcher.label(ref, track, multiDisc: multiDisc)).tag(ReleaseTrackRef?.some(ref))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 320)
                    .overlay(alignment: .trailing) {
                        if let ref = mapping[file.id], used.contains(ref) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .offset(x: 20)
                                .help("Several files get this track")
                        }
                    }
                    .padding(.trailing, 22)
                }
            }
            Toggle("Use the best cover of this release (Cover Art Archive\(editor.configStore.config.audioCoverFromAppleMusic ? " or Apple Music" : ""))",
                   isOn: $useCover)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Back") { self.release = nil; mapping = [:]; error = nil }
                    .disabled(applying)
                Spacer()
                if applying { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply(release) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mapping.isEmpty || applying)
            }
        }
    }

    private func allTracks(_ release: AudioRelease) -> [(ReleaseTrackRef, AudioTrackInfo)] {
        let media = release.discTracks.isEmpty ? [release.discNumber: release.tracks] : release.discTracks
        return media.keys.sorted().flatMap { disc in
            (media[disc] ?? []).map { (ReleaseTrackRef(disc: disc, number: $0.number), $0) }
        }
    }

    // MARK: Actions

    private func prefill() {
        let tracks = editor.tracks(ids)
        let releaseIDs = Set(tracks.map(\.tags.musicBrainzReleaseID))
        if releaseIDs.count == 1, let id = releaseIDs.first, !id.isEmpty {
            query = "https://musicbrainz.org/release/\(id)"
        } else if let tags = tracks.first?.tags {
            let artist = tags.albumArtist.isEmpty ? tags.artist : tags.albumArtist
            query = [artist, tags.album].filter { !$0.isEmpty }.joined(separator: " ")
        }
        search()
    }

    private func search() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        error = nil
        Task {
            do {
                results = try await Metadata.searchReleasesForFiles(query, trackCount: ids.count)
                if results.isEmpty { error = "No matching releases" }
            } catch {
                self.error = error.localizedDescription
            }
            searching = false
        }
    }

    private func choose(_ summary: AudioRelease) {
        loadingRelease = summary.id
        error = nil
        Task {
            do {
                let full = summary.isComplete && !summary.discTracks.isEmpty
                    ? summary : try await Metadata.release(id: summary.id, trackCount: ids.count)
                let files = editor.tracks(ids).map {
                    ReleaseMatcher.File(id: $0.id, disc: $0.tags.disc, track: $0.tags.track,
                                        title: $0.tags.title, duration: $0.info.duration)
                }
                mapping = ReleaseMatcher.match(files, to: full)
                useCover = full.hasFrontCover || editor.configStore.config.audioCoverFromAppleMusic
                release = full
            } catch {
                self.error = error.localizedDescription
            }
            loadingRelease = nil
        }
    }

    private func apply(_ release: AudioRelease) {
        applying = true
        error = nil
        Task {
            editor.apply(release, to: mapping)
            if useCover, !(await editor.useBestCover(of: release, for: Array(mapping.keys))) {
                error = "Tags were taken over, but no cover was found. Choose one on the Artwork tab."
                applying = false
                return
            }
            applying = false
            dismiss()
        }
    }
}

// MARK: - Song

/// Finds a single song on MusicBrainz by title and artist and takes over its tags, including the album it is on.
struct SongLookupSheet: View {
    let id: UUID
    @EnvironmentObject var editor: TagEditor
    @Environment(\.dismiss) private var dismiss
    @ViewState private var title = ""
    @ViewState private var artist = ""
    @ViewState private var album = ""
    @ViewState private var results: [RecordingMatch] = []
    @ViewState private var error: String?
    @ViewState private var searching = false
    @ViewState private var applying: String?
    @ViewState private var useCover = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Look Up Song on MusicBrainz").font(.headline)
            HStack {
                TextField("Title", text: $title).onSubmit(search)
                TextField("Artist", text: $artist).onSubmit(search)
                TextField("Album (optional)", text: $album).onSubmit(search)
                Button("Search", action: search).keyboardShortcut(.defaultAction).disabled(title.isEmpty || searching)
            }
            Text("Every release the song appears on is listed, official albums first. Choosing one sets the song's tags and the album it belongs to.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            List(results) { match in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(match.title) – \(match.artist)").bold()
                        Text(match.releaseSummary).font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            if !match.trackNumber.isEmpty { Text("Track \(match.trackNumber)") }
                            if match.length > 0 { Text(String(format: "%d:%02d", match.length / 60, match.length % 60)) }
                            if !match.official { Text("Not official") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if applying == match.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Use") { use(match) }.disabled(applying != nil)
                    }
                }
                .padding(.vertical, 2)
            }
            .overlay {
                if searching { ProgressView() }
                else if results.isEmpty, !title.isEmpty { ContentUnavailableView.search(text: title) }
            }
            HStack {
                Toggle("Use the album's cover", isOn: $useCover)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 720, height: 540)
        .onAppear {
            guard let track = editor.tracks[id] else { return }
            title = track.tags.title.isEmpty ? TagEditor.parseFileName(track.url.deletingPathExtension().lastPathComponent).title : track.tags.title
            artist = track.tags.artist.isEmpty ? track.tags.albumArtist : track.tags.artist
            album = track.tags.album
            search()
        }
    }

    private func search() {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        error = nil
        Task {
            do {
                results = try await Metadata.searchRecordings(title: title, artist: artist, album: album)
                if results.isEmpty, !album.isEmpty {
                    // The album name in the file is often slightly different; try once more without it.
                    results = try await Metadata.searchRecordings(title: title, artist: artist)
                }
                if results.isEmpty { error = "No matching songs" }
            } catch {
                self.error = error.localizedDescription
            }
            searching = false
        }
    }

    private func use(_ match: RecordingMatch) {
        applying = match.id
        error = nil
        Task {
            do {
                let release = try await Metadata.release(id: match.releaseID, trackCount: 0)
                let media = release.discTracks.isEmpty ? [release.discNumber: release.tracks] : release.discTracks
                let ref = media.keys.sorted().lazy.compactMap { disc in
                    media[disc]?.first { $0.recordingID == match.recordingID }
                        .map { ReleaseTrackRef(disc: disc, number: $0.number) }
                }.first
                guard let ref else { throw MetadataError.badResponse("the song is missing on this release") }
                editor.apply(release, to: [id: ref])
                if useCover { _ = await editor.useBestCover(of: release, for: [id]) }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            applying = nil
        }
    }
}

// MARK: - Rename

/// Renames files after their tags, with a preview of every new name.
struct RenameSheet: View {
    let ids: [UUID]
    @EnvironmentObject var editor: TagEditor
    @Environment(\.dismiss) private var dismiss
    @ViewState private var pattern = ""
    @ViewState private var error: String?

    var body: some View {
        let plan = editor.renamePlan(ids, pattern: pattern.isEmpty ? "{track} - {title}" : pattern)
        let changes = plan.count { $0.changes }
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Files").font(.headline)
            TextField("Pattern", text: $pattern, prompt: Text("{track} - {title}"))
            Text("Placeholders: {track}, {title}, {trackartist}, {artist} (album artist), {album}, {year}, {genre}, {disc}. Files stay in their folders. Names use the tags shown in the editor, including unsaved changes.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(plan) { item in
                HStack(spacing: 8) {
                    Text(item.oldName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(item.newName).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(item.changes ? .primary : .secondary)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Text(changes == 0 ? "All names already match." : "\(changes) file\(changes == 1 ? "" : "s") will be renamed.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") {
                    do {
                        try editor.rename(plan)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(changes == 0)
            }
        }
        .padding()
        .frame(width: 720, height: 520)
        .onAppear { pattern = editor.configStore.config.audioFilePattern }
    }
}
