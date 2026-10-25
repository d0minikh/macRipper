import Foundation
import AVFoundation

/// Everything written into an audio file. Field names follow MusicBrainz Picard's conventions.
struct AudioTags {
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

    struct EmbeddedCover {
        let data: Data
        let format: String           // jpeg / png
        let width: Int
        let height: Int
        var mimeType: String { format == "png" ? "image/png" : "image/jpeg" }
    }

    var year: String { String(date.prefix(4)) }

    /// Vorbis comment fields (FLAC), in Picard's naming.
    var vorbisFields: [(String, String)] {
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
        ].filter { !$0.1.isEmpty }
    }

    /// ffmpeg `-metadata` keys for ID3v2.4 (MP3). Unknown keys become TXXX frames named like Picard's.
    var id3Fields: [(String, String)] {
        [
            ("title", title), ("artist", artist), ("album", album), ("album_artist", albumArtist),
            ("TSO2", albumArtistSort), ("date", date), ("TDOR", originalDate),
            ("track", track > 0 ? (trackTotal > 0 ? "\(track)/\(trackTotal)" : "\(track)") : ""),
            ("disc", disc > 0 ? (discTotal > 0 ? "\(disc)/\(discTotal)" : "\(disc)") : ""),
            ("genre", genre), ("composer", composer), ("comment", comment), ("publisher", label),
            ("TSRC", isrc), ("TMED", media), ("compilation", compilation ? "1" : ""),
            ("CATALOGNUMBER", catalogNumber), ("BARCODE", barcode), ("MusicBrainz Album Release Country", country),
            ("MusicBrainz Album Id", musicBrainzReleaseID), ("MusicBrainz Release Group Id", musicBrainzReleaseGroupID),
            ("MusicBrainz Album Artist Id", musicBrainzAlbumArtistID), ("MusicBrainz Artist Id", musicBrainzArtistID),
            ("MusicBrainz Release Track Id", musicBrainzReleaseTrackID), ("MusicBrainz Disc Id", musicBrainzDiscID),
        ].filter { !$0.1.isEmpty }
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

        if format == .mp3 {
            guard let ffmpeg = Tools.ffmpeg(config) else { throw RipError.missingTool("ffmpeg for MP3 (brew install ffmpeg)") }
            // MP3 tags (ID3v2.4) are written by ffmpeg while encoding.
            try await Self.ffmpegWriteMP3(ffmpeg, input: input, output: output, tags: tags,
                                          codec: ["-c:a", "libmp3lame", "-q:a", "0"], runner: runner, log: log)
            return
        }

        if let ffmpeg = Tools.ffmpeg(config), format != .wav {
            var args = ["-y", "-hide_banner", "-loglevel", "error", "-i", input.path, "-map", "0:a", "-map_metadata", "-1"]
            switch format {
            case .flac: args += ["-c:a", "flac", "-compression_level", "8"]
            case .alac: args += ["-c:a", "alac"]
            case .aac: args += ["-c:a", "aac", "-b:a", "\(config.aacBitrate)"]
            case .mp3, .wav: break
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
    static func writeTags(_ tags: AudioTags, to file: URL, config: AppConfig, runner: ProcessRunner,
                          log: JobLogger?) async throws {
        switch file.pathExtension.lowercased() {
        case "flac": try FLACTagger.write(tags, to: file)
        case "m4a": try await M4ATagger.write(tags, to: file)
        case "mp3":
            guard let ffmpeg = Tools.ffmpeg(config) else { throw RipError.missingTool("ffmpeg to tag MP3 files") }
            let tmp = file.deletingLastPathComponent().appendingPathComponent(".retag-\(UUID().uuidString).mp3")
            do {
                try await ffmpegWriteMP3(ffmpeg, input: file, output: tmp, tags: tags, codec: ["-c:a", "copy"],
                                         runner: runner, log: log)
                _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                throw error
            }
        default: break                // WAV has no widely supported tags
        }
    }

    private static func ffmpegWriteMP3(_ ffmpeg: String, input: URL, output: URL, tags: AudioTags, codec: [String],
                                       runner: ProcessRunner, log: JobLogger?) async throws {
        var args = ["-y", "-hide_banner", "-loglevel", "error", "-i", input.path]
        var coverFile: URL?
        if let cover = tags.cover {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("macripper-cover-\(UUID().uuidString).\(cover.format == "png" ? "png" : "jpg")")
            try cover.data.write(to: url)
            coverFile = url
            args += ["-i", url.path]
        }
        defer { coverFile.map { try? FileManager.default.removeItem(at: $0) } }
        args += ["-map", "0:a"] + codec + ["-map_metadata", "-1", "-id3v2_version", "4", "-write_id3v1", "1"]
        if coverFile != nil {
            args += ["-map", "1:v", "-c:v", "copy", "-disposition:v", "attached_pic",
                     "-metadata:s:v", "title=Album cover", "-metadata:s:v", "comment=Cover (front)"]
        }
        for (key, value) in tags.id3Fields { args += ["-metadata", "\(key)=\(value)"] }
        try await runner.run(ffmpeg, args + ["-f", "mp3", output.path], log: log)
    }
}

/// Writes a Vorbis comment and a front cover picture block into a FLAC file.
enum FLACTagger {
    static func write(_ tags: AudioTags, to url: URL) throws {
        var data = try Data(contentsOf: url)
        guard data.count > 8, data.prefix(4) == Data("fLaC".utf8) else { return }

        // Collect existing metadata blocks, dropping old comments/pictures and padding.
        var pos = 4
        var blocks: [(type: UInt8, body: Data)] = []
        var last = false
        while !last, pos + 4 <= data.count {
            let header = data[data.startIndex + pos]
            last = header & 0x80 != 0
            let type = header & 0x7F
            let len = Int(data[pos + 1]) << 16 | Int(data[pos + 2]) << 8 | Int(data[pos + 3])
            guard pos + 4 + len <= data.count else { throw RipError.failed("\(url.lastPathComponent) is not a valid FLAC file") }
            let body = data.subdata(in: (pos + 4)..<(pos + 4 + len))
            if type != 4, type != 6, type != 1 { blocks.append((type, body)) }
            pos += 4 + len
        }
        let audio = data.subdata(in: pos..<data.count)

        blocks.append((4, vorbisComment(tags)))
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
        try data.write(to: url, options: .atomic)
    }

    private static func le32(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)])
    }

    private static func be32(_ v: Int) -> Data {
        Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }

    static func vorbisComment(_ t: AudioTags) -> Data {
        let vendor = Data("MacRipper".utf8)
        let fields = t.vorbisFields.map { Data("\($0.0)=\($0.1)".utf8) }
        var d = le32(vendor.count) + vendor + le32(fields.count)
        for f in fields { d += le32(f.count) + f }
        return d
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

/// Writes iTunes metadata to ALAC/AAC files via a passthrough export.
enum M4ATagger {
    static func write(_ tags: AudioTags, to url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem? {
            guard !value.isEmpty else { return nil }
            let i = AVMutableMetadataItem()
            i.identifier = id
            i.value = value as NSString
            return i
        }
        func data(_ id: AVMetadataIdentifier, _ value: Data, type: CFString) -> AVMetadataItem {
            let i = AVMutableMetadataItem()
            i.identifier = id
            i.value = value as NSData
            i.dataType = type as String
            return i
        }
        var items = [
            item(.iTunesMetadataSongName, tags.title),
            item(.iTunesMetadataArtist, tags.artist),
            item(.iTunesMetadataAlbumArtist, tags.albumArtist),
            item(.iTunesMetadataAlbum, tags.album),
            item(.iTunesMetadataReleaseDate, tags.date),
            item(.iTunesMetadataUserGenre, tags.genre),
            item(.iTunesMetadataComposer, tags.composer),
            item(.iTunesMetadataUserComment, tags.comment),
            item(.iTunesMetadataRecordCompany, tags.label),
        ].compactMap { $0 }
        // trkn: 2 bytes padding, track, total, 2 bytes padding. disk: padding, disc, total.
        func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        if tags.track > 0 {
            items.append(data(.iTunesMetadataTrackNumber, Data([0, 0] + be16(tags.track) + be16(tags.trackTotal) + [0, 0]),
                              type: kCMMetadataBaseDataType_RawData))
        }
        if tags.disc > 0 {
            items.append(data(.iTunesMetadataDiscNumber, Data([0, 0] + be16(tags.disc) + be16(tags.discTotal)),
                              type: kCMMetadataBaseDataType_RawData))
        }
        if tags.compilation {
            items.append(data(.iTunesMetadataDiscCompilation, Data([1]), type: kCMMetadataBaseDataType_UInt8))
        }
        if let cover = tags.cover {
            items.append(data(.iTunesMetadataCoverArt, cover.data,
                              type: cover.format == "png" ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG))
        }

        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tag-\(UUID().uuidString).m4a")
        export.metadata = items
        do {
            try await export.export(to: tmp, as: .m4a)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw RipError.failed("Could not write tags to \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
