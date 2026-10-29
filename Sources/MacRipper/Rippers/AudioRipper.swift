import Foundation
import AVFoundation

/// Everything written into an audio file. Field names follow MusicBrainz Picard's conventions.
struct AudioTags: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var albumArtist = ""
    var date = ""                    // YYYY or YYYY-MM-DD
    var track = 0
    var trackTotal = 0
    var disc = 1
    var discTotal = 1
    var genre = ""
    var composer = ""
    var comment = ""
    var label = ""
    var catalogNumber = ""
    var barcode = ""
    var isrc = ""
    var country = ""
    var media = ""
    var originalDate = ""
    var albumArtistSort = ""
    var compilation = false
    var musicBrainzReleaseID = ""
    var musicBrainzReleaseGroupID = ""
    var musicBrainzAlbumArtistID = ""
    var musicBrainzArtistID = ""
    var musicBrainzRecordingID = ""
    var musicBrainzReleaseTrackID = ""
    var musicBrainzDiscID = ""
    var cover: EmbeddedCover?

    struct EmbeddedCover: Equatable {
        let data: Data
        let format: String           // jpeg / png
        let width: Int
        let height: Int
        var mimeType: String { format == "png" ? "image/png" : "image/jpeg" }
    }

    var year: String { String(date.prefix(4)) }

    /// Vorbis comment fields (FLAC), in Picard's naming.
    var vorbisFields: [(String, String)] { vorbisFieldsIncludingEmpty.filter { !$0.1.isEmpty } }

    /// Every Vorbis field MacRipper manages, empty ones included, so a rewrite can clear them.
    var vorbisFieldsIncludingEmpty: [(String, String)] {
        [
            ("TITLE", title), ("ARTIST", artist), ("ALBUM", album), ("ALBUMARTIST", albumArtist),
            ("ALBUMARTISTSORT", albumArtistSort), ("DATE", date), ("ORIGINALDATE", originalDate),
            ("TRACKNUMBER", track > 0 ? "\(track)" : ""), ("TRACKTOTAL", trackTotal > 0 ? "\(trackTotal)" : ""),
            ("TOTALTRACKS", trackTotal > 0 ? "\(trackTotal)" : ""),
            ("DISCNUMBER", disc > 0 ? "\(disc)" : ""), ("DISCTOTAL", discTotal > 0 ? "\(discTotal)" : ""),
            ("TOTALDISCS", discTotal > 0 ? "\(discTotal)" : ""),
            ("GENRE", genre), ("COMPOSER", composer), ("COMMENT", comment), ("LABEL", label),
            ("CATALOGNUMBER", catalogNumber), ("BARCODE", barcode), ("ISRC", isrc), ("RELEASECOUNTRY", country),
            ("MEDIA", media), ("COMPILATION", compilation ? "1" : ""),
            ("MUSICBRAINZ_ALBUMID", musicBrainzReleaseID), ("MUSICBRAINZ_RELEASEGROUPID", musicBrainzReleaseGroupID),
            ("MUSICBRAINZ_ALBUMARTISTID", musicBrainzAlbumArtistID), ("MUSICBRAINZ_ARTISTID", musicBrainzArtistID),
            ("MUSICBRAINZ_TRACKID", musicBrainzRecordingID), ("MUSICBRAINZ_RELEASETRACKID", musicBrainzReleaseTrackID),
            ("MUSICBRAINZ_DISCID", musicBrainzDiscID),
        ]
    }
}

/// Rips audio CDs. macOS exposes every track of a mounted audio CD as an AIFF file
/// (cddafs), so ripping means reading those files and encoding them (ARM: abcde).
struct AudioRipper {
    let config: AppConfig

    /// AIFF track files of the mounted CD, ordered by track number.
    static func trackFiles(mountPoint: String) -> [Int: URL] {
        let dir = URL(fileURLWithPath: mountPoint)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [Int: URL] = [:]
        for file in files where file.pathExtension.lowercased() == "aiff" {
            let digits = file.lastPathComponent.prefix { $0.isNumber }
            if let n = Int(digits) { out[n] = file }
        }
        return out
    }

    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters)
        let cleaned = s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.hasPrefix(".") ? "_" + cleaned.dropFirst() : cleaned
        guard !trimmed.isEmpty else { return "Unknown" }
        // File names may have at most 255 bytes; CJK titles take 3 bytes per character.
        var result = ""
        for ch in trimmed {
            if result.utf8.count + ch.utf8.count > 200 { break }
            result.append(ch)
        }
        return result
    }

    /// Placeholders: {artist} (album artist), {albumartist}, {trackartist}, {album}, {year}, {genre}, {disc}, {track}, {title}.
    static func expand(_ pattern: String, _ tags: AudioTags) -> String {
        let albumArtist = tags.albumArtist.isEmpty ? tags.artist : tags.albumArtist
        return pattern
            .replacingOccurrences(of: "{artist}", with: sanitize(albumArtist))
            .replacingOccurrences(of: "{albumartist}", with: sanitize(albumArtist))
            .replacingOccurrences(of: "{trackartist}", with: sanitize(tags.artist))
            .replacingOccurrences(of: "{album}", with: sanitize(tags.album))
            .replacingOccurrences(of: "{genre}", with: sanitize(tags.genre))
            .replacingOccurrences(of: "{year}", with: tags.year.isEmpty ? "----" : tags.year)
            .replacingOccurrences(of: "{disc}", with: "\(max(tags.disc, 1))")
            .replacingOccurrences(of: "{track}", with: String(format: "%02d", tags.track))
            .replacingOccurrences(of: "{title}", with: sanitize(tags.title))
            .replacingOccurrences(of: " (----)", with: "")
            .replacingOccurrences(of: "----", with: "")
    }

    /// File name pattern for a disc; multi-disc albums get a disc prefix so tracks of different discs never collide.
    static func filePattern(_ pattern: String, discTotal: Int) -> String {
        discTotal > 1 && !pattern.contains("{disc}") ? "{disc}-" + pattern : pattern
    }

    func encode(_ input: URL, to output: URL, tags: AudioTags, runner: ProcessRunner, log: JobLogger?) async throws {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output)
        let format = config.audioFormat

        if format == .mp3, Tools.ffmpeg(config) == nil {
            throw RipError.missingTool("ffmpeg for MP3 (brew install ffmpeg)")
        }
        if let ffmpeg = Tools.ffmpeg(config), format != .wav {
            var args = ["-y", "-hide_banner", "-loglevel", "error", "-i", input.path, "-map", "0:a", "-map_metadata", "-1"]
            switch format {
            case .flac: args += ["-c:a", "flac", "-compression_level", "8"]
            case .alac: args += ["-c:a", "alac"]
            case .aac: args += ["-c:a", "aac", "-b:a", "\(config.aacBitrate)"]
            case .mp3: args += ["-c:a", "libmp3lame", "-q:a", "0"]
            case .wav: break
            }
            try await runner.run(ffmpeg, args + [output.path], log: log)
        } else {
            let afArgs: [String]
            switch format {
            case .flac: afArgs = ["-f", "flac", "-d", "flac"]
            case .alac: afArgs = ["-f", "m4af", "-d", "alac"]
            case .aac: afArgs = ["-f", "m4af", "-d", "aac", "-b", "\(config.aacBitrate)", "-q", "127", "-s", "2"]
            case .wav: afArgs = ["-f", "WAVE", "-d", "LEI16"]
            case .mp3: afArgs = []
            }
            try await runner.run("/usr/bin/afconvert", afArgs + [input.path, output.path], log: log)
        }
        try await Self.writeTags(tags, to: output, config: config, runner: runner, log: log)
    }

    /// Writes (or rewrites) all tags and the cover of an existing file.
    /// `preservingOtherTags` keeps tags MacRipper does not manage (lyrics, ReplayGain …); `keepExistingCover` keeps
    /// the embedded cover when `tags.cover` is nil instead of removing it.
    static func writeTags(_ tags: AudioTags, to file: URL, config: AppConfig, runner: ProcessRunner,
                          log: JobLogger?, preservingOtherTags: Bool = false, keepExistingCover: Bool = false) async throws {
        switch file.pathExtension.lowercased() {
        case "flac":
            try FLACTagger.write(tags, to: file, preservingOtherTags: preservingOtherTags, keepExistingCover: keepExistingCover)
        case "m4a":
            try MP4Tag.write(tags, to: file, preservingOtherTags: preservingOtherTags, keepExistingCover: keepExistingCover)
        case "mp3":
            try ID3Tag.write(tags, to: file, preservingOtherTags: preservingOtherTags, keepExistingCover: keepExistingCover)
        default: break                // WAV has no widely supported tags
        }
    }
}

/// Writes a Vorbis comment and a front cover picture block into a FLAC file.
enum FLACTagger {
    /// Field names MacRipper manages, including the aliases other taggers use for them. When other tags are
    /// preserved, these are replaced and everything else is kept.
    static let managedFields: Set<String> = Set(AudioTags().vorbisFieldsIncludingEmpty.map(\.0))
        .union(["ALBUM ARTIST", "ORIGINALYEAR", "YEAR", "DESCRIPTION", "ORGANIZATION", "PUBLISHER"])

    static func write(_ tags: AudioTags, to url: URL, preservingOtherTags: Bool = false,
                      keepExistingCover: Bool = false) throws {
        var data = try Data(contentsOf: url)
        guard data.count > 8, data.prefix(4) == Data("fLaC".utf8) else { return }

        // Collect existing metadata blocks, dropping old comments/pictures and padding.
        var pos = 4
        var blocks: [(type: UInt8, body: Data)] = []
        var keptFields: [String] = []
        var vendor = "MacRipper"
        var last = false
        while !last, pos + 4 <= data.count {
            let header = data[data.startIndex + pos]
            last = header & 0x80 != 0
            let type = header & 0x7F
            let len = Int(data[pos + 1]) << 16 | Int(data[pos + 2]) << 8 | Int(data[pos + 3])
            guard pos + 4 + len <= data.count else { throw RipError.failed("\(url.lastPathComponent) is not a valid FLAC file") }
            let body = data.subdata(in: (pos + 4)..<(pos + 4 + len))
            switch type {
            case 4 where preservingOtherTags:
                if let comment = parseVorbisComment(body) {
                    vendor = comment.vendor
                    keptFields += comment.fields.filter { !managedFields.contains($0.key.uppercased()) }
                        .map { "\($0.key)=\($0.value)" }
                }
            case 6:
                // Front covers (and untyped pictures) are replaced; back covers, booklets … stay when preserving.
                let pictureType = body.count >= 4 ? Int(body[body.startIndex]) << 24 | Int(body[body.startIndex + 1]) << 16
                    | Int(body[body.startIndex + 2]) << 8 | Int(body[body.startIndex + 3]) : 0
                let isFront = pictureType == 3 || pictureType == 0
                if isFront ? (keepExistingCover && tags.cover == nil) : preservingOtherTags { blocks.append((type, body)) }
            case 1, 4: break
            default: blocks.append((type, body))
            }
            pos += 4 + len
        }
        let audio = data.subdata(in: pos..<data.count)

        blocks.append((4, vorbisComment(tags, vendor: vendor, extraFields: keptFields)))
        if let cover = tags.cover {
            let picture = picture(cover)
            // A metadata block length is 24 bit (16 MB); larger covers are left out rather than corrupting the file.
            if picture.count < 1 << 24 { blocks.append((6, picture)) }
        }
        // Some padding lets other taggers edit in place later.
        blocks.append((1, Data(count: 4096)))

        data = Data("fLaC".utf8)
        for (i, block) in blocks.enumerated() {
            let isLast = i == blocks.count - 1
            data.append((isLast ? 0x80 : 0) | block.type)
            let len = block.body.count
            data.append(contentsOf: [UInt8(len >> 16 & 0xFF), UInt8(len >> 8 & 0xFF), UInt8(len & 0xFF)])
            data.append(block.body)
        }
        data.append(audio)
        try FileWriting.replace(url, with: data)
    }

    private static func le32(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)])
    }

    private static func be32(_ v: Int) -> Data {
        Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }

    static func vorbisComment(_ t: AudioTags, vendor: String = "MacRipper", extraFields: [String] = []) -> Data {
        let vendor = Data(vendor.utf8)
        let fields = t.vorbisFields.map { Data("\($0.0)=\($0.1)".utf8) } + extraFields.map { Data($0.utf8) }
        var d = le32(vendor.count) + vendor + le32(fields.count)
        for f in fields { d += le32(f.count) + f }
        return d
    }

    /// Vendor string and fields of a VORBIS_COMMENT block, in file order.
    static func parseVorbisComment(_ body: Data) -> (vendor: String, fields: [(key: String, value: String)])? {
        let d = [UInt8](body)
        var pos = 0
        func le32() -> Int? {
            guard pos + 4 <= d.count else { return nil }
            defer { pos += 4 }
            return Int(d[pos]) | Int(d[pos + 1]) << 8 | Int(d[pos + 2]) << 16 | Int(d[pos + 3]) << 24
        }
        func string(_ length: Int) -> String? {
            guard length >= 0, pos + length <= d.count else { return nil }
            defer { pos += length }
            return String(decoding: d[pos..<(pos + length)], as: UTF8.self)
        }
        guard let vendorLength = le32(), let vendor = string(vendorLength), let count = le32() else { return nil }
        var fields: [(key: String, value: String)] = []
        for _ in 0..<count {
            guard let length = le32(), let field = string(length) else { break }
            guard let eq = field.firstIndex(of: "=") else { continue }
            fields.append((String(field[..<eq]), String(field[field.index(after: eq)...])))
        }
        return (vendor, fields)
    }

    /// METADATA_BLOCK_PICTURE, type 3 = front cover.
    static func picture(_ cover: AudioTags.EmbeddedCover) -> Data {
        let mime = Data(cover.mimeType.utf8)
        let description = Data("Cover (front)".utf8)
        var block = be32(3)
        block.append(be32(mime.count))
        block.append(mime)
        block.append(be32(description.count))
        block.append(description)
        block.append(be32(cover.width))
        block.append(be32(cover.height))
        block.append(be32(24))           // color depth
        block.append(be32(0))            // not an indexed-color image
        block.append(be32(cover.data.count))
        block.append(cover.data)
        return block
    }
}
