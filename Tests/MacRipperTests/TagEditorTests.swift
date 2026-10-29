import Foundation
import AVFoundation
import AppKit
import Testing
@testable import MacRipper

@Suite struct TagEditorTests {
    // MARK: Fixtures

    /// A folder per test, removed afterwards by the system's temp cleanup.
    static func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macripper-tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// One second of a 440 Hz tone as 16 bit stereo WAV.
    static func wav(in folder: URL) throws -> URL {
        let rate = 44_100, channels = 2
        var pcm = Data()
        for i in 0..<rate {
            let sample = Int16(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * 8_000)
            for _ in 0..<channels { withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) } }
        }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        var d = Data("RIFF".utf8) + le32(36 + pcm.count) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(channels)
        d += le32(rate) + le32(rate * channels * 2) + le16(channels * 2) + le16(16) + Data("data".utf8) + le32(pcm.count) + pcm
        let url = folder.appendingPathComponent("tone.wav")
        try d.write(to: url)
        return url
    }

    static func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RipError.failed("\(tool) failed") }
    }

    static func afconvert(_ wav: URL, to name: String, _ format: [String]) throws -> URL {
        let out = wav.deletingLastPathComponent().appendingPathComponent(name)
        try run("/usr/bin/afconvert", format + [wav.path, out.path])
        return out
    }

    static var ffmpeg: String? { Tools.resolve("", name: "ffmpeg") }

    static func cover(_ color: (UInt8, UInt8, UInt8), size: Int = 64) -> AudioTags.EmbeddedCover {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255,
                                     blue: CGFloat(color.2) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
        return AudioTags.EmbeddedCover(data: png, format: "png", width: size, height: size)
    }

    static var sampleTags: AudioTags {
        var t = AudioTags()
        t.title = "Rysperdal Gstp"
        t.artist = "Ettella Diamant"
        t.album = "Ettella Diamant"
        t.albumArtist = "Ettella Diamant"
        t.albumArtistSort = "Diamant, Ettella"
        t.date = "2004-05-03"
        t.track = 3
        t.trackTotal = 12
        t.disc = 1
        t.discTotal = 2
        t.genre = "Trip Hop"
        t.composer = "Composer"
        t.comment = "A comment"
        t.label = "Deadred Records"
        t.compilation = true
        return t
    }

    // MARK: Field mapping

    @Test func mapsFieldNamesAndAliases() {
        var t = AudioTags()
        TagReader.apply("tracknumber", "03/12", to: &t)
        TagReader.apply("DISCNUMBER", "2", to: &t)
        TagReader.apply("TOTALDISCS", "3", to: &t)
        TagReader.apply("ALBUM ARTIST", "Various Artists", to: &t)
        TagReader.apply("ORGANIZATION", "Label", to: &t)
        TagReader.apply("ARTIST", "A", to: &t)
        TagReader.apply("ARTIST", "B", to: &t)
        TagReader.apply("YEAR", "2001", to: &t)
        TagReader.apply("DATE", "2001-02-03", to: &t)
        TagReader.apply("COMPILATION", "1", to: &t)
        #expect(!TagReader.apply("REPLAYGAIN_TRACK_GAIN", "-3 dB", to: &t))
        #expect(t.track == 3 && t.trackTotal == 12)
        #expect(t.disc == 2 && t.discTotal == 3)
        #expect(t.albumArtist == "Various Artists")
        #expect(t.label == "Label")
        #expect(t.artist == "A; B")
        #expect(t.date == "2001-02-03")
        #expect(t.compilation)
        #expect(TagReader.numberPair("4 of 10") == (4, 10))
        #expect(TagReader.id3Names["MUSICBRAINZ ALBUM ID"] == "MUSICBRAINZ_ALBUMID")
    }

    @Test func parsesFileNames() {
        let a = TagEditor.parseFileName("03 - Daft Punk - One More Time")
        #expect(a.track == 3 && a.artist == "Daft Punk" && a.title == "One More Time")
        let b = TagEditor.parseFileName("07. Digital Love")
        #expect(b.track == 7 && b.artist == nil && b.title == "Digital Love")
        let c = TagEditor.parseFileName("Aerodynamic")
        #expect(c.track == nil && c.title == "Aerodynamic")
        #expect(TagEditor.capitalizedWords("one more time (radio edit) by DJ x") == "One More Time (Radio Edit) By DJ X")
    }

    // MARK: Matching

    static var twoDiscRelease: AudioRelease {
        var r = AudioRelease(id: "r1")
        func track(_ n: Int, _ title: String, _ length: Int) -> AudioTrackInfo {
            var t = AudioTrackInfo(number: n)
            t.title = title
            t.length = length
            return t
        }
        r.discTracks = [1: [track(1, "Intro", 60), track(2, "Song Two", 200)],
                        2: [track(1, "Live One", 300), track(2, "Live Two", 245)]]
        return r
    }

    @Test func matchesFilesToReleaseTracks() {
        let ids = (0..<4).map { _ in UUID() }
        let files = [
            ReleaseMatcher.File(id: ids[0], disc: 1, track: 1, title: "intro", duration: 61),        // title + position
            ReleaseMatcher.File(id: ids[1], disc: 0, track: 0, title: "Live One", duration: 0),      // title only
            ReleaseMatcher.File(id: ids[2], disc: 1, track: 2, title: "Track 02", duration: 0),      // position only
            ReleaseMatcher.File(id: ids[3], disc: 0, track: 0, title: "", duration: 244),            // length only
        ]
        let result = ReleaseMatcher.match(files, to: Self.twoDiscRelease)
        #expect(result[ids[0]] == ReleaseTrackRef(disc: 1, number: 1))
        #expect(result[ids[1]] == ReleaseTrackRef(disc: 2, number: 1))
        #expect(result[ids[2]] == ReleaseTrackRef(disc: 1, number: 2))
        #expect(result[ids[3]] == ReleaseTrackRef(disc: 2, number: 2))
    }

    @Test func parsesAllMediaOfARelease() throws {
        let json = #"""
        {"id":"r","title":"Live","media":[
          {"position":1,"format":"CD","track-count":1,"tracks":[{"id":"t1","position":1,"title":"A","length":61000,"recording":{"id":"rec1"}}]},
          {"position":2,"format":"Vinyl","track-count":2,"tracks":[{"id":"t2","position":1,"title":"B","recording":{"id":"rec2","length":5000}},
                                                                   {"id":"t3","position":2,"title":"C","recording":{"id":"rec3"}}]}]}
        """#
        let dict = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let release = Metadata.parseRelease(dict, discID: nil, trackCount: 0)
        #expect(release.discTracks.keys.sorted() == [1, 2])
        #expect(release.discTracks[2]?.map(\.recordingID) == ["rec2", "rec3"])
        #expect(release.discFormats[2] == "Vinyl")
        #expect(release.discTracks[1]?.first?.length == 61)
        #expect(release.discTracks[2]?.first?.length == 5)
        #expect(release.discTotal == 2)
    }

    @Test func ranksOfficialAlbumsFirst() throws {
        let json = #"""
        {"recordings":[{"id":"rec","title":"Song","length":180000,
          "artist-credit":[{"name":"Artist","joinphrase":""}],
          "releases":[
            {"id":"single","title":"Song","status":"Official","release-group":{"primary-type":"Single"},
             "media":[{"format":"CD","track":[{"number":"1"}]}]},
            {"id":"boot","title":"Live","status":"Bootleg","release-group":{"primary-type":"Album"}},
            {"id":"album","title":"The Album","date":"1999","country":"GB","status":"Official",
             "release-group":{"primary-type":"Album"},"media":[{"format":"CD","track":[{"number":"4"}]}]}]}]}
        """#
        let matches = Metadata.parseRecordings(try JSONSerialization.jsonObject(with: Data(json.utf8)))
        #expect(matches.map(\.releaseID) == ["album", "single", "boot"])
        #expect(matches[0].trackNumber == "4")
        #expect(matches[0].length == 180)
        #expect(matches[0].releaseSummary == "The Album · 1999 · GB · CD · Album")
    }

    // MARK: Files

    @Test func flacRoundTripKeepsOtherFieldsAndCover() async throws {
        let folder = try Self.tempFolder()
        let flac = try Self.afconvert(try Self.wav(in: folder), to: "a.flac", ["-f", "flac", "-d", "flac"])
        var tags = Self.sampleTags
        tags.musicBrainzReleaseID = "rel-1"
        tags.cover = Self.cover((255, 0, 0))
        try FLACTagger.write(tags, to: flac)

        // Fields from other taggers: written by hand next to MacRipper's.
        var withExtra = tags
        withExtra.cover = nil
        try FLACTagger.write(withExtra, to: flac, preservingOtherTags: true, keepExistingCover: true)
        let read = try TagReader.readFLAC(flac)
        #expect(read.tags.title == tags.title)
        #expect(read.tags.track == 3 && read.tags.trackTotal == 12 && read.tags.discTotal == 2)
        #expect(read.tags.albumArtistSort == "Diamant, Ettella")
        #expect(read.tags.compilation)
        #expect(read.tags.musicBrainzReleaseID == "rel-1")
        #expect(read.cover == tags.cover?.data)                      // kept although not passed again
        #expect(read.info.sampleRate == 44_100 && read.info.channels == 2 && read.info.bitDepth == 16)
        #expect(abs(read.info.duration - 1) < 0.01)

        // Clearing a field removes it; the cover can be removed explicitly.
        var cleared = read.tags
        cleared.comment = ""
        try FLACTagger.write(cleared, to: flac, preservingOtherTags: true, keepExistingCover: false)
        let again = try TagReader.readFLAC(flac)
        #expect(again.tags.comment.isEmpty)
        #expect(again.cover == nil)
    }

    @Test(.enabled(if: TagEditorTests.ffmpeg != nil, "needs ffmpeg"))
    func flacKeepsUnknownFields() async throws {
        let folder = try Self.tempFolder()
        let wav = try Self.wav(in: folder)
        let flac = folder.appendingPathComponent("b.flac")
        try Self.run(Self.ffmpeg!, ["-y", "-loglevel", "error", "-i", wav.path, "-metadata", "TITLE=Old",
                                    "-metadata", "REPLAYGAIN_TRACK_GAIN=-3 dB", "-metadata", "LYRICS=la la", flac.path])
        var tags = try TagReader.readFLAC(flac).tags
        tags.title = "New"
        try FLACTagger.write(tags, to: flac, preservingOtherTags: true, keepExistingCover: true)
        let handle = try FileHandle(forReadingFrom: flac)
        let head = String(decoding: try handle.read(upToCount: 8192) ?? Data(), as: UTF8.self)
        #expect(head.contains("REPLAYGAIN_TRACK_GAIN=-3 dB"))
        #expect(head.contains("LYRICS=la la"))
        #expect(head.contains("TITLE=New") && !head.contains("TITLE=Old"))
    }

    @Test func m4aRoundTripWithCover() async throws {
        let folder = try Self.tempFolder()
        let m4a = try Self.afconvert(try Self.wav(in: folder), to: "a.m4a", ["-f", "m4af", "-d", "alac"])
        var tags = Self.sampleTags
        tags.cover = Self.cover((0, 0, 255))
        try MP4Tag.write(tags, to: m4a, preservingOtherTags: false, keepExistingCover: false)
        var read = try await TagReader.read(m4a)
        #expect(read.tags.title == tags.title)
        #expect(read.tags.album == tags.album && read.tags.albumArtist == tags.albumArtist)
        #expect(read.tags.track == 3 && read.tags.trackTotal == 12)
        #expect(read.tags.disc == 1 && read.tags.discTotal == 2)
        #expect(read.tags.genre == "Trip Hop" && read.tags.composer == "Composer")
        #expect(read.tags.albumArtistSort == "Diamant, Ettella")
        #expect(read.tags.compilation)
        #expect(read.cover == tags.cover?.data)
        #expect(read.info.format == "ALAC" && read.info.bitDepth == 16)

        // A rewrite without a cover keeps it when asked to.
        read.tags.title = "Changed"
        try MP4Tag.write(read.tags, to: m4a, preservingOtherTags: true, keepExistingCover: true)
        read = try await TagReader.read(m4a)
        #expect(read.tags.title == "Changed")
        #expect(read.cover == tags.cover?.data)
    }

    @Test(.enabled(if: TagEditorTests.ffmpeg != nil, "needs ffmpeg"))
    func m4aKeepsLyrics() async throws {
        let folder = try Self.tempFolder()
        let wav = try Self.wav(in: folder)
        let m4a = folder.appendingPathComponent("b.m4a")
        try Self.run(Self.ffmpeg!, ["-y", "-loglevel", "error", "-i", wav.path, "-c:a", "alac",
                                    "-metadata", "title=Old", "-metadata", "lyrics=la la", m4a.path])
        var tags = try await TagReader.read(m4a).tags
        tags.title = "New"
        try MP4Tag.write(tags, to: m4a, preservingOtherTags: true, keepExistingCover: true)
        let items = try await AVURLAsset(url: m4a).load(.metadata)
        let lyrics = try await items.first { $0.identifier == .iTunesMetadataLyrics }?.load(.stringValue)
        #expect(lyrics == "la la")
        #expect(try await TagReader.read(m4a).tags.title == "New")
    }

    @Test(.enabled(if: TagEditorTests.ffmpeg != nil, "needs ffmpeg"))
    func mp3RewriteKeepsOtherTagsAndCover() async throws {
        let folder = try Self.tempFolder()
        let wav = try Self.wav(in: folder)
        let mp3 = folder.appendingPathComponent("c.mp3")
        var tags = Self.sampleTags
        tags.musicBrainzReleaseID = "rel-1"
        tags.catalogNumber = "CAT 1"
        tags.cover = Self.cover((0, 255, 0))
        // Encode once like the ripper does, plus a tag MacRipper does not know.
        try Self.run(Self.ffmpeg!, ["-y", "-loglevel", "error", "-i", wav.path, "-c:a", "libmp3lame",
                                    "-metadata", "REPLAYGAIN_TRACK_GAIN=-3 dB", mp3.path])
        var config = AppConfig()
        config.ffmpegPath = Self.ffmpeg!
        try await AudioRipper.writeTags(tags, to: mp3, config: config, runner: ProcessRunner(), log: nil,
                                        preservingOtherTags: true, keepExistingCover: false)
        var read = try await TagReader.read(mp3)
        #expect(read.tags.title == tags.title && read.tags.artist == tags.artist)
        #expect(read.tags.track == 3 && read.tags.trackTotal == 12)
        #expect(read.tags.catalogNumber == "CAT 1" && read.tags.musicBrainzReleaseID == "rel-1")
        #expect(read.tags.albumArtistSort == "Diamant, Ettella")
        #expect(read.tags.compilation)
        #expect(read.cover != nil)

        // Change a field, clear another, keep the cover and the unknown tag.
        read.tags.title = "Changed"
        read.tags.comment = ""
        try await AudioRipper.writeTags(read.tags, to: mp3, config: config, runner: ProcessRunner(), log: nil,
                                        preservingOtherTags: true, keepExistingCover: true)
        let again = try await TagReader.read(mp3)
        #expect(again.tags.title == "Changed")
        #expect(again.tags.comment.isEmpty)
        #expect(again.cover != nil)
        let items = try await AVURLAsset(url: mp3).load(.metadata)
        var replayGain: String?
        for item in items where (try? await item.load(.extraAttributes))?[.info] as? String == "REPLAYGAIN_TRACK_GAIN" {
            replayGain = try await item.load(.stringValue)
        }
        #expect(replayGain == "-3 dB")
    }

    // MARK: Native ID3 and MP4

    /// Samples of an audio file, decoded – to prove that rewriting tags never touches the audio.
    static func pcm(_ url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData)
        return Data(bytes: channel[0], count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
    }

    @Test func id3KeepsForeignFramesAndAudio() throws {
        func frame(_ id: String, _ body: [UInt8]) -> Data {
            Data(id.utf8) + withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) } + Data([0, 0]) + Data(body)
        }
        // An ID3v2.3 tag like iTunes and Picard write: numeric genre, iTunNORM comment, UFID, rating, ReplayGain.
        let frames = frame("TIT2", [0] + Array("Old".utf8)) + frame("TCON", [0] + Array("(17)".utf8))
            + frame("COMM", [0] + Array("eng".utf8) + Array("iTunNORM".utf8) + [0] + Array(" 0000".utf8))
            + frame("COMM", [1] + Array("eng".utf8) + [0xFF, 0xFE, 0, 0] + [0xFF, 0xFE] + Array("Hi".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
            + frame("UFID", Array("http://musicbrainz.org".utf8) + [0] + Array("rec-1".utf8))
            + frame("POPM", Array("me@example.com".utf8) + [0, 196, 0, 0, 0, 1])
            + frame("TXXX", [0] + Array("REPLAYGAIN_TRACK_GAIN".utf8) + [0] + Array("-3 dB".utf8))
        let header = Data("ID3".utf8) + Data([3, 0, 0]) + ID3Tag.syncsafeBytes(frames.count)
        let audio = Data((0..<4000).map { UInt8($0 % 251) })
        var v1 = AudioTags()
        v1.title = "Old"
        let url = try Self.tempFolder().appendingPathComponent("x.mp3")
        try (header + frames + audio + ID3Tag.id3v1(v1)).write(to: url)

        var tags = AudioTags()
        _ = ID3Tag.apply(try ID3Tag.read(url).frames, to: &tags)
        #expect(tags.title == "Old" && tags.genre == "Rock" && tags.comment == "Hi")
        #expect(tags.musicBrainzRecordingID == "rec-1")

        tags.title = "New"
        tags.comment = ""
        tags.cover = Self.cover((1, 2, 3))
        try ID3Tag.write(tags, to: url, preservingOtherTags: true, keepExistingCover: true)
        let (written, length) = try ID3Tag.read(url)
        let ids = written.map(\.id)
        #expect(ids.contains("POPM") && ids.contains("APIC") && ids.filter { $0 == "COMM" }.count == 1)
        #expect(written.contains { $0.id == "TXXX" && String(decoding: $0.body, as: UTF8.self).contains("REPLAYGAIN") })
        var again = AudioTags()
        let cover = ID3Tag.apply(written, to: &again)
        #expect(again.title == "New" && again.comment.isEmpty && again.genre == "Rock")
        #expect(again.musicBrainzRecordingID == "rec-1")
        #expect(cover == tags.cover?.data)
        let file = try Data(contentsOf: url)
        #expect(file.subdata(in: length..<(length + audio.count)) == audio)
        #expect(file.suffix(128).prefix(3) == Data("TAG".utf8) && file.suffix(125).prefix(3) == Data("New".utf8))
    }

    @Test func id3GenreReferences() {
        #expect(ID3Genres.resolve("(17)") == "Rock")
        #expect(ID3Genres.resolve("(17)Rock") == "Rock")
        #expect(ID3Genres.resolve("52") == "Electronic")
        #expect(ID3Genres.resolve("Trip Hop") == "Trip Hop")
        #expect(ID3Genres.index(of: "rock") == 17)
    }

    @Test func mp4RewriteKeepsAudioAndForeignAtoms() throws {
        let folder = try Self.tempFolder()
        let m4a = try Self.afconvert(try Self.wav(in: folder), to: "a.m4a", ["-f", "m4af", "-d", "alac"])
        let before = try Self.pcm(m4a)
        var tags = Self.sampleTags
        tags.catalogNumber = "CAT 1"
        tags.musicBrainzReleaseID = "rel-1"
        tags.musicBrainzRecordingID = "rec-1"
        tags.cover = Self.cover((9, 9, 9), size: 400)
        try MP4Tag.write(tags, to: m4a, preservingOtherTags: true, keepExistingCover: true)
        #expect(try Self.pcm(m4a) == before)
        var read = AudioTags()
        _ = MP4Tag.apply(try MP4Tag.readItems(m4a), to: &read)
        #expect(read.catalogNumber == "CAT 1" && read.musicBrainzReleaseID == "rel-1" && read.musicBrainzRecordingID == "rec-1")
        #expect(read.label == tags.label && read.albumArtistSort == tags.albumArtistSort)
    }

    @Test(.enabled(if: TagEditorTests.ffmpeg != nil, "needs ffmpeg"))
    func mp4FastStartShiftsChunkOffsets() throws {
        let folder = try Self.tempFolder()
        let wav = try Self.wav(in: folder)
        for codec in [["-c:a", "alac"], ["-c:a", "aac", "-b:a", "128k"]] {
            let m4a = folder.appendingPathComponent("fast-\(codec[1]).m4a")
            // moov before mdat: every change of the metadata size moves the audio.
            try Self.run(Self.ffmpeg!, ["-y", "-loglevel", "error", "-i", wav.path] + codec
                         + ["-metadata", "lyrics=keep me", "-movflags", "+faststart", m4a.path])
            let before = try Self.pcm(m4a)
            var tags = Self.sampleTags
            tags.cover = Self.cover((5, 5, 5), size: 300)
            try MP4Tag.write(tags, to: m4a, preservingOtherTags: true, keepExistingCover: true)
            #expect(try Self.pcm(m4a) == before)
            tags.cover = nil
            tags.title = "Shorter"
            try MP4Tag.write(tags, to: m4a, preservingOtherTags: true, keepExistingCover: false)
            #expect(try Self.pcm(m4a) == before)
            let items = try MP4Tag.readItems(m4a)
            #expect(items.contains { $0.key == "\u{A9}lyr" && $0.payload == Data("keep me".utf8) })
            #expect(!items.contains { $0.key == "covr" })
        }
    }

    /// Broken, truncated and random files must give an error or empty tags – never a crash or a hang.
    @Test func damagedFilesDoNotCrash() async throws {
        let folder = try Self.tempFolder()
        let wav = try Self.wav(in: folder)
        let flac = try Self.afconvert(wav, to: "a.flac", ["-f", "flac", "-d", "flac"])
        let m4a = try Self.afconvert(wav, to: "a.m4a", ["-f", "m4af", "-d", "alac"])
        var tags = Self.sampleTags
        tags.cover = Self.cover((1, 1, 1))
        try FLACTagger.write(tags, to: flac)
        try MP4Tag.write(tags, to: m4a, preservingOtherTags: false, keepExistingCover: false)
        var generator = SystemRandomNumberGenerator()
        for source in [flac, m4a] {
            let data = try Data(contentsOf: source)
            for (n, length) in [10, 100, data.count / 3, data.count / 2, data.count - 7].enumerated() {
                let cut = folder.appendingPathComponent("cut\(n).\(source.pathExtension)")
                try data.prefix(length).write(to: cut)
                _ = try? await TagReader.read(cut)
                _ = try? MP4Tag.readItems(cut)
            }
        }
        for ext in ["flac", "m4a", "mp3"] {
            for n in 0..<20 {
                var bytes = (0..<4096).map { _ in UInt8.random(in: 0...255, using: &generator) }
                // Valid looking headers lead the parsers deeper into the garbage.
                let header: [UInt8] = switch ext {
                case "flac": Array("fLaC".utf8)
                case "mp3": Array("ID3".utf8) + [UInt8(3 + n % 2), 0, UInt8(n % 3 == 0 ? 0x80 : 0), 0, 0, 0x1F, 0x7F]
                default: [0, 0, 0x0F, 0xFF] + Array("moov".utf8)
                }
                bytes.replaceSubrange(0..<header.count, with: header)
                let url = folder.appendingPathComponent("random\(n).\(ext)")
                try Data(bytes).write(to: url)
                _ = try? await TagReader.read(url)
                _ = try? ID3Tag.read(url)
                _ = try? MP4Tag.readItems(url)
                var moov = bytes
                MP4Tag.shiftChunkOffsets(&moov, by: 100, after: 0)
            }
        }
    }

    // MARK: Editor

    @MainActor
    @Test func editorLoadsGroupsEditsSavesAndRenames() async throws {
        let folder = try Self.tempFolder()
        let wav = try Self.wav(in: folder)
        let album = folder.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        for (n, title) in [(1, "First"), (2, "Second")] {
            let file = try Self.afconvert(wav, to: "Album/\(n).flac", ["-f", "flac", "-d", "flac"])
            var tags = Self.sampleTags
            tags.title = title
            tags.track = n
            tags.trackTotal = 2
            try FLACTagger.write(tags, to: file)
        }
        let single = try Self.afconvert(wav, to: "loose.flac", ["-f", "flac", "-d", "flac"])
        try FLACTagger.write(AudioTags(), to: single)

        let editor = TagEditor(configStore: ConfigStore())
        await editor.add([folder])
        #expect(editor.tracks.count == 3)
        #expect(editor.albums.count == 2)
        let entry = try #require(editor.sortedAlbums.first { $0.summary.hasAlbumTag })
        #expect(entry.summary.title == "Ettella Diamant" && entry.summary.trackCount == 2)

        // Adding the same folder again changes nothing.
        await editor.add([folder])
        #expect(editor.tracks.count == 3)

        let ids = editor.tracks(in: entry.album).map(\.id)
        editor.edit(ids) { $0.genre = "Electronic" }
        #expect(editor.modifiedCount == 2)
        editor.revert([ids[1]])
        #expect(editor.modifiedCount == 1)
        await editor.save(ids)
        #expect(editor.modifiedCount == 0)
        #expect(try TagReader.readFLAC(try #require(editor.tracks[ids[0]]).url).tags.genre == "Electronic")
        #expect(try TagReader.readFLAC(try #require(editor.tracks[ids[1]]).url).tags.genre == "Trip Hop")

        let plan = editor.renamePlan(ids, pattern: "{track} - {title}")
        // The sample tags say two discs, so the names get a disc prefix.
        #expect(plan.map(\.newName) == ["1-01 - First.flac", "1-02 - Second.flac"])
        try editor.rename(plan)
        #expect(FileManager.default.fileExists(atPath: album.appendingPathComponent("1-02 - Second.flac").path))
        #expect(editor.tracks[ids[1]]?.fileName == "1-02 - Second.flac")

        editor.removeAll()
    }
}
