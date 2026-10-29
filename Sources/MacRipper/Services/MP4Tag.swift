import Foundation

/// Reads and writes iTunes metadata (moov/udta/meta/ilst) of M4A files directly. Atoms MacRipper does not manage –
/// lyrics, sort names, gapless info, Picard's and other programs' freeform "----" atoms – stay byte for byte.
/// Freeform names follow MusicBrainz Picard, so M4A files get the same fields as FLAC and MP3.
enum MP4Tag {
    struct Item: Equatable {
        /// Four character code, e.g. "©nam", or "----:mean:name" for freeform atoms.
        let key: String
        let raw: Data                   // the complete item atom
        let dataType: Int
        let payload: Data               // contents of its (first) data atom
    }

    // MARK: Atoms

    struct Atom {
        let type: String
        let start: Int                  // offset of the atom header
        let headerSize: Int
        let end: Int                    // offset after the atom
        var bodyStart: Int { start + headerSize }
    }

    static func fourCC(_ s: String) -> Data { s.data(using: .isoLatin1) ?? Data(s.utf8) }

    static func atoms(_ d: [UInt8], in range: Range<Int>) -> [Atom] {
        var result: [Atom] = []
        var pos = range.lowerBound
        while pos + 8 <= range.upperBound {
            var size = be32(d, pos)
            var header = 8
            if size == 1 {
                guard pos + 16 <= range.upperBound else { break }
                size = Int(be32(d, pos + 8)) << 32 | be32(d, pos + 12)
                header = 16
            } else if size == 0 {
                size = range.upperBound - pos
            }
            guard size >= header, pos + size <= range.upperBound else { break }
            let type = String(data: Data(d[(pos + 4)..<(pos + 8)]), encoding: .isoLatin1) ?? ""
            result.append(Atom(type: type, start: pos, headerSize: header, end: pos + size))
            pos += size
        }
        return result
    }

    static func atom(_ type: String, _ body: Data) -> Data { be32Data(body.count + 8) + fourCC(type) + body }

    // MARK: Reading

    /// The metadata items of a file. Only the moov atom is read, never the audio.
    static func readItems(_ url: URL) throws -> [Item] {
        guard let moov = try readMoov(url) else { return [] }
        let d = [UInt8](moov)
        return ilstRange(d).map { items(d, in: $0) } ?? []
    }

    private static func readMoov(_ url: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        var pos: UInt64 = 0
        while pos + 8 <= length {
            try handle.seek(toOffset: pos)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { break }
            let h = [UInt8](header)
            var size = UInt64(be32(h, 0))
            if size == 1, h.count == 16 { size = UInt64(be32(h, 8)) << 32 | UInt64(be32(h, 12)) }
            if size == 0 { size = length - pos }
            guard size >= 8 else { break }
            if String(data: Data(h[4..<8]), encoding: .isoLatin1) == "moov" {
                try handle.seek(toOffset: pos)
                return try handle.read(upToCount: Int(size))
            }
            pos += size
        }
        return nil
    }

    /// Range of the ilst body inside a moov atom (which starts at offset 0 of `d`).
    static func ilstRange(_ d: [UInt8]) -> Range<Int>? {
        guard let moov = atoms(d, in: 0..<d.count).first(where: { $0.type == "moov" }),
              let udta = atoms(d, in: moov.bodyStart..<moov.end).first(where: { $0.type == "udta" }),
              let meta = atoms(d, in: udta.bodyStart..<udta.end).first(where: { $0.type == "meta" }),
              let ilst = atoms(d, in: (meta.bodyStart + 4)..<meta.end).first(where: { $0.type == "ilst" })
        else { return nil }
        return ilst.bodyStart..<ilst.end
    }

    static func items(_ d: [UInt8], in range: Range<Int>) -> [Item] {
        atoms(d, in: range).map { item in
            var key = item.type
            var dataType = 0
            var payload = Data()
            var mean = "", name = ""
            for child in atoms(d, in: item.bodyStart..<item.end) {
                switch child.type {
                case "mean": mean = String(decoding: d[min(child.bodyStart + 4, child.end)..<child.end], as: UTF8.self)
                case "name": name = String(decoding: d[min(child.bodyStart + 4, child.end)..<child.end], as: UTF8.self)
                case "data" where payload.isEmpty && child.end - child.bodyStart >= 8:
                    dataType = be32(d, child.bodyStart) & 0xFFFFFF
                    payload = Data(d[(child.bodyStart + 8)..<child.end])
                default: break
                }
            }
            if key == "----" { key = "----:\(mean):\(name)" }
            return Item(key: key, raw: Data(d[item.start..<item.end]), dataType: dataType, payload: payload)
        }
    }

    /// iTunes atoms → Vorbis names.
    static let names: [String: String] = [
        "\u{A9}nam": "TITLE", "\u{A9}ART": "ARTIST", "aART": "ALBUMARTIST", "\u{A9}alb": "ALBUM", "\u{A9}day": "DATE",
        "\u{A9}gen": "GENRE", "\u{A9}wrt": "COMPOSER", "\u{A9}cmt": "COMMENT", "soaa": "ALBUMARTISTSORT",
    ]

    /// Picard's freeform names (mean com.apple.iTunes) → Vorbis names.
    static let freeformNames: [String: String] = [
        "LABEL": "LABEL", "CATALOGNUMBER": "CATALOGNUMBER", "BARCODE": "BARCODE", "ISRC": "ISRC", "MEDIA": "MEDIA",
        "ORIGINALDATE": "ORIGINALDATE", "ORIGINALYEAR": "ORIGINALYEAR",
        "MUSICBRAINZ ALBUM ID": "MUSICBRAINZ_ALBUMID", "MUSICBRAINZ RELEASE GROUP ID": "MUSICBRAINZ_RELEASEGROUPID",
        "MUSICBRAINZ ALBUM ARTIST ID": "MUSICBRAINZ_ALBUMARTISTID", "MUSICBRAINZ ARTIST ID": "MUSICBRAINZ_ARTISTID",
        "MUSICBRAINZ TRACK ID": "MUSICBRAINZ_TRACKID", "MUSICBRAINZ RELEASE TRACK ID": "MUSICBRAINZ_RELEASETRACKID",
        "MUSICBRAINZ DISC ID": "MUSICBRAINZ_DISCID", "MUSICBRAINZ ALBUM RELEASE COUNTRY": "RELEASECOUNTRY",
    ]

    /// Applies the items to `tags` and returns the cover.
    static func apply(_ items: [Item], to tags: inout AudioTags) -> Data? {
        var cover: Data?
        var genreFromIndex = ""
        for item in items {
            let p = [UInt8](item.payload)
            switch item.key {
            case "trkn", "disk":
                guard p.count >= 6 else { continue }
                let number = Int(p[2]) << 8 | Int(p[3]), total = Int(p[4]) << 8 | Int(p[5])
                if item.key == "trkn" { tags.track = number; tags.trackTotal = total }
                else { tags.disc = number; tags.discTotal = total }
            case "cpil": tags.compilation = p.last == 1
            case "covr": if cover == nil, !p.isEmpty { cover = item.payload }
            case "gnre":
                // Index into the ID3v1 list, plus one.
                if p.count >= 2 {
                    let index = (Int(p[0]) << 8 | Int(p[1])) - 1
                    if ID3Genres.names.indices.contains(index) { genreFromIndex = ID3Genres.names[index] }
                }
            default:
                let value = String(decoding: p, as: UTF8.self)
                if item.key.hasPrefix("----:") {
                    let name = item.key.split(separator: ":", maxSplits: 2).last.map(String.init) ?? ""
                    if let field = freeformNames[name.uppercased()] { TagReader.apply(field, value, to: &tags) }
                } else if let field = names[item.key] {
                    TagReader.apply(field, value, to: &tags)
                }
            }
        }
        if tags.genre.isEmpty { tags.genre = genreFromIndex }
        return cover
    }

    // MARK: Writing

    static let managedKeys: Set<String> = Set(names.keys).union(["trkn", "disk", "cpil", "gnre"])

    static func isManagedFreeform(_ key: String) -> Bool {
        guard key.hasPrefix("----:") else { return false }
        return freeformNames[(key.split(separator: ":", maxSplits: 2).last.map(String.init) ?? "").uppercased()] != nil
    }

    static func newItems(_ t: AudioTags) -> [Data] {
        var items: [Data] = []
        func data(_ type: Int, _ payload: Data) -> Data { atom("data", be32Data(type) + be32Data(0) + payload) }
        func text(_ key: String, _ value: String) {
            if !value.isEmpty { items.append(atom(key, data(1, Data(value.utf8)))) }
        }
        func freeform(_ name: String, _ value: String) {
            guard !value.isEmpty else { return }
            items.append(atom("----", atom("mean", Data(count: 4) + Data("com.apple.iTunes".utf8))
                              + atom("name", Data(count: 4) + Data(name.utf8)) + data(1, Data(value.utf8))))
        }
        func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        text("\u{A9}nam", t.title)
        text("\u{A9}ART", t.artist)
        text("aART", t.albumArtist)
        text("\u{A9}alb", t.album)
        text("\u{A9}day", t.date)
        text("\u{A9}gen", t.genre)
        text("\u{A9}wrt", t.composer)
        text("\u{A9}cmt", t.comment)
        text("soaa", t.albumArtistSort)
        if t.track > 0 { items.append(atom("trkn", data(0, Data([0, 0] + be16(t.track) + be16(t.trackTotal) + [0, 0])))) }
        if t.disc > 0 { items.append(atom("disk", data(0, Data([0, 0] + be16(t.disc) + be16(t.discTotal))))) }
        if t.compilation { items.append(atom("cpil", data(21, Data([1])))) }
        freeform("LABEL", t.label)
        freeform("CATALOGNUMBER", t.catalogNumber)
        freeform("BARCODE", t.barcode)
        freeform("ISRC", t.isrc)
        freeform("MEDIA", t.media)
        freeform("ORIGINALDATE", t.originalDate)
        freeform("MusicBrainz Album Release Country", t.country)
        freeform("MusicBrainz Album Id", t.musicBrainzReleaseID)
        freeform("MusicBrainz Release Group Id", t.musicBrainzReleaseGroupID)
        freeform("MusicBrainz Album Artist Id", t.musicBrainzAlbumArtistID)
        freeform("MusicBrainz Artist Id", t.musicBrainzArtistID)
        freeform("MusicBrainz Track Id", t.musicBrainzRecordingID)
        freeform("MusicBrainz Release Track Id", t.musicBrainzReleaseTrackID)
        freeform("MusicBrainz Disc Id", t.musicBrainzDiscID)
        if let cover = t.cover { items.append(atom("covr", data(cover.format == "png" ? 14 : 13, cover.data))) }
        return items
    }

    /// Rewrites the ilst atom of an M4A file. When the moov atom changes size and sits before the audio, the chunk
    /// offsets (stco/co64) are moved by the same amount, so the audio stays where the file says it is.
    static func write(_ tags: AudioTags, to url: URL, preservingOtherTags: Bool, keepExistingCover: Bool) throws {
        let file = try Data(contentsOf: url)
        let d = [UInt8](file)
        let top = atoms(d, in: 0..<d.count)
        guard let moov = top.first(where: { $0.type == "moov" }) else {
            throw RipError.failed("\(url.lastPathComponent) is not a valid M4A file")
        }
        if top.contains(where: { $0.type == "moof" }) {
            throw RipError.failed("\(url.lastPathComponent) is a fragmented MP4 file, which MacRipper cannot tag")
        }

        let existing = ilstRange(Array(d[moov.start..<moov.end])).map { range in
            items(Array(d[moov.start..<moov.end]), in: range)
        } ?? []
        var ilstBody = Data()
        for item in existing {
            let keep = item.key == "covr"
                ? keepExistingCover && tags.cover == nil
                : preservingOtherTags && !managedKeys.contains(item.key) && !isManagedFreeform(item.key)
            if keep { ilstBody.append(item.raw) }
        }
        newItems(tags).forEach { ilstBody.append($0) }
        let ilst = atom("ilst", ilstBody)

        // Rebuild meta, udta and moov around the new ilst, keeping all their other children.
        func rebuilt(_ container: Atom, prefix: Int = 0, replacing type: String, with child: Data) -> Data {
            var body = Data(d[container.bodyStart..<(container.bodyStart + prefix)])
            var replaced = false
            for a in atoms(d, in: (container.bodyStart + prefix)..<container.end) {
                if a.type == type, !replaced { body.append(child); replaced = true } else { body.append(contentsOf: d[a.start..<a.end]) }
            }
            if !replaced { body.append(child) }
            return atom(container.type, body)
        }
        let udta = atoms(d, in: moov.bodyStart..<moov.end).first { $0.type == "udta" }
        let meta = udta.flatMap { u in atoms(d, in: u.bodyStart..<u.end).first { $0.type == "meta" } }
        let newMeta: Data
        if let meta {
            newMeta = rebuilt(meta, prefix: 4, replacing: "ilst", with: ilst)
        } else {
            // version/flags, then the handler iTunes expects ("mdir", "appl").
            let hdlr = atom("hdlr", Data(count: 8) + fourCC("mdir") + fourCC("appl") + Data(count: 9))
            newMeta = atom("meta", Data(count: 4) + hdlr + ilst)
        }
        let newUdta = udta.map { rebuilt($0, replacing: "meta", with: newMeta) } ?? atom("udta", newMeta)
        var newMoov = [UInt8](rebuilt(moov, replacing: "udta", with: newUdta))

        let delta = newMoov.count - (moov.end - moov.start)
        if delta != 0, top.contains(where: { $0.type == "mdat" && $0.start > moov.start }) {
            shiftChunkOffsets(&newMoov, by: delta, after: moov.start)
        }
        var output = Data(d[0..<moov.start])
        output.append(contentsOf: newMoov)
        output.append(contentsOf: d[moov.end...])
        try FileWriting.replace(url, with: output)
    }

    /// Adds `delta` to every chunk offset that points behind `after` (the old position of moov).
    static func shiftChunkOffsets(_ moov: inout [UInt8], by delta: Int, after: Int) {
        let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]
        func walk(_ range: Range<Int>) {
            for a in atoms(moov, in: range) {
                if containers.contains(a.type) {
                    walk(a.bodyStart..<a.end)
                } else if a.type == "stco" || a.type == "co64" {
                    let wide = a.type == "co64"
                    guard a.bodyStart + 8 <= a.end else { continue }
                    // The entry count comes from the file; a damaged one must not run past the atom.
                    let count = min(be32(moov, a.bodyStart + 4), (a.end - a.bodyStart - 8) / (wide ? 8 : 4))
                    var pos = a.bodyStart + 8
                    for _ in 0..<count {
                        if wide {
                            let value = Int(be32(moov, pos)) << 32 | be32(moov, pos + 4)
                            if value > after { put64(&moov, pos, value + delta) }
                            pos += 8
                        } else {
                            let value = be32(moov, pos)
                            if value > after { put32(&moov, pos, value + delta) }
                            pos += 4
                        }
                    }
                }
            }
        }
        walk(0..<moov.count)
    }

    // MARK: Helpers

    static func be32(_ d: [UInt8], _ i: Int) -> Int {
        Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3])
    }

    static func be32Data(_ v: Int) -> Data {
        Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }

    static func put32(_ d: inout [UInt8], _ i: Int, _ v: Int) {
        d[i] = UInt8(v >> 24 & 0xFF); d[i + 1] = UInt8(v >> 16 & 0xFF); d[i + 2] = UInt8(v >> 8 & 0xFF); d[i + 3] = UInt8(v & 0xFF)
    }

    static func put64(_ d: inout [UInt8], _ i: Int, _ v: Int) {
        put32(&d, i, v >> 32)
        put32(&d, i + 4, v & 0xFFFF_FFFF)
    }
}
