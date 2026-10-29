import Foundation

/// An existing music file loaded into the Tag Editor: the tags as read from disk and the edited tags.
struct LibraryTrack: Identifiable, Equatable {
    let id: UUID
    var url: URL
    var info: AudioFileInfo
    /// Tags as last read from the file. The embedded cover is kept apart in `originalCover`.
    var original: AudioTags
    var tags: AudioTags
    var originalCover: CoverImage?
    var cover: CoverImage?
    var error: String?

    var isModified: Bool { tags != original || cover != originalCover }
    var coverChanged: Bool { cover != originalCover }
    var fileName: String { url.lastPathComponent }
    var displayTitle: String { tags.title.isEmpty ? url.deletingPathExtension().lastPathComponent : tags.title }

    /// Disc and track position for sorting: disc, track, then file name for untagged files.
    static func areInOrder(_ a: LibraryTrack, _ b: LibraryTrack) -> Bool {
        let da = max(a.tags.disc, 1), db = max(b.tags.disc, 1)
        if da != db { return da < db }
        let ta = a.tags.track == 0 ? Int.max : a.tags.track, tb = b.tags.track == 0 ? Int.max : b.tags.track
        if ta != tb { return ta < tb }
        return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
    }
}

/// Files that belong together: the same album tag in the same folder. Songs without an album tag form a group of
/// their own per folder. Albums keep their files when tags are edited, so a renamed album stays one entry.
struct LibraryAlbum: Identifiable, Equatable {
    let id: UUID
    let folder: URL
    /// Lowercased album tag the files had when they were added; files added later join an album with the same key.
    let albumKey: String
    var trackIDs: [UUID]
}

/// What the Tag Editor shows for an album: values common to all its files, or a neutral fallback.
struct LibraryAlbumSummary {
    var title: String
    var artist: String
    var year: String
    var genre: String
    var cover: CoverImage?
    var trackCount: Int
    var modifiedCount: Int
    var errorCount: Int
    var formats: String
    var duration: Double
    var hasAlbumTag: Bool
}

/// A track of a MusicBrainz release, addressed by disc and position.
struct ReleaseTrackRef: Hashable {
    let disc: Int
    let number: Int
}

/// Assigns files to the tracks of a MusicBrainz release, the way a person would: same title and position first,
/// then the same title, then the same position, then the closest length.
enum ReleaseMatcher {
    struct File {
        let id: UUID
        let disc: Int
        let track: Int
        let title: String
        let duration: Double
    }

    static func match(_ files: [File], to release: AudioRelease) -> [UUID: ReleaseTrackRef] {
        let media = release.discTracks.isEmpty ? [release.discNumber: release.tracks] : release.discTracks
        var free: [ReleaseTrackRef: AudioTrackInfo] = [:]
        for (disc, tracks) in media { for track in tracks { free[ReleaseTrackRef(disc: disc, number: track.number)] = track } }
        // With a single medium, files without a disc number belong to it.
        let onlyDisc = media.count == 1 ? media.keys.first : nil
        var result: [UUID: ReleaseTrackRef] = [:]
        var open = files

        func assign(_ pass: (File) -> ReleaseTrackRef?) {
            open = open.filter { file in
                guard let ref = pass(file), free[ref] != nil else { return true }
                free[ref] = nil
                result[file.id] = ref
                return false
            }
        }
        func disc(of file: File) -> Int { file.disc > 0 ? file.disc : (onlyDisc ?? 1) }
        func sameTitle(_ file: File, _ track: AudioTrackInfo) -> Bool {
            let a = CoverArt.normalized(file.title), b = CoverArt.normalized(track.title)
            return !a.isEmpty && a == b
        }

        // 1. Title and position agree.
        assign { file in
            let ref = ReleaseTrackRef(disc: disc(of: file), number: file.track)
            return free[ref].map { sameTitle(file, $0) } == true ? ref : nil
        }
        // 2. The title matches exactly one free track.
        assign { file in
            let hits = free.filter { sameTitle(file, $0.value) }
            return hits.count == 1 ? hits.first?.key : nil
        }
        // 3. The position exists on the release.
        assign { file in file.track > 0 ? ReleaseTrackRef(disc: disc(of: file), number: file.track) : nil }
        // 4. The length is within three seconds of exactly one free track.
        assign { file in
            guard file.duration > 0 else { return nil }
            let hits = free.filter { $0.value.length > 0 && abs(Double($0.value.length) - file.duration) <= 3 }
            return hits.count == 1 ? hits.first?.key : nil
        }
        return result
    }

    /// "1-03 · Title (3:45)" for pickers.
    static func label(_ ref: ReleaseTrackRef, _ track: AudioTrackInfo, multiDisc: Bool) -> String {
        let position = multiDisc ? "\(ref.disc)-\(String(format: "%02d", ref.number))" : String(format: "%02d", ref.number)
        let length = track.length > 0 ? " (\(track.length / 60):\(String(format: "%02d", track.length % 60)))" : ""
        return "\(position) · \(track.title)\(length)"
    }
}
