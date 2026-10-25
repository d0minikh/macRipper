import SwiftUI

/// Manual title correction for video discs (ARM: "Title search" / "Custom title").
struct VideoSearchSheet: View {
    let job: Job
    @EnvironmentObject var manager: JobManager
    @EnvironmentObject var configStore: ConfigStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var query = ""
    @ViewState private var year = ""
    @ViewState private var results: [VideoSearchResult] = []
    @ViewState private var error: String?
    @ViewState private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search Metadata (\(configStore.config.metadataProvider.label))").font(.headline)
            HStack {
                TextField("Title", text: $query).onSubmit(search)
                TextField("Year", text: $year).frame(width: 70).onSubmit(search)
                Button("Search", action: search).keyboardShortcut(.defaultAction).disabled(query.isEmpty || searching)
            }
            if let error { Text(error).foregroundStyle(.red) }
            List(results) { r in
                HStack(spacing: 12) {
                    AsyncImage(url: URL(string: r.posterURL)) { $0.resizable().scaledToFit() } placeholder: {
                        Color.secondary.opacity(0.1)
                    }
                    .frame(width: 40, height: 58)
                    VStack(alignment: .leading) {
                        Text(r.title).bold()
                        Text("\(r.year) · \(r.kind.label)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Use") {
                        manager.setIdentification(job.id) {
                            $0.title = r.title
                            $0.year = r.year
                            $0.videoKind = r.kind == .unknown ? $0.videoKind : r.kind
                            $0.imdbID = r.imdbID
                            $0.posterURL = r.posterURL
                        }
                        dismiss()
                    }
                }
            }
            .overlay { if searching { ProgressView() } }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 560, height: 480)
        .onAppear {
            query = job.title.isEmpty ? DiscIdentifier.cleanLabel(job.discLabel) : job.title
            year = job.year
            search()
        }
    }

    func search() {
        guard !query.isEmpty else { return }
        searching = true
        error = nil
        Task {
            do {
                results = try await Metadata.searchVideo(query, year: year, config: configStore.config)
                if results.isEmpty { error = "No results" }
            } catch {
                self.error = error.localizedDescription
            }
            searching = false
        }
    }
}

/// Find the right MusicBrainz release (edition) for an audio CD.
struct AudioSearchSheet: View {
    let job: Job
    @EnvironmentObject var manager: JobManager
    @Environment(\.dismiss) private var dismiss
    @ViewState private var query = ""
    @ViewState private var results: [AudioRelease] = []
    @ViewState private var error: String?
    @ViewState private var searching = false
    @ViewState private var applying: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search MusicBrainz").font(.headline)
            HStack {
                TextField("Artist and album, or a MusicBrainz release link", text: $query).onSubmit(search)
                Button("Search", action: search).keyboardShortcut(.defaultAction).disabled(query.isEmpty || searching)
            }
            Text("Only releases with \(job.titles.count) tracks are shown. Pick the edition that matches your CD (country, label, catalog number on the back).")
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
                            if release.discTotal > 1 { Text("Disc \(release.discNumber) of \(release.discTotal)") }
                            if !release.barcode.isEmpty { Text("Barcode \(release.barcode)") }
                            if release.hasFrontCover { Label("Cover", systemImage: "photo").labelStyle(.titleAndIcon) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if applying == release.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Use") { use(release) }.disabled(applying != nil)
                    }
                }
                .padding(.vertical, 2)
            }
            .overlay {
                if searching { ProgressView() }
                else if results.isEmpty { ContentUnavailableView.search(text: query) }
            }
            HStack {
                Link("Add this CD to MusicBrainz", destination: URL(string: "https://musicbrainz.org/cdtoc/attach?id=\(job.musicBrainzDiscID)")!)
                    .font(.caption)
                    .opacity(job.musicBrainzDiscID.isEmpty ? 0 : 1)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 640, height: 520)
        .onAppear {
            results = manager.audioCandidates(job.id)
            let known = !job.album.isEmpty && job.album != "Unknown Album"
            query = known ? "\(job.artist) \(job.album)" : ""
        }
    }

    private func search() {
        // Return in the empty field would otherwise send an invalid " AND tracks:…" query.
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        error = nil
        Task {
            do {
                results = try await Metadata.searchReleases(query, trackCount: job.titles.count)
                if results.isEmpty { error = "No matching releases" }
            } catch {
                self.error = error.localizedDescription
            }
            searching = false
        }
    }

    private func use(_ release: AudioRelease) {
        applying = release.id
        error = nil
        Task {
            do {
                try await manager.chooseRelease(job.id, release)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            applying = nil
        }
    }
}
