import Foundation
import AVFoundation

/// Technical properties of an audio file, shown in the Tag Editor's inspector.
struct AudioFileInfo: Equatable {
    var format = ""                  // FLAC, ALAC, AAC, MP3
    var duration: Double = 0         // seconds
    var sampleRate: Double = 0       // Hz
    var bitDepth = 0                 // 0 = not applicable (lossy)
    var channels = 0
    var bitrate = 0                  // average bits per second
    var fileSize: Int64 = 0

    var summary: String {
        var parts: [String] = []
        if sampleRate > 0 { parts.append("\((sampleRate / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz") }
        if bitDepth > 0 { parts.append("\(bitDepth) bit") }
        switch channels {
        case 1: parts.append("Mono")
        case 2: parts.append("Stereo")
        case 0: break
        default: parts.append("\(channels) channels")
        }
        if bitrate > 0 { parts.append("\(bitrate / 1000) kbps") }
        return parts.joined(separator: " · ")
    }
}

/// Tags, embedded cover and properties read from an existing audio file.
struct AudioFileContents {
    var tags = AudioTags()
    var cover: Data?
    var info = AudioFileInfo()
}

/// Reads tags of existing music files for the Tag Editor. The tags of every format are parsed directly
/// (`FLACTagger`, `ID3Tag`, `MP4Tag`); AVFoundation only measures the audio of MP3 and M4A files. Field names of
/// every format are mapped to the Vorbis names `AudioTags` writes, so the readers understand files written by
/// MacRipper, Picard, iTunes/Music and ffmpeg alike.
enum TagReader {
    static let supportedExtensions: Set<String> = ["flac", "m4a", "mp3"]

    static func isSupported(_ url: URL) -> Bool { supportedExtensions.contains(url.pathExtension.lowercased()) }

    static func read(_ url: URL) async throws -> AudioFileContents {
        var contents: AudioFileContents
        switch url.pathExtension.lowercased() {
        case "flac": contents = try readFLAC(url)
        case "m4a", "mp3": contents = try await readMP3OrM4A(url)
        default: throw RipError.failed("\(url.lastPathComponent) is not a supported audio file")
        }
        contents.info.fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if contents.info.bitrate == 0, contents.info.duration > 0 {
            contents.info.bitrate = Int(Double(contents.info.fileSize * 8) / contents.info.duration)
        }
        return contents
    }

    // MARK: Field mapping

    /// Applies one tag, named in Vorbis style (TITLE, TRACKNUMBER …) or by a known alias, to `tags`.
    /// Returns false for fields `AudioTags` has no place for.
    @discardableResult
    static func apply(_ name: String, _ rawValue: String, to tags: inout AudioTags) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        func append(_ field: inout String) {
            // Repeated fields (two ARTIST comments …) are shown together, as most players do.
            field = field.isEmpty ? value : (field == value || value.isEmpty ? field : "\(field); \(value)")
        }
        switch name.uppercased() {
        case "TITLE": append(&tags.title)
        case "ARTIST": append(&tags.artist)
        case "ALBUM": append(&tags.album)
        case "ALBUMARTIST", "ALBUM ARTIST": append(&tags.albumArtist)
        case "ALBUMARTISTSORT": tags.albumArtistSort = value
        case "DATE", "YEAR": if tags.date.isEmpty || value.count > tags.date.count { tags.date = value }
        case "ORIGINALDATE": tags.originalDate = value
        case "ORIGINALYEAR": if tags.originalDate.isEmpty { tags.originalDate = value }
        case "TRACKNUMBER":
            let (number, total) = numberPair(value)
            tags.track = number
            if total > 0 { tags.trackTotal = total }
        case "TRACKTOTAL", "TOTALTRACKS": tags.trackTotal = Int(value) ?? tags.trackTotal
        case "DISCNUMBER":
            let (number, total) = numberPair(value)
            tags.disc = number
            if total > 0 { tags.discTotal = total }
        case "DISCTOTAL", "TOTALDISCS": tags.discTotal = Int(value) ?? tags.discTotal
        case "GENRE": append(&tags.genre)
        case "COMPOSER": append(&tags.composer)
        case "COMMENT", "DESCRIPTION": if tags.comment.isEmpty { tags.comment = value }
        case "LABEL", "ORGANIZATION", "PUBLISHER": if tags.label.isEmpty { tags.label = value }
        case "CATALOGNUMBER": tags.catalogNumber = value
        case "BARCODE": tags.barcode = value
        case "ISRC": tags.isrc = value
        case "RELEASECOUNTRY": tags.country = value
        case "MEDIA": tags.media = value
        case "COMPILATION": tags.compilation = value == "1" || value.lowercased() == "true"
        case "MUSICBRAINZ_ALBUMID": tags.musicBrainzReleaseID = value
        case "MUSICBRAINZ_RELEASEGROUPID": tags.musicBrainzReleaseGroupID = value
        case "MUSICBRAINZ_ALBUMARTISTID": tags.musicBrainzAlbumArtistID = value
        case "MUSICBRAINZ_ARTISTID": tags.musicBrainzArtistID = value
        case "MUSICBRAINZ_TRACKID": tags.musicBrainzRecordingID = value
        case "MUSICBRAINZ_RELEASETRACKID": tags.musicBrainzReleaseTrackID = value
        case "MUSICBRAINZ_DISCID": tags.musicBrainzDiscID = value
        default: return false
        }
        return true
    }

    /// "3", "3/12" or "03 of 12" → (3, 12).
    static func numberPair(_ value: String) -> (Int, Int) {
        let numbers = value.split { !$0.isNumber }.compactMap { Int($0) }
        return (numbers.first ?? 0, numbers.count > 1 ? numbers[1] : 0)
    }

    /// ID3v2 frames (and the TXXX descriptions Picard and ffmpeg use) → Vorbis names.
    static let id3Names: [String: String] = [
        "TIT2": "TITLE", "TPE1": "ARTIST", "TALB": "ALBUM", "TPE2": "ALBUMARTIST", "TSO2": "ALBUMARTISTSORT",
        "TDRC": "DATE", "TYER": "DATE", "TDOR": "ORIGINALDATE", "TORY": "ORIGINALYEAR", "TRCK": "TRACKNUMBER",
        "TPOS": "DISCNUMBER", "TCON": "GENRE", "TCOM": "COMPOSER", "COMM": "COMMENT", "TPUB": "LABEL",
        "TSRC": "ISRC", "TMED": "MEDIA", "TCMP": "COMPILATION",
        "COMMENT": "COMMENT", "CATALOGNUMBER": "CATALOGNUMBER", "BARCODE": "BARCODE",
        "MUSICBRAINZ ALBUM ID": "MUSICBRAINZ_ALBUMID", "MUSICBRAINZ RELEASE GROUP ID": "MUSICBRAINZ_RELEASEGROUPID",
        "MUSICBRAINZ ALBUM ARTIST ID": "MUSICBRAINZ_ALBUMARTISTID", "MUSICBRAINZ ARTIST ID": "MUSICBRAINZ_ARTISTID",
        "MUSICBRAINZ RELEASE TRACK ID": "MUSICBRAINZ_RELEASETRACKID", "MUSICBRAINZ DISC ID": "MUSICBRAINZ_DISCID",
        "MUSICBRAINZ TRACK ID": "MUSICBRAINZ_TRACKID", "MUSICBRAINZ ALBUM RELEASE COUNTRY": "RELEASECOUNTRY",
        "ORIGINALYEAR": "ORIGINALYEAR", "ORIGINALDATE": "ORIGINALDATE",
    ]

    // MARK: FLAC

    /// Reads only the metadata blocks; the audio frames after them are never loaded.
    static func readFLAC(_ url: URL) throws -> AudioFileContents {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data("fLaC".utf8) else {
            throw RipError.failed("\(url.lastPathComponent) is not a valid FLAC file")
        }
        var contents = AudioFileContents()
        contents.info.format = "FLAC"
        var frontCover: Data?
        var anyPicture: Data?
        var last = false
        while !last {
            guard let header = try handle.read(upToCount: 4), header.count == 4 else { break }
            let bytes = [UInt8](header)
            last = bytes[0] & 0x80 != 0
            let type = bytes[0] & 0x7F
            let length = Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            guard let body = try handle.read(upToCount: length), body.count == length else {
                throw RipError.failed("\(url.lastPathComponent) is not a valid FLAC file")
            }
            switch type {
            case 0: parseStreamInfo(body, into: &contents.info)
            case 4:
                for field in FLACTagger.parseVorbisComment(body)?.fields ?? [] {
                    apply(field.key, field.value, to: &contents.tags)
                }
            case 6:
                if let picture = parsePicture(body) {
                    if picture.type == 3, frontCover == nil { frontCover = picture.data }
                    if anyPicture == nil { anyPicture = picture.data }
                }
            default: break
            }
        }
        contents.cover = frontCover ?? anyPicture
        return contents
    }

    static func parseStreamInfo(_ body: Data, into info: inout AudioFileInfo) {
        let b = [UInt8](body)
        guard b.count >= 18 else { return }
        let sampleRate = Int(b[10]) << 12 | Int(b[11]) << 4 | Int(b[12]) >> 4
        let channels = Int(b[12] >> 1 & 0x07) + 1
        let bitDepth = (Int(b[12] & 0x01) << 4 | Int(b[13]) >> 4) + 1
        var samples = Int(b[13] & 0x0F)
        for i in 14...17 { samples = samples << 8 | Int(b[i]) }
        info.sampleRate = Double(sampleRate)
        info.channels = channels
        info.bitDepth = bitDepth
        if sampleRate > 0 { info.duration = Double(samples) / Double(sampleRate) }
    }

    static func parsePicture(_ body: Data) -> (type: Int, data: Data)? {
        let b = [UInt8](body)
        var pos = 0
        func be32() -> Int? {
            guard pos + 4 <= b.count else { return nil }
            defer { pos += 4 }
            return Int(b[pos]) << 24 | Int(b[pos + 1]) << 16 | Int(b[pos + 2]) << 8 | Int(b[pos + 3])
        }
        guard let type = be32(), let mimeLength = be32() else { return nil }
        pos += mimeLength
        guard let descriptionLength = be32() else { return nil }
        pos += descriptionLength + 16          // width, height, depth, colors
        guard let length = be32(), pos + length <= b.count else { return nil }
        return (type, Data(b[pos..<(pos + length)]))
    }

    // MARK: MP3 and M4A

    static func readMP3OrM4A(_ url: URL) async throws -> AudioFileContents {
        let asset = AVURLAsset(url: url)
        var contents = AudioFileContents()
        let duration = try await asset.load(.duration)
        contents.info.duration = duration.isNumeric ? duration.seconds : 0
        if let track = try await asset.loadTracks(withMediaType: .audio).first {
            let rate = try? await track.load(.estimatedDataRate)
            contents.info.bitrate = Int(rate ?? 0)
            if let description = try? await track.load(.formatDescriptions).first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                contents.info.sampleRate = asbd.mSampleRate
                contents.info.channels = Int(asbd.mChannelsPerFrame)
                switch asbd.mFormatID {
                case kAudioFormatAppleLossless:
                    contents.info.format = "ALAC"
                    // The ALAC format flags encode the source bit depth: 1 = 16, 2 = 20, 3 = 24, 4 = 32 bit.
                    contents.info.bitDepth = [1: 16, 2: 20, 3: 24, 4: 32][Int(asbd.mFormatFlags)] ?? 0
                case kAudioFormatMPEGLayer3: contents.info.format = "MP3"
                case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: contents.info.format = "AAC"
                default: contents.info.format = url.pathExtension.uppercased()
                }
            }
        }
        if contents.info.format.isEmpty { contents.info.format = url.pathExtension.uppercased() }

        switch url.pathExtension.lowercased() {
        case "mp3": contents.cover = ID3Tag.apply(try ID3Tag.read(url).frames, to: &contents.tags)
        default: contents.cover = MP4Tag.apply(try MP4Tag.readItems(url), to: &contents.tags)
        }
        return contents
    }
}
