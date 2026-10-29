import Foundation
import CryptoKit

/// The Tag Editor's working set: existing music files, their edited tags and covers, and the actions on them.
/// Nothing is written to a file before the user saves; until then every change can be reverted.
@MainActor
final class TagEditor: ObservableObject {
    struct Progress: Equatable {
        var done: Int
        var total: Int
    }

    struct RenameItem: Identifiable, Equatable {
        let id: UUID
        let oldName: String
        let newName: String
        var changes: Bool { oldName != newName }
    }

    @Published private(set) var tracks: [UUID: LibraryTrack] = [:]
    @Published private(set) var albums: [LibraryAlbum] = []
    @Published private(set) var loading: Progress?
    @Published private(set) var saving: Set<UUID> = []
    /// Problems of the last add or save that do not belong to a single file (shown on the Tag Editor page).
    @Published var notice: String?

    let configStore: ConfigStore
    private var config: AppConfig { configStore.config }

    init(configStore: ConfigStore) {
        self.configStore = configStore
        // Covers are only kept while their files are loaded, and nothing is loaded at launch.
        TagEditorCovers.clear()
    }

    // MARK: Queries

    func album(_ id: UUID) -> LibraryAlbum? { albums.first { $0.id == id } }

    func tracks(in album: LibraryAlbum) -> [LibraryTrack] {
        album.trackIDs.compactMap { tracks[$0] }.sorted(by: LibraryTrack.areInOrder)
    }

    func tracks(_ ids: some Sequence<UUID>) -> [LibraryTrack] {
        ids.compactMap { tracks[$0] }.sorted(by: LibraryTrack.areInOrder)
    }

    var modifiedCount: Int { tracks.values.count { $0.isModified } }
    var modifiedIDs: [UUID] { tracks.values.filter(\.isModified).map(\.id) }

    func isSaving(_ album: LibraryAlbum) -> Bool { album.trackIDs.contains { saving.contains($0) } }

    /// Albums in the order of the sidebar: by artist, then title.
    var sortedAlbums: [(album: LibraryAlbum, summary: LibraryAlbumSummary)] {
        albums.map { ($0, summary($0)) }.sorted { a, b in
            let artist = a.summary.artist.localizedStandardCompare(b.summary.artist)
            if artist != .orderedSame { return artist == .orderedAscending }
            return a.summary.title.localizedStandardCompare(b.summary.title) == .orderedAscending
        }
    }

    func summary(_ album: LibraryAlbum) -> LibraryAlbumSummary {
        let list = album.trackIDs.compactMap { tracks[$0] }
        func common(_ keyPath: KeyPath<AudioTags, String>) -> String {
            let values = Set(list.map { $0.tags[keyPath: keyPath] })
            return values.count == 1 ? values.first ?? "" : ""
        }
        let albumTitle = common(\.album)
        let firstTitle = list.lazy.map(\.tags.album).first { !$0.isEmpty } ?? ""
        let albumArtist = common(\.albumArtist), artist = common(\.artist)
        let anyArtist = list.contains { !$0.tags.artist.isEmpty || !$0.tags.albumArtist.isEmpty }
        return LibraryAlbumSummary(
            title: albumTitle.isEmpty ? (firstTitle.isEmpty ? album.folder.lastPathComponent : firstTitle) : albumTitle,
            artist: !albumArtist.isEmpty ? albumArtist : !artist.isEmpty ? artist
                : (list.count > 1 && anyArtist ? "Various Artists" : "Unknown Artist"),
            year: common(\.year),
            genre: common(\.genre),
            cover: list.sorted(by: LibraryTrack.areInOrder).lazy.compactMap(\.cover).first,
            trackCount: list.count,
            modifiedCount: list.count { $0.isModified },
            errorCount: list.count { $0.error != nil },
            formats: Set(list.map(\.info.format)).sorted().joined(separator: ", "),
            duration: list.reduce(0) { $0 + $1.info.duration },
            hasAlbumTag: !firstTitle.isEmpty)
    }

    // MARK: Adding and removing

    /// Adds files and folders (searched recursively). Files that are already loaded are skipped.
    func add(_ urls: [URL]) async {
        guard loading == nil else { return }
        let known = Set(tracks.values.map { $0.url.standardizedFileURL.path })
        var seen = Set<String>()
        let files = Self.audioFiles(in: urls).filter { url in
            let path = url.standardizedFileURL.path
            return !known.contains(path) && seen.insert(path).inserted
        }
        guard !files.isEmpty else {
            notice = urls.isEmpty ? nil : "No new FLAC, M4A or MP3 files were found."
            return
        }
        notice = nil
        loading = Progress(done: 0, total: files.count)
        var failed: [String] = []
        var added: [LibraryTrack] = []
        await withTaskGroup(of: (URL, Result<(AudioFileContents, CoverImage?), Error>).self) { group in
            var next = 0
            func enqueue() {
                guard next < files.count else { return }
                let url = files[next]
                next += 1
                group.addTask {
                    do {
                        let contents = try await TagReader.read(url)
                        let cover = contents.cover.flatMap { TagEditorCovers.store($0, source: "Embedded in file") }
                        return (url, .success((contents, cover)))
                    } catch {
                        return (url, .failure(error))
                    }
                }
            }
            // A few files at a time: enough to hide the latency of AVFoundation, without opening hundreds of files.
            for _ in 0..<8 { enqueue() }
            for await (url, result) in group {
                switch result {
                case .success(let (contents, cover)):
                    added.append(LibraryTrack(id: UUID(), url: url, info: contents.info, original: contents.tags,
                                              tags: contents.tags, originalCover: cover, cover: cover))
                case .failure:
                    failed.append(url.lastPathComponent)
                }
                loading?.done += 1
                enqueue()
            }
        }
        for track in added.sorted(by: { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }) {
            tracks[track.id] = track
            let folder = track.url.deletingLastPathComponent().standardizedFileURL
            let key = track.original.album.lowercased()
            if let i = albums.firstIndex(where: { $0.folder == folder && $0.albumKey == key }) {
                albums[i].trackIDs.append(track.id)
            } else {
                albums.append(LibraryAlbum(id: UUID(), folder: folder, albumKey: key, trackIDs: [track.id]))
            }
        }
        loading = nil
        if !failed.isEmpty {
            let names = failed.prefix(3).joined(separator: ", ") + (failed.count > 3 ? " …" : "")
            notice = "\(failed.count) file\(failed.count == 1 ? "" : "s") could not be read: \(names)"
        }
    }

    nonisolated static func audioFiles(in urls: [URL]) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                if TagReader.isSupported(url) { files.append(url) }
                continue
            }
            let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let file = enumerator?.nextObject() as? URL {
                if TagReader.isSupported(file) { files.append(file) }
            }
        }
        return files
    }

    func remove(_ ids: some Sequence<UUID>) {
        let ids = Set(ids)
        for id in ids { tracks[id] = nil }
        albums = albums.compactMap { album in
            var album = album
            album.trackIDs.removeAll { ids.contains($0) }
            return album.trackIDs.isEmpty ? nil : album
        }
    }

    func removeAll() {
        tracks = [:]
        albums = []
        notice = nil
        TagEditorCovers.clear()
    }

    // MARK: Editing

    func edit(_ ids: some Sequence<UUID>, _ change: (inout AudioTags) -> Void) {
        for id in ids { tracks[id]?.tags.modify(change) }
    }

    func setCover(_ cover: CoverImage?, for ids: some Sequence<UUID>) {
        for id in ids { tracks[id]?.cover = cover }
    }

    func revert(_ ids: some Sequence<UUID>) {
        for id in ids {
            guard var track = tracks[id] else { continue }
            track.tags = track.original
            track.cover = track.originalCover
            track.error = nil
            tracks[id] = track
        }
    }

    /// Numbers the given tracks 1, 2, 3 … in this order and sets the track total.
    func numberTracks(_ orderedIDs: [UUID]) {
        for (index, id) in orderedIDs.enumerated() {
            tracks[id]?.tags.track = index + 1
            tracks[id]?.tags.trackTotal = orderedIDs.count
        }
    }

    /// Capitalizes the first letter of every word in titles; the rest of each word is left alone ("DJ" stays "DJ").
    func capitalizeTitles(_ ids: some Sequence<UUID>) {
        edit(ids) { $0.title = Self.capitalizedWords($0.title) }
    }

    nonisolated static func capitalizedWords(_ text: String) -> String {
        var result = ""
        var startOfWord = true
        for character in text {
            result += startOfWord ? character.uppercased() : String(character)
            startOfWord = character.isWhitespace || character == "(" || character == "[" || character == "\"" || character == "-"
        }
        return result
    }

    /// Fills track number, title and (for "Artist - Title") artist from file names like "03 - Artist - Title.flac".
    func tagsFromFileNames(_ ids: some Sequence<UUID>) {
        for id in ids {
            guard let track = tracks[id] else { continue }
            let parsed = Self.parseFileName(track.url.deletingPathExtension().lastPathComponent)
            edit([id]) { tags in
                if let number = parsed.track { tags.track = number }
                if let artist = parsed.artist { tags.artist = artist }
                tags.title = parsed.title
            }
        }
    }

    nonisolated static func parseFileName(_ name: String) -> (track: Int?, artist: String?, title: String) {
        var rest = name.trimmingCharacters(in: .whitespaces)
        var track: Int?
        if let match = rest.range(of: #"^\d{1,3}(?=[\s._-])"#, options: .regularExpression) {
            track = Int(rest[match])
            rest = String(rest[match.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
        }
        let parts = rest.components(separatedBy: " - ")
        if parts.count >= 2 {
            return (track, parts[0].trimmingCharacters(in: .whitespaces),
                    parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces))
        }
        return (track, nil, rest)
    }

    // MARK: Saving

    /// Writes the changed tags (and cover) into the files. Tags MacRipper does not manage, such as lyrics or
    /// ReplayGain, stay in the files. Afterwards every file is read again, so the editor shows what was written.
    func save(_ ids: some Sequence<UUID>) async {
        let targets = ids.compactMap { tracks[$0] }.filter { $0.isModified && !saving.contains($0.id) }
            .sorted { $0.url.path < $1.url.path }
        guard !targets.isEmpty else { return }
        saving.formUnion(targets.map(\.id))
        let runner = ProcessRunner()
        let embedPixels = config.audioEmbedCoverMaxPixels > 0 ? config.audioEmbedCoverMaxPixels : CoverArt.appleMusicSize
        for track in targets {
            var tags = track.tags
            if track.coverChanged, let cover = track.cover,
               let embedded = CoverArt.embeddedData(cover, maxPixels: embedPixels) {
                tags.cover = AudioTags.EmbeddedCover(data: embedded.data, format: embedded.format,
                                                     width: embedded.width, height: embedded.height)
            }
            do {
                try await AudioRipper.writeTags(tags, to: track.url, config: config, runner: runner, log: nil,
                                                preservingOtherTags: true, keepExistingCover: !track.coverChanged)
                let fresh = try await TagReader.read(track.url)
                let cover = fresh.cover.flatMap { TagEditorCovers.store($0, source: "Embedded in file") }
                if var current = tracks[track.id] {
                    current.info = fresh.info
                    current.original = fresh.tags
                    current.originalCover = cover
                    // Edits made while the file was written stay pending on top of the new state.
                    if current.tags == track.tags { current.tags = fresh.tags }
                    if current.cover == track.cover { current.cover = cover }
                    current.error = nil
                    tracks[track.id] = current
                }
            } catch {
                tracks[track.id]?.error = error.localizedDescription
            }
            saving.remove(track.id)
        }
    }

    // MARK: Renaming

    /// New file names from a pattern such as "{track} - {title}"; files stay in their folders.
    func renamePlan(_ ids: some Sequence<UUID>, pattern: String) -> [RenameItem] {
        let list = tracks(ids)
        var plan: [RenameItem] = []
        for (folder, group) in Dictionary(grouping: list, by: { $0.url.deletingLastPathComponent() }) {
            let moving = Set(group.map { $0.fileName.lowercased() })
            let others = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .map { $0.lowercased() }.filter { !moving.contains($0) }
            var taken = Set(others)
            for track in group.sorted(by: LibraryTrack.areInOrder) {
                let base = AudioRipper.expand(AudioRipper.filePattern(pattern, discTotal: track.tags.discTotal), track.tags)
                let ext = track.url.pathExtension
                var name = "\(base).\(ext)"
                var n = 2
                while !taken.insert(name.lowercased()).inserted {
                    name = "\(base) (\(n)).\(ext)"
                    n += 1
                }
                plan.append(RenameItem(id: track.id, oldName: track.fileName, newName: name))
            }
        }
        return plan.sorted { a, b in
            guard let ta = tracks[a.id], let tb = tracks[b.id] else { return false }
            return LibraryTrack.areInOrder(ta, tb)
        }
    }

    /// Renames in two steps, because a new name may be the old name of another file of the same plan.
    func rename(_ plan: [RenameItem]) throws {
        let fm = FileManager.default
        var moved: [(id: UUID, temp: URL, final: URL, original: URL)] = []
        do {
            for item in plan where item.changes {
                guard let track = tracks[item.id] else { continue }
                let folder = track.url.deletingLastPathComponent()
                let temp = folder.appendingPathComponent(".macripper-\(UUID().uuidString).\(track.url.pathExtension)")
                try fm.moveItem(at: track.url, to: temp)
                moved.append((item.id, temp, folder.appendingPathComponent(item.newName), track.url))
            }
        } catch {
            for move in moved { try? fm.moveItem(at: move.temp, to: move.original) }
            throw error
        }
        for (index, move) in moved.enumerated() {
            do {
                try fm.moveItem(at: move.temp, to: move.final)
                tracks[move.id]?.url = move.final
            } catch {
                // Files already renamed keep their new names; the rest go back to their old ones.
                for rest in moved[index...] { try? fm.moveItem(at: rest.temp, to: rest.original) }
                throw error
            }
        }
    }

    // MARK: MusicBrainz

    /// Takes album and track tags from a MusicBrainz release for the given files. Existing genres are only
    /// replaced when MusicBrainz knows one.
    func apply(_ release: AudioRelease, to mapping: [UUID: ReleaseTrackRef]) {
        for (id, ref) in mapping {
            let medium = release.discTracks[ref.disc] ?? release.tracks
            guard let info = medium.first(where: { $0.number == ref.number }) else { continue }
            edit([id]) { t in
                t.album = release.title
                t.albumArtist = release.artist
                t.albumArtistSort = release.artistSort
                t.date = release.date
                t.originalDate = release.originalDate
                if !release.genre.isEmpty { t.genre = release.genre }
                t.label = release.label
                t.catalogNumber = release.catalogNumber
                t.barcode = release.barcode
                t.country = release.country
                t.media = release.discFormats[ref.disc] ?? release.format
                t.compilation = release.isCompilation
                t.disc = ref.disc
                t.discTotal = max(release.discTotal, release.discTracks.count, 1)
                t.track = info.number
                t.trackTotal = medium.count
                t.title = info.title
                t.artist = info.artist
                t.isrc = info.isrc
                t.musicBrainzReleaseID = release.id
                t.musicBrainzReleaseGroupID = release.releaseGroupID
                t.musicBrainzAlbumArtistID = release.artistID
                t.musicBrainzArtistID = info.artistID
                t.musicBrainzRecordingID = info.recordingID
                t.musicBrainzReleaseTrackID = info.releaseTrackID
            }
        }
    }

    /// Finds the sharpest cover of a release (Cover Art Archive or Apple Music) and uses it for the files.
    func useBestCover(of release: AudioRelease, for ids: [UUID]) async -> Bool {
        guard let (candidate, data, _) = await CoverArt.findBest(
            releaseID: release.id, releaseGroupID: release.releaseGroupID, artist: release.artist, album: release.title,
            trackCount: release.trackCount, includeAppleMusic: config.audioCoverFromAppleMusic, log: nil),
            let cover = TagEditorCovers.store(data, source: candidate.source) else { return false }
        setCover(cover, for: ids)
        return true
    }

    func coverCandidates(for ids: [UUID]) async -> [CoverCandidate] {
        guard let tags = tracks(ids).first?.tags else { return [] }
        return await CoverArt.candidates(
            releaseID: tags.musicBrainzReleaseID, releaseGroupID: tags.musicBrainzReleaseGroupID,
            artist: tags.albumArtist.isEmpty ? tags.artist : tags.albumArtist, album: tags.album,
            trackCount: max(tags.trackTotal, ids.count), includeAppleMusic: config.audioCoverFromAppleMusic)
    }

    func useCover(_ candidate: CoverCandidate, for ids: [UUID]) async throws {
        let (data, _) = try await CoverArt.download(candidate)
        guard let cover = TagEditorCovers.store(data, source: candidate.source) else {
            throw RipError.failed("The cover from \(candidate.source) could not be stored")
        }
        setCover(cover, for: ids)
    }

    func useCoverFile(_ file: URL, for ids: [UUID]) throws {
        let data = try Data(contentsOf: file)
        guard let cover = TagEditorCovers.store(data, source: "File") else {
            throw RipError.failed("\(file.lastPathComponent) is not an image")
        }
        setCover(cover, for: ids)
    }

    /// Saves the album's cover as cover.jpg (or the name from Settings) next to its files.
    @discardableResult
    func saveCoverFile(_ album: LibraryAlbum) throws -> URL? {
        guard let cover = summary(album).cover else { return nil }
        let name = config.audioCoverFileName.isEmpty ? "cover" : config.audioCoverFileName
        for ext in ["jpg", "png"] { try? FileManager.default.removeItem(at: album.folder.appendingPathComponent("\(name).\(ext)")) }
        let url = album.folder.appendingPathComponent("\(name).\(cover.fileExtension)")
        try FileManager.default.copyItem(at: cover.url, to: url)
        return url
    }
}

extension AudioTags {
    mutating func modify(_ change: (inout AudioTags) -> Void) { change(&self) }
}

/// Covers shown in the Tag Editor, stored once per image (an album's files usually share one cover).
enum TagEditorCovers {
    static var folder: URL { AppPaths.support.appendingPathComponent("tag-editor-covers", isDirectory: true) }

    static func clear() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Keeps JPEG and PNG as they are; other formats are converted, because players only understand those two.
    static func store(_ original: Data, source: String) -> CoverImage? {
        guard var info = CoverArt.imageInfo(original) else { return nil }
        var data = original
        if info.format != "png", data.prefix(2) != Data([0xFF, 0xD8]) {
            guard let jpeg = CoverArt.jpegData(original, maxPixels: max(info.width, info.height)),
                  let converted = CoverArt.imageInfo(jpeg) else { return nil }
            data = jpeg
            info = converted
        }
        let hash = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(hash).\(info.format == "png" ? "png" : "jpg")")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        }
        return CoverImage(path: url.path, width: info.width, height: info.height, bytes: data.count,
                          format: info.format, source: source)
    }
}
