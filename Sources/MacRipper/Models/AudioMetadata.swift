import Foundation

/// Album level tags of an audio CD beyond artist/album/year (which live on `Job`).
/// Decoding is lenient so fields added later never invalidate a saved job history.
struct AudioAlbumInfo: Codable, Hashable {
    var date = ""                    // release date, e.g. 2001-03-12
    var originalDate = ""            // first release of the release group
    var genre = ""
    var label = ""
    var catalogNumber = ""
    var barcode = ""
    var country = ""
    var media = ""                   // CD, Enhanced CD, …
    var discNumber = 1
    var discTotal = 1
    var compilation = false
    var releaseGroupID = ""
    var albumArtistID = ""
    var albumArtistSort = ""
    var comment = ""
    var cover: CoverImage?
    /// Set when tags were edited after the rip, so the UI can offer to rewrite the files.
    var tagsChangedAfterRip = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        originalDate = try c.decodeIfPresent(String.self, forKey: .originalDate) ?? ""
        genre = try c.decodeIfPresent(String.self, forKey: .genre) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        catalogNumber = try c.decodeIfPresent(String.self, forKey: .catalogNumber) ?? ""
        barcode = try c.decodeIfPresent(String.self, forKey: .barcode) ?? ""
        country = try c.decodeIfPresent(String.self, forKey: .country) ?? ""
        media = try c.decodeIfPresent(String.self, forKey: .media) ?? ""
        discNumber = try c.decodeIfPresent(Int.self, forKey: .discNumber) ?? 1
        discTotal = try c.decodeIfPresent(Int.self, forKey: .discTotal) ?? 1
        compilation = try c.decodeIfPresent(Bool.self, forKey: .compilation) ?? false
        releaseGroupID = try c.decodeIfPresent(String.self, forKey: .releaseGroupID) ?? ""
        albumArtistID = try c.decodeIfPresent(String.self, forKey: .albumArtistID) ?? ""
        albumArtistSort = try c.decodeIfPresent(String.self, forKey: .albumArtistSort) ?? ""
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        cover = try c.decodeIfPresent(CoverImage.self, forKey: .cover)
        tagsChangedAfterRip = try c.decodeIfPresent(Bool.self, forKey: .tagsChangedAfterRip) ?? false
    }
}

/// A cover image stored for a job, kept as the original file without recompression.
struct CoverImage: Codable, Hashable {
    var path: String                 // local copy in Application Support/covers
    var width: Int
    var height: Int
    var bytes: Int
    var format: String               // jpeg / png
    var source: String               // e.g. "Cover Art Archive", "Apple Music", "File"

    var url: URL { URL(fileURLWithPath: path) }
    var fileExtension: String { format == "png" ? "png" : "jpg" }
    var summary: String {
        "\(width) × \(height) px · \(format.uppercased()) · \(Int64(bytes).formatted(.byteCount(style: .file))) · \(source)"
    }
}

/// Per-track tags of an audio CD.
struct AudioTrackTags: Codable, Hashable {
    var artist = ""                  // empty = album artist
    var artistID = ""
    var recordingID = ""
    var releaseTrackID = ""
    var isrc = ""
    var composer = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        artistID = try c.decodeIfPresent(String.self, forKey: .artistID) ?? ""
        recordingID = try c.decodeIfPresent(String.self, forKey: .recordingID) ?? ""
        releaseTrackID = try c.decodeIfPresent(String.self, forKey: .releaseTrackID) ?? ""
        isrc = try c.decodeIfPresent(String.self, forKey: .isrc) ?? ""
        composer = try c.decodeIfPresent(String.self, forKey: .composer) ?? ""
    }
}

extension Job {
    /// MusicBrainz's special "Various Artists" artist.
    static let variousArtistsID = "89ad4ac3-39f7-470e-963a-56509c546377"
}
