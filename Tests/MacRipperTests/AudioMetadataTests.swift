import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import MacRipper

@Suite struct AudioMetadataTests {
    /// Trimmed MusicBrainz discid response (inc=artist-credits recordings labels release-groups isrcs genres).
    static let discLookup = #"""
    {"releases":[{"id":"d3dc4be9-9749-4959-99e5-133d0cb467fe","title":"Ettella Diamant","date":"2004-05-03",
      "country":"SK","barcode":"8586010200415","disambiguation":"","genres":[],
      "cover-art-archive":{"front":true},
      "artist-credit":[{"name":"Ettella Diamant","joinphrase":"","artist":{"id":"43b30031-071e-42df-ac2c-4f7a301e235b","name":"Ettella Diamant","sort-name":"Ettella Diamant"}}],
      "label-info":[{"catalog-number":"DR E006","label":{"name":"Deadred Records"}}],
      "release-group":{"id":"1e18709f-ae50-39de-aef5-3cce3229791b","first-release-date":"2004",
        "genres":[{"name":"downtempo","count":1},{"name":"trip hop","count":3},{"name":"electronic","count":2}]},
      "media":[{"position":1,"format":"CD","track-count":2,"discs":[{"id":"49HHV7Eb8UKF3aQiNmu1GR8vKTY-"}],
        "tracks":[
          {"id":"942fb138-d6ff-3f79-85ec-090084191e83","position":1,"title":"Rysperdal Gstp",
           "artist-credit":[{"name":"Ettella Diamant","joinphrase":"","artist":{"id":"43b30031-071e-42df-ac2c-4f7a301e235b"}}],
           "recording":{"id":"9b743096-62a0-493f-9d8a-bdde49ca0669","isrcs":["SKA010400001"]}},
          {"id":"aaaa0000-0000-0000-0000-000000000002","position":2,"title":"Duet",
           "artist-credit":[{"name":"Ettella Diamant","joinphrase":" feat. ","artist":{"id":"43b30031-071e-42df-ac2c-4f7a301e235b"}},
                            {"name":"Guest","joinphrase":"","artist":{"id":"bbbb0000-0000-0000-0000-000000000002"}}],
           "recording":{"id":"cccc0000-0000-0000-0000-000000000002","isrcs":[]}}]}]}]}
    """#

    @Test func parsesFullRelease() throws {
        let json = try #require(JSONSerialization.jsonObject(with: Data(Self.discLookup.utf8)) as? [String: Any])
        let release = Metadata.parseRelease((json["releases"] as! [[String: Any]])[0],
                                            discID: "49HHV7Eb8UKF3aQiNmu1GR8vKTY-", trackCount: 2)
        #expect(release.title == "Ettella Diamant")
        #expect(release.artist == "Ettella Diamant")
        #expect(release.date == "2004-05-03")
        #expect(release.year == "2004")
        #expect(release.originalDate == "2004")
        #expect(release.label == "Deadred Records")
        #expect(release.catalogNumber == "DR E006")
        #expect(release.barcode == "8586010200415")
        #expect(release.genre == "Trip Hop")              // most voted release group genre
        #expect(release.format == "CD")
        #expect(release.hasFrontCover)
        #expect(!release.isCompilation)
        #expect(release.tracks.count == 2)
        #expect(release.tracks[0].isrc == "SKA010400001")
        #expect(release.tracks[0].recordingID == "9b743096-62a0-493f-9d8a-bdde49ca0669")
        #expect(release.tracks[1].artist == "Ettella Diamant feat. Guest")
        #expect(release.editionSummary == "2004-05-03 · SK · CD · Deadred Records · DR E006")
    }

    @Test func releaseIDFromLinks() {
        #expect(Metadata.releaseID(in: "https://musicbrainz.org/release/d3dc4be9-9749-4959-99e5-133d0cb467fe")
                == "d3dc4be9-9749-4959-99e5-133d0cb467fe")
        #expect(Metadata.releaseID(in: "D3DC4BE9-9749-4959-99E5-133D0CB467FE") == "d3dc4be9-9749-4959-99e5-133d0cb467fe")
        #expect(Metadata.releaseID(in: "https://musicbrainz.org/release-group/1e18709f-ae50-39de-aef5-3cce3229791b") == nil)
        #expect(Metadata.releaseID(in: "Daft Punk Discovery") == nil)
    }

    @Test func appleMusicArtworkAndMatching() {
        #expect(CoverArt.appleMusicArtwork("https://is1-ssl.mzstatic.com/image/thumb/a/b.jpg/100x100bb.jpg", size: 3000)
                == "https://is1-ssl.mzstatic.com/image/thumb/a/b.jpg/3000x3000bb.jpg")
        #expect(CoverArt.matches(album: "Discovery (Remastered)", wanted: "Discovery"))
        #expect(CoverArt.matches(album: "Random Access Memories", wanted: "Discovery") == false)
        #expect(CoverArt.matches(artist: "Beyoncé", wanted: "Beyonce"))
        #expect(CoverArt.matches(artist: "Simon & Garfunkel", wanted: "Simon and Garfunkel"))
        #expect(CoverArt.matches(artist: "Daft Punk", wanted: "Justice") == false)
    }

    @Test func bestCoverPrefersSharpSquareImages() {
        func candidate(_ source: String) -> CoverCandidate {
            CoverCandidate(source: source, imageURL: URL(string: "https://example.com/\(source)")!,
                           thumbnailURL: URL(string: "https://example.com/t")!, caption: "")
        }
        let caa = (candidate("Cover Art Archive"), Data(), CoverArt.ImageInfo(width: 500, height: 500, format: "jpeg"))
        let apple = (candidate("Apple Music"), Data(), CoverArt.ImageInfo(width: 3000, height: 3000, format: "jpeg"))
        let booklet = (candidate("Scan"), Data(), CoverArt.ImageInfo(width: 6000, height: 3000, format: "jpeg"))
        #expect(CoverArt.best(of: [caa, apple, booklet])?.0.source == "Apple Music")
        let caaBig = (candidate("Cover Art Archive"), Data(), CoverArt.ImageInfo(width: 3000, height: 3000, format: "jpeg"))
        #expect(CoverArt.best(of: [apple, caaBig])?.0.source == "Cover Art Archive")   // ties go to the exact edition
    }

    @Test func multiDiscFilePattern() {
        #expect(AudioRipper.filePattern("{track} - {title}", discTotal: 1) == "{track} - {title}")
        #expect(AudioRipper.filePattern("{track} - {title}", discTotal: 2) == "{disc}-{track} - {title}")
        #expect(AudioRipper.filePattern("{disc}.{track}", discTotal: 2) == "{disc}.{track}")
        let tags = AudioTags(title: "Intro", artist: "Guest", album: "Live", albumArtist: "Band", date: "1999-01-01",
                             track: 1, disc: 2, discTotal: 2, genre: "Rock")
        #expect(AudioRipper.expand("{artist}/{album} ({year})/{disc}-{track} {trackartist}", tags)
                == "Band/Live (1999)/2-01 Guest")
    }

    static func makeJPEG(width: Int, height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    @Test func embeddedCoverIsOriginalOrDownscaled() throws {
        let id = UUID()
        defer { for ext in ["jpg", "png"] { try? FileManager.default.removeItem(at: CoverArt.coversFolder.appendingPathComponent("\(id).\(ext)")) } }
        let big = Self.makeJPEG(width: 4000, height: 4000)
        let info = try #require(CoverArt.imageInfo(big))
        #expect(info == CoverArt.ImageInfo(width: 4000, height: 4000, format: "jpeg"))
        let cover = try CoverArt.store(big, info: info, source: "Test", jobID: id)
        #expect(try Data(contentsOf: cover.url) == big)                     // stored without recompression

        let scaled = try #require(CoverArt.embeddedData(cover, maxPixels: 3000))
        #expect(scaled.width == 3000 && scaled.height == 3000)
        #expect(CoverArt.embeddedData(cover, maxPixels: 0) == nil)

        let small = Self.makeJPEG(width: 1200, height: 1200)
        let smallCover = try CoverArt.store(small, info: CoverArt.imageInfo(small)!, source: "Test", jobID: id)
        #expect(CoverArt.embeddedData(smallCover, maxPixels: 3000)?.data == small)   // original kept when it fits
    }

    /// Encodes a short track to FLAC, M4A and MP3 with full tags and a cover, then reads everything back with ffprobe.
    @Test(.enabled(if: Tools.ffmpeg(AppConfig()) != nil && Tools.ffprobe != nil))
    func endToEndTagging() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("in.wav")
        try ParserTests.silentWAV().write(to: wav)

        let coverData = Self.makeJPEG(width: 1400, height: 1400)
        var tags = AudioTags(title: "Rysperdal Gstp", artist: "Ettella Diamant feat. Guest", album: "Ettella Diamant",
                             albumArtist: "Ettella Diamant", date: "2004-05-03", track: 1, trackTotal: 6,
                             disc: 1, discTotal: 2, genre: "Trip Hop")
        tags.label = "Deadred Records"
        tags.catalogNumber = "DR E006"
        tags.isrc = "SKA010400001"
        tags.musicBrainzReleaseID = "d3dc4be9-9749-4959-99e5-133d0cb467fe"
        tags.cover = AudioTags.EmbeddedCover(data: coverData, format: "jpeg", width: 1400, height: 1400)

        for format in [AudioFormat.flac, .alac, .mp3] {
            var config = AppConfig()
            config.audioFormat = format
            let out = dir.appendingPathComponent("track.\(format.fileExtension)")
            try await AudioRipper(config: config).encode(wav, to: out, tags: tags, runner: ProcessRunner(), log: nil)
            let probe = try await ProcessRunner().run(Tools.ffprobe!, [
                "-v", "error", "-show_entries", "format_tags:stream=codec_type,width,height", "-of", "json", out.path])
            let json = try #require(JSONSerialization.jsonObject(with: Data(probe.utf8)) as? [String: Any])
            let formatTags = ((json["format"] as? [String: Any])?["tags"] as? [String: String] ?? [:])
                .reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
            #expect(formatTags["title"] == "Rysperdal Gstp", "\(format)")
            #expect(formatTags["artist"] == "Ettella Diamant feat. Guest", "\(format)")
            #expect(formatTags["album_artist"] ?? formatTags["albumartist"] == "Ettella Diamant", "\(format)")
            #expect(formatTags["genre"] == "Trip Hop", "\(format)")
            #expect(formatTags["date"]?.hasPrefix("2004") == true, "\(format)")
            #expect((formatTags["track"] ?? formatTags["tracknumber"])?.hasPrefix("1") == true, "\(format)")
            #expect((formatTags["disc"] ?? formatTags["discnumber"])?.hasPrefix("1") == true, "\(format)")
            if format != .alac {
                #expect(formatTags["musicbrainz_albumid"] ?? formatTags["musicbrainz album id"]
                        == "d3dc4be9-9749-4959-99e5-133d0cb467fe", "\(format)")
                #expect(formatTags["isrc"] ?? formatTags["tsrc"] == "SKA010400001", "\(format)")
            }
            let streams = json["streams"] as? [[String: Any]] ?? []
            let picture = streams.first { $0["codec_type"] as? String == "video" }
            #expect(picture?["width"] as? Int == 1400, "cover in \(format)")
            #expect(picture?["height"] as? Int == 1400, "cover in \(format)")
        }
    }
}

/// Talks to MusicBrainz, Cover Art Archive and Apple Music. Run with MACRIPPER_NETWORK_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACRIPPER_NETWORK_TESTS"] == "1"))
struct OnlineMetadataTests {
    @Test func discLookupAndBestCover() async throws {
        // TOC of the CD from the MusicBrainz disc ID documentation (Ettella Diamant – Ettella Diamant).
        let offsets = [150, 15363, 32314, 46592, 63414, 80489]
        let toc = CDTOC(firstTrack: 1, lastTrack: 6, leadoutSector: 95462 - 150,
                        tracks: offsets.enumerated().map { .init(number: $0 + 1, startSector: $1 - 150, isData: false) })
        let release = try #require(try await Metadata.lookupDisc(toc).first)
        #expect(release.title == "Ettella Diamant")
        #expect(release.tracks.count == 6)
        #expect(!release.genre.isEmpty)

        let best = await CoverArt.findBest(releaseID: release.id, releaseGroupID: release.releaseGroupID,
                                           artist: release.artist, album: release.title, trackCount: 6,
                                           includeAppleMusic: true, log: nil)
        let (candidate, _, info) = try #require(best)
        print("Best cover: \(candidate.source) \(info.width)×\(info.height)")
        #expect(info.width >= 500)
    }

    @Test func appleMusicDeliversHighResolution() async throws {
        let candidates = await CoverArt.appleMusic(artist: "Daft Punk", album: "Discovery", trackCount: 14)
        let first = try #require(candidates.first)
        let (_, info) = try await CoverArt.download(first)
        print("Apple Music cover: \(info.width)×\(info.height)")
        #expect(info.width == 3000 && info.height == 3000)
    }

    @Test func textSearchFindsEditions() async throws {
        let results = try await Metadata.searchReleases("Daft Punk Discovery", trackCount: 14)
        #expect(!results.isEmpty)
        #expect(results.contains { $0.title == "Discovery" })
        let full = try await Metadata.release(id: results.first { $0.title == "Discovery" }!.id, trackCount: 14)
        #expect(full.tracks.count == 14)
        print("Edition: \(full.editionSummary), genre \(full.genre), first track \(full.tracks[0].title)")
    }
}

@Suite struct RetagTests {
    /// Edit an already ripped CD, write the tags back and check files, folder and cover follow.
    @MainActor @Test func rewritesTagsAndRenamesAfterEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigStore()
        let previous = store.config
        defer { store.config = previous }
        store.config.musicPath = root.path
        store.config.audioFormat = .flac
        store.config.audioFolderPattern = "{artist}/{album} ({year})"
        store.config.audioFilePattern = "{track} - {title}"
        let manager = JobManager(configStore: store, monitor: DiscMonitor())

        // A finished rip with a typo in the album name.
        let oldFolder = root.appendingPathComponent("Daft Punk/Discovry (2001)")
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        let wav = root.appendingPathComponent("in.wav")
        try ParserTests.silentWAV().write(to: wav)
        let flac = oldFolder.appendingPathComponent("01 - One More Time.flac")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "flac", "-d", "flac", wav.path, flac.path]
        try p.run(); p.waitUntilExit()

        var job = Job(devicePath: "/dev/disk9")
        job.discType = .audioCD
        job.status = .success
        job.artist = "Daft Punk"
        job.album = "Discovry"
        job.year = "2001"
        job.outputPath = oldFolder.path
        job.audioInfo = AudioAlbumInfo()
        job.titles = [DiscTitle(id: 1, name: "One More Time", outputFile: flac.lastPathComponent, ripped: true)]
        manager.insertForDebug([job])
        let cover = AudioMetadataTests.makeJPEG(width: 1000, height: 1000)
        let coverFile = root.appendingPathComponent("c.jpg")
        try cover.write(to: coverFile)
        try manager.useCoverFile(job.id, coverFile)
        defer { manager.removeCover(job.id) }

        manager.setIdentification(job.id) { $0.album = "Discovery" }
        #expect(manager.job(job.id)?.audioInfo?.tagsChangedAfterRip == true)

        await manager.writeTagsToFiles(job.id)
        #expect(manager.retagErrors[job.id] == nil)
        let newFolder = root.appendingPathComponent("Daft Punk/Discovery (2001)")
        let newFile = newFolder.appendingPathComponent("01 - One More Time.flac")
        #expect(FileManager.default.fileExists(atPath: newFile.path))
        #expect(FileManager.default.fileExists(atPath: newFolder.appendingPathComponent("cover.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: oldFolder.path))             // old empty folder removed
        let data = try Data(contentsOf: newFile)
        #expect(data.range(of: Data("ALBUM=Discovery".utf8)) != nil)
        #expect(data.range(of: cover) != nil)                                           // cover embedded unchanged
        #expect(manager.job(job.id)?.outputPath == newFolder.path)
        #expect(manager.job(job.id)?.audioInfo?.tagsChangedAfterRip == false)
    }
}
