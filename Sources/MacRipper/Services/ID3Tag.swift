import Foundation

/// Reads and writes ID3v2 tags of MP3 files directly, so frames MacRipper does not manage (lyrics, ratings,
/// ReplayGain, Picard's UFID …) survive byte for byte. Tags are written as ID3v2.4 in UTF-8, with Picard's frame
/// and TXXX names.
enum ID3Tag {
    struct Frame: Equatable {
        var id: String
        /// Format flags in ID3v2.4 layout (status flags are dropped when a tag is rewritten).
        var flags: UInt16 = 0
        var body: Data
    }

    // MARK: Reading

    /// Tag and size of the ID3v2 tag at the start of a file (0 when there is none).
    static func read(_ url: URL) throws -> (frames: [Frame], length: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 10), header.count == 10, header.prefix(3) == Data("ID3".utf8)
        else { return ([], 0) }
        let h = [UInt8](header)
        let size = syncsafe(h[6], h[7], h[8], h[9])
        let length = 10 + size + (h[3] == 4 && h[5] & 0x10 != 0 ? 10 : 0)
        guard let body = try handle.read(upToCount: size), body.count == size else { return ([], 0) }
        return (parse(version: h[3], flags: h[5], body: [UInt8](body)), length)
    }

    static func parse(version: UInt8, flags: UInt8, body original: [UInt8]) -> [Frame] {
        var body = original
        if flags & 0x80 != 0, version < 4 { body = deunsynchronize(body) }
        var pos = 0
        if flags & 0x40 != 0, body.count >= 4 {
            // Extended header: its own size is included in v2.4, excluded in v2.3.
            pos = version == 4 ? syncsafe(body[0], body[1], body[2], body[3]) : be32(body, 0) + 4
        }
        var frames: [Frame] = []
        let headerSize = version == 2 ? 6 : 10
        while pos + headerSize <= body.count, body[pos] != 0 {
            let rawID = String(decoding: body[pos..<(pos + (version == 2 ? 3 : 4))], as: UTF8.self)
            let size: Int
            var frameFlags: UInt16 = 0
            switch version {
            case 2: size = Int(body[pos + 3]) << 16 | Int(body[pos + 4]) << 8 | Int(body[pos + 5])
            case 3: size = be32(body, pos + 4)
            default: size = syncsafe(body[pos + 4], body[pos + 5], body[pos + 6], body[pos + 7])
            }
            if version >= 3 { frameFlags = UInt16(body[pos + 8]) << 8 | UInt16(body[pos + 9]) }
            let start = pos + headerSize
            guard size >= 0, start + size <= body.count else { break }
            var data = Array(body[start..<(start + size)])
            pos = start + size

            var id = rawID
            var format: UInt16 = 0
            switch version {
            case 2:
                guard let mapped = v22Names[rawID] else { continue }      // other v2.2 frames are not kept
                id = mapped
            case 3:
                // v2.3 compression, encryption and grouping change the frame layout; such frames are rare and dropped.
                if frameFlags & 0x00E0 != 0 { continue }
            default:
                format = frameFlags & 0x00FF
                if format & 0x0002 != 0 {                                  // per-frame unsynchronisation
                    data = deunsynchronize(data)
                    format &= ~0x0002
                }
                if format & 0x0001 != 0 {                                  // data length indicator
                    if format & 0x000C == 0, data.count >= 4 { data.removeFirst(4); format &= ~0x0001 }
                }
            }
            guard id.allSatisfy({ $0.isUppercase || $0.isNumber }) else { continue }
            frames.append(Frame(id: id, flags: format, body: Data(data)))
        }
        return frames
    }

    /// ID3v2.2 frames MacRipper understands, by their v2.4 names.
    static let v22Names: [String: String] = [
        "TT2": "TIT2", "TP1": "TPE1", "TP2": "TPE2", "TAL": "TALB", "TYE": "TYER", "TRK": "TRCK", "TPA": "TPOS",
        "TCO": "TCON", "TCM": "TCOM", "TPB": "TPUB", "TRC": "TSRC", "COM": "COMM", "TXX": "TXXX", "ULT": "USLT",
    ]

    /// Applies the frames to `tags` and returns the front cover (or the first picture).
    static func apply(_ frames: [Frame], to tags: inout AudioTags) -> Data? {
        var front: Data?
        var any: Data?
        var comment: String?
        for frame in frames {
            let b = [UInt8](frame.body)
            switch frame.id {
            case "TXXX":
                guard let encoding = b.first else { continue }
                let parts = strings(Array(b.dropFirst()), encoding: encoding)
                guard parts.count >= 2 else { continue }
                let description = parts[0]
                let value = parts.dropFirst().joined(separator: "; ")
                if description.lowercased() == "comment" { if comment == nil { comment = value }; continue }
                if let name = TagReader.id3Names[description.uppercased()] { TagReader.apply(name, value, to: &tags) }
            case "COMM":
                guard b.count > 4 else { continue }
                let parts = strings(Array(b[4...]), encoding: b[0])
                guard parts.count >= 2 else { continue }
                // Comments with a description are data of other programs (iTunNORM, iTunSMPB …), not the comment.
                if parts[0].isEmpty || parts[0] == "ID3v1 Comment" { comment = comment ?? parts[1] }
            case "UFID":
                guard let zero = b.firstIndex(of: 0) else { continue }
                if String(decoding: b[..<zero], as: UTF8.self) == musicBrainzOwner {
                    tags.musicBrainzRecordingID = String(decoding: b[(zero + 1)...], as: UTF8.self)
                }
            case "APIC":
                guard let picture = parsePicture(b) else { continue }
                if picture.type == 3, front == nil { front = picture.data }
                if any == nil { any = picture.data }
            default:
                guard frame.id.hasPrefix("T"), let encoding = b.first,
                      let name = TagReader.id3Names[frame.id] else { continue }
                var value = strings(Array(b.dropFirst()), encoding: encoding).filter { !$0.isEmpty }
                    .joined(separator: "; ")
                if frame.id == "TCON" { value = ID3Genres.resolve(value) }
                TagReader.apply(name, value, to: &tags)
            }
        }
        if let comment { tags.comment = comment }
        return front ?? any
    }

    static func parsePicture(_ b: [UInt8]) -> (type: Int, data: Data)? {
        guard b.count > 4, let mimeEnd = b[1...].firstIndex(of: 0), mimeEnd + 2 < b.count else { return nil }
        let type = Int(b[mimeEnd + 1])
        let encoding = b[0]
        var pos = mimeEnd + 2
        // The description ends with one zero byte (Latin-1, UTF-8) or two (UTF-16).
        if encoding == 1 || encoding == 2 {
            while pos + 1 < b.count, !(b[pos] == 0 && b[pos + 1] == 0) { pos += 2 }
            pos += 2
        } else {
            while pos < b.count, b[pos] != 0 { pos += 1 }
            pos += 1
        }
        guard pos <= b.count else { return nil }
        return (type, Data(b[pos...]))
    }

    // MARK: Writing

    static let musicBrainzOwner = "http://musicbrainz.org"

    /// Text frames written from `AudioTags`, plus the v2.3 date frames they replace.
    static let managedFrames: Set<String> = [
        "TIT2", "TPE1", "TALB", "TPE2", "TSO2", "TDRC", "TYER", "TDAT", "TIME", "TRDA", "TDOR", "TORY", "TRCK", "TPOS",
        "TCON", "TCOM", "TPUB", "TSRC", "TMED", "TCMP",
    ]

    /// TXXX descriptions written from `AudioTags` (compared case-insensitively).
    static let managedDescriptions: Set<String> = [
        "comment", "catalognumber", "barcode", "musicbrainz album id", "musicbrainz release group id",
        "musicbrainz album artist id", "musicbrainz artist id", "musicbrainz release track id", "musicbrainz disc id",
        "musicbrainz album release country", "musicbrainz track id", "originalyear", "originaldate",
    ]

    static func frames(for t: AudioTags) -> [Frame] {
        var frames: [Frame] = []
        func text(_ id: String, _ value: String) {
            if !value.isEmpty { frames.append(Frame(id: id, body: Data([3]) + Data(value.utf8))) }
        }
        func txxx(_ description: String, _ value: String) {
            if !value.isEmpty { frames.append(Frame(id: "TXXX", body: Data([3]) + Data(description.utf8) + Data([0]) + Data(value.utf8))) }
        }
        text("TIT2", t.title)
        text("TPE1", t.artist)
        text("TALB", t.album)
        text("TPE2", t.albumArtist)
        text("TSO2", t.albumArtistSort)
        text("TDRC", t.date)
        text("TDOR", t.originalDate)
        text("TRCK", t.track > 0 ? (t.trackTotal > 0 ? "\(t.track)/\(t.trackTotal)" : "\(t.track)") : "")
        text("TPOS", t.disc > 0 ? (t.discTotal > 0 ? "\(t.disc)/\(t.discTotal)" : "\(t.disc)") : "")
        text("TCON", t.genre)
        text("TCOM", t.composer)
        text("TPUB", t.label)
        text("TSRC", t.isrc)
        text("TMED", t.media)
        text("TCMP", t.compilation ? "1" : "")
        if !t.comment.isEmpty {
            frames.append(Frame(id: "COMM", body: Data([3]) + Data("eng".utf8) + Data([0]) + Data(t.comment.utf8)))
        }
        txxx("CATALOGNUMBER", t.catalogNumber)
        txxx("BARCODE", t.barcode)
        txxx("MusicBrainz Album Release Country", t.country)
        txxx("MusicBrainz Album Id", t.musicBrainzReleaseID)
        txxx("MusicBrainz Release Group Id", t.musicBrainzReleaseGroupID)
        txxx("MusicBrainz Album Artist Id", t.musicBrainzAlbumArtistID)
        txxx("MusicBrainz Artist Id", t.musicBrainzArtistID)
        txxx("MusicBrainz Release Track Id", t.musicBrainzReleaseTrackID)
        txxx("MusicBrainz Disc Id", t.musicBrainzDiscID)
        if !t.musicBrainzRecordingID.isEmpty {
            frames.append(Frame(id: "UFID", body: Data(musicBrainzOwner.utf8) + Data([0]) + Data(t.musicBrainzRecordingID.utf8)))
        }
        if let cover = t.cover {
            // Latin-1, MIME type, type 3 (front cover), empty description, image.
            frames.append(Frame(id: "APIC", body: Data([0]) + Data(cover.mimeType.utf8) + Data([0, 3, 0]) + cover.data))
        }
        return frames
    }

    /// Whether a frame of an existing tag is replaced by MacRipper's frames.
    static func isManaged(_ frame: Frame, replacingCover: Bool) -> Bool {
        let b = [UInt8](frame.body)
        switch frame.id {
        case "TXXX":
            guard let encoding = b.first, let description = strings(Array(b.dropFirst()), encoding: encoding).first
            else { return false }
            return managedDescriptions.contains(description.lowercased())
        case "COMM":
            guard b.count > 4, let description = strings(Array(b[4...]), encoding: b[0]).first else { return false }
            return description.isEmpty || description == "ID3v1 Comment"
        case "UFID":
            guard let zero = b.firstIndex(of: 0) else { return false }
            return String(decoding: b[..<zero], as: UTF8.self) == musicBrainzOwner
        case "APIC":
            // Front covers (and untyped pictures) are the cover; back covers, booklets … are other data.
            guard replacingCover, let picture = parsePicture(b) else { return false }
            return picture.type == 3 || picture.type == 0
        default:
            return managedFrames.contains(frame.id)
        }
    }

    /// Replaces the ID3v2 tag of an MP3 file. With `preservingOtherTags`, frames MacRipper does not manage stay;
    /// with `keepExistingCover`, the embedded cover stays when `tags.cover` is nil. An existing ID3v1 tag at the end
    /// of the file is updated, a missing one is not added.
    static func write(_ tags: AudioTags, to url: URL, preservingOtherTags: Bool, keepExistingCover: Bool) throws {
        let existing = try read(url)
        let replacingCover = !(keepExistingCover && tags.cover == nil)
        var kept: [Frame] = []
        for frame in existing.frames {
            if frame.id == "APIC", !replacingCover { kept.append(frame); continue }
            if preservingOtherTags, !isManaged(frame, replacingCover: replacingCover) { kept.append(frame) }
        }
        var data = try Data(contentsOf: url)
        var audio = data.subdata(in: min(existing.length, data.count)..<data.count)
        var hasV1 = false
        if audio.count >= 128, audio.suffix(128).prefix(3) == Data("TAG".utf8) {
            hasV1 = true
            audio.removeLast(128)
        }
        data = tag(kept + frames(for: tags))
        data.append(audio)
        if hasV1 { data.append(id3v1(tags)) }
        try FileWriting.replace(url, with: data)
    }

    static func tag(_ frames: [Frame], padding: Int = 2048) -> Data {
        var body = Data()
        for frame in frames {
            body.append(Data(frame.id.utf8.prefix(4)))
            body.append(syncsafeBytes(frame.body.count))
            body.append(contentsOf: [0, UInt8(frame.flags & 0xFF)])
            body.append(frame.body)
        }
        body.append(Data(count: padding))
        return Data("ID3".utf8) + Data([4, 0, 0]) + syncsafeBytes(body.count) + body
    }

    static func id3v1(_ t: AudioTags) -> Data {
        func field(_ s: String, _ length: Int) -> Data {
            var bytes = Data((s.data(using: .isoLatin1, allowLossyConversion: true) ?? Data()).prefix(length))
            bytes.append(Data(count: length - bytes.count))
            return bytes
        }
        return Data("TAG".utf8) + field(t.title, 30) + field(t.artist, 30) + field(t.album, 30) + field(t.year, 4)
            + field(t.comment, 28) + Data([0, UInt8(clamping: max(0, t.track)), ID3Genres.index(of: t.genre)])
    }

    // MARK: Helpers

    static func syncsafe(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
        Int(a & 0x7F) << 21 | Int(b & 0x7F) << 14 | Int(c & 0x7F) << 7 | Int(d & 0x7F)
    }

    static func syncsafeBytes(_ v: Int) -> Data {
        Data([UInt8(v >> 21 & 0x7F), UInt8(v >> 14 & 0x7F), UInt8(v >> 7 & 0x7F), UInt8(v & 0x7F)])
    }

    static func be32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }

    static func deunsynchronize(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            out.append(b[i])
            if b[i] == 0xFF, i + 1 < b.count, b[i + 1] == 0 { i += 1 }
            i += 1
        }
        return out
    }

    /// Zero separated strings in one of ID3's encodings: 0 Latin-1, 1 UTF-16 with BOM, 2 UTF-16BE, 3 UTF-8.
    static func strings(_ b: [UInt8], encoding: UInt8) -> [String] {
        var parts: [[UInt8]] = []
        var current: [UInt8] = []
        if encoding == 1 || encoding == 2 {
            var i = 0
            while i + 1 < b.count {
                if b[i] == 0, b[i + 1] == 0 {
                    parts.append(current)
                    current = []
                } else {
                    current += [b[i], b[i + 1]]
                }
                i += 2
            }
        } else {
            for byte in b {
                if byte == 0 { parts.append(current); current = [] } else { current.append(byte) }
            }
        }
        parts.append(current)
        // A trailing terminator leaves an empty last part; empty parts in between are kept (empty descriptions).
        if parts.count > 1, parts.last?.isEmpty == true { parts.removeLast() }
        return parts.map { part in
            switch encoding {
            case 0: String(data: Data(part), encoding: .isoLatin1) ?? ""
            case 1:
                if part.starts(with: [0xFF, 0xFE]) { String(data: Data(part.dropFirst(2)), encoding: .utf16LittleEndian) ?? "" }
                else if part.starts(with: [0xFE, 0xFF]) { String(data: Data(part.dropFirst(2)), encoding: .utf16BigEndian) ?? "" }
                else { String(data: Data(part), encoding: .utf16LittleEndian) ?? "" }
            case 2: String(data: Data(part), encoding: .utf16BigEndian) ?? ""
            default: String(decoding: part, as: UTF8.self)
            }
        }
    }
}

/// The ID3v1 genre list (with the Winamp extensions), which ID3 "(17)" references and MP4 "gnre" atoms use.
enum ID3Genres {
    static let names = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal", "New Age",
        "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska",
        "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion",
        "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock",
        "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream",
        "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle",
        "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal",
        "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock", "Folk", "Folk-Rock",
        "National Folk", "Swing", "Fast Fusion", "Bebop", "Latin", "Revival", "Celtic", "Bluegrass", "Avantgarde",
        "Gothic Rock", "Progressive Rock", "Psychedelic Rock", "Symphonic Rock", "Slow Rock", "Big Band", "Chorus",
        "Easy Listening", "Acoustic", "Humour", "Speech", "Chanson", "Opera", "Chamber Music", "Sonata", "Symphony",
        "Booty Bass", "Primus", "Porn Groove", "Satire", "Slow Jam", "Club", "Tango", "Samba", "Folklore", "Ballad",
        "Power Ballad", "Rhythmic Soul", "Freestyle", "Duet", "Punk Rock", "Drum Solo", "A Cappella", "Euro-House",
        "Dance Hall", "Goa", "Drum & Bass", "Club-House", "Hardcore", "Terror", "Indie", "BritPop", "Afro-Punk",
        "Polsk Punk", "Beat", "Christian Gangsta Rap", "Heavy Metal", "Black Metal", "Crossover",
        "Contemporary Christian", "Christian Rock", "Merengue", "Salsa", "Thrash Metal", "Anime", "JPop", "Synthpop",
    ]

    /// "(17)", "(17)Rock", "17" → "Rock"; "RX"/"CR" → Remix/Cover; other text stays as it is.
    static func resolve(_ value: String) -> String {
        var rest = value.trimmingCharacters(in: .whitespaces)
        var resolved: [String] = []
        while rest.hasPrefix("("), let close = rest.firstIndex(of: ")") {
            let code = rest[rest.index(after: rest.startIndex)..<close]
            if let n = Int(code), names.indices.contains(n) { resolved.append(names[n]) }
            else if code == "RX" { resolved.append("Remix") }
            else if code == "CR" { resolved.append("Cover") }
            rest = String(rest[rest.index(after: close)...])
        }
        if !rest.isEmpty {
            // "(17)Rock" repeats the name after the reference.
            if let n = Int(rest), names.indices.contains(n) { return names[n] }
            return rest
        }
        return resolved.first ?? ""
    }

    static func index(of genre: String) -> UInt8 {
        names.firstIndex { $0.caseInsensitiveCompare(genre) == .orderedSame }.map { UInt8($0) } ?? 255
    }
}

/// Replaces a file's contents through a temporary file, keeping its Finder tags, dates and permissions.
enum FileWriting {
    static func replace(_ url: URL, with data: Data) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".macripper-\(UUID().uuidString).\(url.pathExtension)")
        do {
            try data.write(to: temp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}
