import Foundation
import Testing
@testable import MacRipper

@Suite struct ParserTests {
    @Test func makemkvFieldsHandleQuotedCommas() throws {
        let f = try #require(MakeMKV.fields(#"TINFO:3,2,0,"Movie, The""#))
        #expect(f.key == "TINFO")
        #expect(f.values == ["3", "2", "0", "Movie, The"])
    }

    /// Output captured from a real Blu-ray.
    @Test func makemkvInfoParsing() {
        let info = MakeMKV.parseInfo("""
            CINFO:2,0,"Seewolf"
            TINFO:0,2,0,"Seewolf"
            TINFO:0,8,0,"10"
            TINFO:0,9,0,"1:36:06"
            TINFO:0,11,0,"13718446080"
            TINFO:0,16,0,"00001.mpls"
            TINFO:0,27,0,"Seewolf_t00.mkv"
            TINFO:1,2,0,"Seewolf"
            TINFO:1,9,0,"0:00:16"
            TINFO:1,11,0,"36839424"
            TINFO:1,16,0,"00000.m2ts"
            MSG:5011,0,0,"Operation successfully completed","Operation successfully completed"
            """)
        #expect(info.name == "Seewolf")
        #expect(info.titles.count == 2)
        #expect(info.titles[0].durationSeconds == 5766)
        #expect(info.titles[0].chapters == 10)
        #expect(info.titles[0].sizeBytes == 13_718_446_080)
        #expect(info.titles[0].sourceFile == "00001.mpls")
        #expect(info.titles[0].outputFile == "Seewolf_t00.mkv")
        #expect(info.titles[1].durationSeconds == 16)
    }

    @Test func makemkvProgress() {
        #expect(MakeMKV.progress("PRGV:100,32768,65536") == 0.5)
        #expect(MakeMKV.progress("MSG:1005,0,1,\"x\"") == nil)
        #expect(MakeMKV.seconds("1:52:07") == 6727)
    }

    @Test func makemkvDriveMapping() {
        let drives = DiscMonitor.parseDrutilList("""
               Vendor   Product           Rev   Bus       SupportLevel
            1  TSSTcorp BDDVDW SE-506CB   TS02  USB       Unsupported
            """)
        #expect(drives.count == 1)
        #expect(drives[0].vendor == "TSSTcorp")
        #expect(drives[0].product == "BDDVDW SE-506CB")
        #expect(drives[0].bus == "USB")
    }

    @Test func handbrakeProgress() {
        let p = VideoTranscoder.handbrakeProgress("Encoding: task 1 of 1, 45.50 % (63.12 fps, avg 60.01 fps, ETA 00h12m03s)")
        #expect(abs((p ?? 0) - 0.455) < 0.0001)
        let twoPass = VideoTranscoder.handbrakeProgress("Encoding: task 2 of 2, 50.00 %")
        #expect(abs((twoPass ?? 0) - 0.75) < 0.0001)
    }

    @Test func argumentSplitting() {
        #expect(VideoTranscoder.splitArgs(#"--preset "HQ 1080p30 Surround" -q 20"#) == ["--preset", "HQ 1080p30 Surround", "-q", "20"])
    }

    /// Example from https://musicbrainz.org/doc/Disc_ID_Calculation
    @Test func musicBrainzDiscID() {
        let offsets = [150, 15363, 32314, 46592, 63414, 80489]
        let toc = CDTOC(firstTrack: 1, lastTrack: 6, leadoutSector: 95462 - 150,
                        tracks: offsets.enumerated().map { .init(number: $0 + 1, startSector: $1 - 150, isData: false) })
        #expect(toc.musicBrainzDiscID == "49HHV7Eb8UKF3aQiNmu1GR8vKTY-")
        #expect(toc.musicBrainzTOCString == "1 6 95462 150 15363 32314 46592 63414 80489")
    }

    @Test func labelCleaning() {
        #expect(DiscIdentifier.cleanLabel("THE_MATRIX_DISC_1_WS") == "The Matrix")
        #expect(DiscIdentifier.cleanLabel("Inception") == "Inception")
        #expect(DiscIdentifier.looksLikeSeries("FRIENDS_SEASON_3_DISC_2"))
        #expect(!DiscIdentifier.looksLikeSeries("AVATAR"))
    }

    @Test func audioPatterns() {
        let tags = AudioTags(title: "Song/Name", artist: "Band", album: "Album", date: "1999", track: 3)
        #expect(AudioRipper.expand("{artist}/{album} ({year})", tags) == "Band/Album (1999)")
        #expect(AudioRipper.expand("{track} - {title}", tags) == "03 - Song_Name")
        var noYear = tags
        noYear.date = ""
        #expect(AudioRipper.expand("{album} ({year})", noYear) == "Album")
    }

    @Test func flacTaggerWritesVorbisComment() throws {
        // Encode a short silent AIFF to FLAC with afconvert and tag it.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("in.wav")
        try Self.silentWAV().write(to: wav)
        let flac = dir.appendingPathComponent("out.flac")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "flac", "-d", "flac", wav.path, flac.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)

        try FLACTagger.write(AudioTags(title: "Täst", artist: "A", album: "B", date: "2001", track: 1, trackTotal: 9), to: flac)
        let data = try Data(contentsOf: flac)
        #expect(data.prefix(4) == Data("fLaC".utf8))
        #expect(data.range(of: Data("TITLE=Täst".utf8)) != nil)
        #expect(data.range(of: Data("TRACKTOTAL=9".utf8)) != nil)
        // Tagging twice must not duplicate comment blocks.
        try FLACTagger.write(AudioTags(title: "Neu"), to: flac)
        let again = try Data(contentsOf: flac)
        #expect(again.range(of: Data("TITLE=Täst".utf8)) == nil)
        #expect(again.range(of: Data("TITLE=Neu".utf8)) != nil)

        // The tagged file must still decode.
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        check.arguments = ["-f", "WAVE", "-d", "LEI16", flac.path, dir.appendingPathComponent("back.wav").path]
        try check.run(); check.waitUntilExit()
        #expect(check.terminationStatus == 0)
    }

    static func silentWAV(seconds: Int = 1) -> Data {
        let rate = 44100, channels = 2, bytes = rate * channels * 2 * seconds
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        var d = Data("RIFF".utf8) + le32(36 + bytes) + Data("WAVEfmt ".utf8)
        d += le32(16) + le16(1) + le16(channels) + le32(rate) + le32(rate * channels * 2) + le16(channels * 2) + le16(16)
        d += Data("data".utf8) + le32(bytes) + Data(count: bytes)
        return d
    }

    @Test func makemkvVersionFromDownloadPage() {
        let html = #"<a href="https://www.makemkv.com/download/makemkv_v1.18.4_osx.dmg">old</a> <a href="makemkv_v2.0.0_osx.dmg">MakeMKV 2.0.0 for Mac</a> makemkv_v1.9.10_osx.dmg"#
        #expect(ToolManager.parseMakeMKVVersion(html) == "2.0.0")
        #expect(ToolManager.parseMakeMKVVersion("no links") == nil)
    }

    @Test func versionComparison() {
        #expect(ToolManager.compareVersions("1.18.4", "2.0.0") == .orderedAscending)
        #expect(ToolManager.compareVersions("1.9.10", "1.18.0") == .orderedAscending)
        #expect(ToolManager.compareVersions("2.0", "2.0.0") == .orderedSame)
        #expect(ToolManager.compareVersions("2.0.1", "2.0.0") == .orderedDescending)
    }

    @Test func brewInfoParsing() throws {
        let json = #"{"formulae":[{"name":"handbrake","versions":{"stable":"1.11.2"},"installed":[],"outdated":false},{"name":"ffmpeg","versions":{"stable":"9.0.2"},"installed":[{"version":"9.0.1"}],"outdated":true}],"casks":[]}"#
        let info = try #require(ToolManager.parseBrewInfo(Data(json.utf8)))
        #expect(info["handbrake"] == .init(stable: "1.11.2", installed: nil, outdated: false))
        #expect(info["ffmpeg"] == .init(stable: "9.0.2", installed: "9.0.1", outdated: true))
    }

    @Test func hdiutilAttachPlistWithWarning() {
        let out = """
            hdiutil: WARNING: 'hdiutil attach' is deprecated.
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>system-entities</key><array>
            <dict><key>dev-entry</key><string>/dev/disk20</string></dict>
            <dict><key>dev-entry</key><string>/dev/disk20s1</string><key>mount-point</key><string>/Volumes/makemkv_v2.0.0</string></dict>
            </array></dict></plist>
            """
        #expect(ToolManager.mountPoint(fromAttachPlist: out) == "/Volumes/makemkv_v2.0.0")
    }

    @Test func makemkvHashFile() {
        let text = """
            -----BEGIN PGP SIGNED MESSAGE-----
            Hash: SHA256

            f4e609bd34042a95b82a37d036d099a96e4480ff43d2bbb0bee009757bd74b72  Setup_MakeMKV_v2.0.0.exe
            e3adad095fb9344e23870d99fd9770a187816332c5a2aa1b226c0bd4a922867a  makemkv_v2.0.0_osx.dmg
            -----BEGIN PGP SIGNATURE-----
            """
        #expect(ToolManager.parseHashFile(text, file: "makemkv_v2.0.0_osx.dmg")
                == "e3adad095fb9344e23870d99fd9770a187816332c5a2aa1b226c0bd4a922867a")
        #expect(ToolManager.parseHashFile(text, file: "makemkv_v9.9.9_osx.dmg") == nil)
    }

    @Test func webTokenComparison() {
        #expect(WebServer.tokensMatch("abc123", "abc123"))
        #expect(!WebServer.tokensMatch("abc124", "abc123"))
        #expect(!WebServer.tokensMatch("abc", "abc123"))
        #expect(!WebServer.tokensMatch("", ""))
    }

    @Test func formEncodingEscapesReservedCharacters() {
        #expect(Notifier.formEncode(["message": "a&b=c d+e"]) == "message=a%26b%3Dc%20d%2Be")
    }

    @Test func templateRendering() {
        let values = ["title": "Inception (2010)", "duration": "1 hr, 12 min"]
        #expect(NotificationTemplate.render("{title} finished in {duration}.", values: values)
                == "Inception (2010) finished in 1 hr, 12 min.")
        #expect(NotificationTemplate.render("{unknown} {title", values: values) == "{unknown} {title")
        #expect(NotificationTemplate.render("{{title}}", values: values) == "{{title}}")
        #expect(NotificationTemplate.render("no vars", values: values) == "no vars")
    }

    @Test func everyDocumentedVariableHasAValue() {
        let values = NotificationTemplate.values(for: NotificationTemplate.sampleJob)
        for variable in NotificationTemplate.variables {
            #expect(values[variable.name] != nil, "missing \(variable.name)")
        }
        #expect(Set(values.keys) == Set(NotificationTemplate.variables.map(\.name)))
    }

    @Test func remainingTimeEstimate() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(Job.estimateRemaining(progress: 0.25, stageStarted: start, now: start.addingTimeInterval(60)) == 180)
        #expect(Job.estimateRemaining(progress: 0.01, stageStarted: start, now: start.addingTimeInterval(60)) == nil)
        #expect(Job.estimateRemaining(progress: 0.5, stageStarted: start, now: start.addingTimeInterval(5)) == nil)
        #expect(Job.estimateRemaining(progress: 0.5, stageStarted: nil) == nil)
    }

    @Test func ntfyHeaderEncoding() {
        #expect(Notifier.headerSafe("Plain title") == "Plain title")
        #expect(Notifier.headerSafe("Fertig: Bücher") == "=?UTF-8?B?\(Data("Fertig: Bücher".utf8).base64EncodedString())?=")
        #expect(Notifier.headerSafe("a\nb") == "a b")
    }

    @Test func configMergeKeepsDefaultsForMissingKeys() throws {
        let cfg = try AppConfig.decodeMerged(from: Data(#"{"minLengthSeconds": 42, "unknownKey": true}"#.utf8))
        #expect(cfg.minLengthSeconds == 42)
        #expect(cfg.audioFormat == .flac)
    }
}
