import Foundation
import CryptoKit

struct VideoSearchResult: Identifiable, Hashable {
    var id: String { "\(provider)-\(providerID)" }
    let provider: MetadataProvider
    let providerID: String
    let imdbID: String
    let title: String
    let year: String
    let kind: VideoKind
    let posterURL: String
}

/// A MusicBrainz release (one edition of an album) with everything needed for tagging.
struct AudioRelease: Identifiable, Hashable {
    let id: String                   // MusicBrainz release id
    var title = ""
    var artist = ""                  // album artist credit
    var artistSort = ""
    var artistID = ""
    var date = ""
    var originalDate = ""
    var country = ""
    var barcode = ""
    var label = ""
    var catalogNumber = ""
    var genre = ""
    var releaseGroupID = ""
    var format = ""
    var disambiguation = ""
    var discNumber = 1
    var discTotal = 1
    var trackCount = 0
    var hasFrontCover = false
    var tracks: [AudioTrackInfo] = []
    /// Tracks and format of every medium (disc) by position, for tagging files of multi-disc albums.
    var discTracks: [Int: [AudioTrackInfo]] = [:]
    var discFormats: [Int: String] = [:]
    /// Search results only carry a summary; the tracks are loaded when the release is chosen.
    var isComplete: Bool { !tracks.isEmpty }

    var year: String { String(date.prefix(4)) }
    var isCompilation: Bool { artistID == Job.variousArtistsID }

    /// One line describing the edition, e.g. "2001 · DE · CD · Virgin · 7243 8 10123 2 3".
    var editionSummary: String {
        [date, country, format, label, catalogNumber, disambiguation]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct AudioTrackInfo: Hashable {
    let number: Int
    var title = ""
    var artist = ""
    var artistID = ""
    var recordingID = ""
    var releaseTrackID = ""
    var isrc = ""
    var length = 0                   // seconds, 0 = unknown
}

/// A recording found by a song search, together with one release it appears on.
struct RecordingMatch: Identifiable, Hashable {
    var id: String { "\(recordingID)-\(releaseID)" }
    let recordingID: String
    let title: String
    let artist: String
    let length: Int                  // seconds, 0 = unknown
    let releaseID: String
    let releaseTitle: String
    let releaseArtist: String
    let date: String
    let country: String
    let format: String
    let trackNumber: String          // as printed on the release, e.g. "3" or "A3"
    let releaseType: String          // Album, Single, Compilation …
    let official: Bool

    var releaseSummary: String {
        [releaseTitle, date, country, format, releaseType].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

enum MetadataError: LocalizedError {
    case missingKey(String), badResponse(String)
    var errorDescription: String? {
        switch self {
        case .missingKey(let p): "No API key configured for \(p)"
        case .badResponse(let m): "Invalid response: \(m)"
        }
    }
}

/// OMDb / TMDb / MusicBrainz lookups (ARM: METADATA_PROVIDER, abcde/MusicBrainz).
enum Metadata {
    static let userAgent = "MacRipper/1.0 ( https://github.com/automatic-ripping-machine/automatic-ripping-machine )"

    private static func getJSON(_ url: URL, headers: [String: String] = [:]) async throws -> Any {
        guard url.host == "musicbrainz.org" else { return try await getJSONOnce(url, headers: headers) }
        // MusicBrainz allows one request per second and answers 503 when that is exceeded.
        var attempt = 0
        while true {
            await MusicBrainzThrottle.shared.wait()
            do {
                return try await getJSONOnce(url, headers: headers)
            } catch MetadataError.badResponse("HTTP 503") where attempt < 3 {
                attempt += 1
                try await Task.sleep(for: .seconds(Double(attempt) * 1.5))
            }
        }
    }

    private static func getJSONOnce(_ url: URL, headers: [String: String]) async throws -> Any {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return [String: Any]() }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MetadataError.badResponse("HTTP \(http.statusCode)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func url(_ base: String, _ query: [String: String]) -> URL {
        var c = URLComponents(string: base)!
        c.queryItems = query.filter { !$0.value.isEmpty }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }

    // MARK: Video

    static func searchVideo(_ query: String, year: String = "", config: AppConfig) async throws -> [VideoSearchResult] {
        switch config.metadataProvider {
        case .omdb: try await searchOMDb(query, year: year, key: config.omdbAPIKey)
        case .tmdb: try await searchTMDb(query, year: year, key: config.tmdbAPIKey)
        case .none: []
        }
    }

    static func searchOMDb(_ query: String, year: String, key: String) async throws -> [VideoSearchResult] {
        guard !key.isEmpty else { throw MetadataError.missingKey("OMDb") }
        let json = try await getJSON(url("https://www.omdbapi.com/", ["apikey": key, "s": query, "y": year]))
        let items = (json as? [String: Any])?["Search"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let title = item["Title"] as? String, let imdb = item["imdbID"] as? String else { return nil }
            let type = item["Type"] as? String
            let poster = item["Poster"] as? String ?? ""
            return VideoSearchResult(provider: .omdb, providerID: imdb, imdbID: imdb, title: title,
                                     year: String((item["Year"] as? String ?? "").prefix(4)),
                                     kind: type == "series" ? .series : type == "movie" ? .movie : .unknown,
                                     posterURL: poster == "N/A" ? "" : poster)
        }
    }

    static func searchTMDb(_ query: String, year: String, key: String) async throws -> [VideoSearchResult] {
        guard !key.isEmpty else { throw MetadataError.missingKey("TMDb") }
        // Long keys are v4 read access tokens (Bearer), short ones v3 API keys.
        let bearer = key.count > 40
        let json = try await getJSON(
            url("https://api.themoviedb.org/3/search/multi", ["query": query, "api_key": bearer ? "" : key]),
            headers: bearer ? ["Authorization": "Bearer \(key)"] : [:])
        let items = (json as? [String: Any])?["results"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            let media = item["media_type"] as? String
            guard media == "movie" || media == "tv", let id = item["id"] as? Int else { return nil }
            let title = (item["title"] ?? item["name"]) as? String ?? ""
            let date = (item["release_date"] ?? item["first_air_date"]) as? String ?? ""
            let poster = (item["poster_path"] as? String).map { "https://image.tmdb.org/t/p/w342\($0)" } ?? ""
            return VideoSearchResult(provider: .tmdb, providerID: String(id), imdbID: "", title: title,
                                     year: String(date.prefix(4)), kind: media == "tv" ? .series : .movie,
                                     posterURL: poster)
        }
        .filter { year.isEmpty || $0.year == year || $0.year.isEmpty }
    }

    /// ARM style identification: search the cleaned label, retrying with fewer words.
    static func identifyVideo(label: String, config: AppConfig) async -> VideoSearchResult? {
        var words = DiscIdentifier.cleanLabel(label).split(separator: " ").map(String.init)
        while !words.isEmpty {
            if let hit = try? await searchVideo(words.joined(separator: " "), config: config).first { return hit }
            words.removeLast()
        }
        return nil
    }

    // MARK: Audio

    private static let releaseIncludes = "artist-credits recordings labels release-groups isrcs genres"

    static func lookupDisc(_ toc: CDTOC) async throws -> [AudioRelease] {
        let json = try await getJSON(url("https://musicbrainz.org/ws/2/discid/\(toc.musicBrainzDiscID)", [
            "toc": toc.musicBrainzTOCString, "inc": releaseIncludes, "fmt": "json", "cdstubs": "no",
        ]))
        let releases = (json as? [String: Any])?["releases"] as? [[String: Any]] ?? []
        return releases.map { parseRelease($0, discID: toc.musicBrainzDiscID, trackCount: toc.tracks.count) }
    }

    /// Text search. Accepts "artist album", a MusicBrainz release ID or a musicbrainz.org release URL.
    /// Results are summaries; load the full release with `release(id:trackCount:)` before using it.
    static func searchReleases(_ query: String, trackCount: Int) async throws -> [AudioRelease] {
        if let id = releaseID(in: query) { return [try await release(id: id, trackCount: trackCount)] }
        let lucene = "\(query) AND tracks:\(trackCount) AND format:*CD*"
        let json = try await getJSON(url("https://musicbrainz.org/ws/2/release", [
            "query": lucene, "fmt": "json", "limit": "25",
        ]))
        var results = ((json as? [String: Any])?["releases"] as? [[String: Any]] ?? [])
            .map { parseRelease($0, discID: nil, trackCount: trackCount) }
        if results.isEmpty {
            // Some editions are not tagged with a CD format; retry without it.
            let json = try await getJSON(url("https://musicbrainz.org/ws/2/release", [
                "query": "\(query) AND tracks:\(trackCount)", "fmt": "json", "limit": "25",
            ]))
            results = ((json as? [String: Any])?["releases"] as? [[String: Any]] ?? [])
                .map { parseRelease($0, discID: nil, trackCount: trackCount) }
        }
        return results
    }

    /// Release search for files of an existing album: releases with the same number of tracks first, then any
    /// release matching the text (the files may be only part of an album, or of a different edition).
    static func searchReleasesForFiles(_ query: String, trackCount: Int) async throws -> [AudioRelease] {
        if let id = releaseID(in: query) { return [try await release(id: id, trackCount: trackCount)] }
        func search(_ lucene: String) async throws -> [AudioRelease] {
            let json = try await getJSON(url("https://musicbrainz.org/ws/2/release", [
                "query": lucene, "fmt": "json", "limit": "25",
            ]))
            return ((json as? [String: Any])?["releases"] as? [[String: Any]] ?? [])
                .map { parseRelease($0, discID: nil, trackCount: trackCount) }
        }
        let exact = trackCount > 0 ? try await search("\(query) AND tracksmedium:\(trackCount)") : []
        var seen = Set(exact.map(\.id))
        let any = try await search(query).filter { seen.insert($0.id).inserted }
        return exact + any
    }

    /// Song search by title and artist (and optionally album). Every release of a recording becomes one match,
    /// official albums first.
    static func searchRecordings(title: String, artist: String, album: String = "") async throws -> [RecordingMatch] {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "") + "\""
        }
        var parts = ["recording:\(quoted(title))"]
        if !artist.isEmpty { parts.append("artist:\(quoted(artist))") }
        if !album.isEmpty { parts.append("release:\(quoted(album))") }
        let json = try await getJSON(url("https://musicbrainz.org/ws/2/recording", [
            "query": parts.joined(separator: " AND "), "fmt": "json", "limit": "25",
        ]))
        return parseRecordings(json)
    }

    static func parseRecordings(_ json: Any) -> [RecordingMatch] {
        var matches: [RecordingMatch] = []
        for r in (json as? [String: Any])?["recordings"] as? [[String: Any]] ?? [] {
            let recordingID = r["id"] as? String ?? ""
            let artist = artistCredit(r["artist-credit"])
            for release in r["releases"] as? [[String: Any]] ?? [] {
                let group = release["release-group"] as? [String: Any] ?? [:]
                let medium = (release["media"] as? [[String: Any]])?.first
                let track = (medium?["track"] as? [[String: Any]])?.first
                let releaseArtist = artistCredit(release["artist-credit"])
                let secondary = group["secondary-types"] as? [String] ?? []
                matches.append(RecordingMatch(
                    recordingID: recordingID,
                    title: r["title"] as? String ?? "",
                    artist: artist,
                    length: (r["length"] as? Int ?? 0) / 1000,
                    releaseID: release["id"] as? String ?? "",
                    releaseTitle: release["title"] as? String ?? "",
                    releaseArtist: releaseArtist.isEmpty ? artist : releaseArtist,
                    date: release["date"] as? String ?? "",
                    country: release["country"] as? String ?? "",
                    format: medium?["format"] as? String ?? "",
                    trackNumber: track?["number"] as? String ?? "",
                    releaseType: secondary.first ?? group["primary-type"] as? String ?? "",
                    official: (release["status"] as? String ?? "Official") == "Official"))
            }
        }
        // Official albums are what most people want to tag a song with; the order within each group is MusicBrainz's.
        func rank(_ m: RecordingMatch) -> Int { (m.official ? 0 : 2) + (m.releaseType == "Album" ? 0 : 1) }
        return matches.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    static func releaseID(in text: String) -> String? {
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let isOtherEntity = ["/release-group/", "/artist/", "/recording/", "/label/"].contains { text.contains($0) }
        return isOtherEntity ? nil : String(text[range]).lowercased()
    }

    static func release(id: String, trackCount: Int) async throws -> AudioRelease {
        let json = try await getJSON(url("https://musicbrainz.org/ws/2/release/\(id)", [
            "inc": releaseIncludes, "fmt": "json",
        ]))
        guard let dict = json as? [String: Any], dict["id"] != nil else { throw MetadataError.badResponse("release not found") }
        return parseRelease(dict, discID: nil, trackCount: trackCount)
    }

    private static func artistCredit(_ any: Any?) -> String {
        (any as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? "") + ($0["joinphrase"] as? String ?? "") }
            .joined()
    }

    private static func firstArtist(_ any: Any?) -> [String: Any]? {
        (any as? [[String: Any]])?.first?["artist"] as? [String: Any]
    }

    /// Most voted genre, capitalized like "Trip Hop".
    static func topGenre(_ lists: Any?...) -> String {
        for list in lists {
            let genres = (list as? [[String: Any]] ?? [])
                .sorted { ($0["count"] as? Int ?? 0) > ($1["count"] as? Int ?? 0) }
            if let name = genres.first?["name"] as? String, !name.isEmpty {
                return name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            }
        }
        return ""
    }

    static func parseRelease(_ r: [String: Any], discID: String?, trackCount: Int) -> AudioRelease {
        let media = r["media"] as? [[String: Any]] ?? []
        let medium = media.first { m in
            guard let discID else { return false }
            return (m["discs"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == discID }
        } ?? media.first { ($0["track-count"] as? Int) == trackCount && $0["tracks"] != nil }
            ?? media.first { $0["tracks"] != nil } ?? media.first
        let group = r["release-group"] as? [String: Any] ?? [:]
        let labelInfo = (r["label-info"] as? [[String: Any]])?.first
        let albumArtist = artistCredit(r["artist-credit"])
        let albumArtistInfo = firstArtist(r["artist-credit"])

        var release = AudioRelease(id: r["id"] as? String ?? "")
        release.title = r["title"] as? String ?? ""
        release.artist = albumArtist
        release.artistID = albumArtistInfo?["id"] as? String ?? ""
        release.artistSort = (r["artist-credit"] as? [[String: Any]])?.count == 1
            ? albumArtistInfo?["sort-name"] as? String ?? "" : ""
        release.date = r["date"] as? String ?? ""
        release.originalDate = group["first-release-date"] as? String ?? ""
        release.country = r["country"] as? String ?? ""
        release.barcode = r["barcode"] as? String ?? ""
        release.label = (labelInfo?["label"] as? [String: Any])?["name"] as? String ?? ""
        release.catalogNumber = labelInfo?["catalog-number"] as? String ?? ""
        release.genre = topGenre(r["genres"], group["genres"])
        release.releaseGroupID = group["id"] as? String ?? ""
        release.disambiguation = r["disambiguation"] as? String ?? ""
        release.format = medium?["format"] as? String ?? ""
        release.discNumber = medium?["position"] as? Int ?? 1
        release.discTotal = max(media.count, r["medium-count"] as? Int ?? 0, 1)
        release.trackCount = medium?["track-count"] as? Int ?? (r["track-count"] as? Int ?? 0)
        release.hasFrontCover = (r["cover-art-archive"] as? [String: Any])?["front"] as? Bool ?? false
        func tracks(_ medium: [String: Any]?) -> [AudioTrackInfo] {
            (medium?["tracks"] as? [[String: Any]] ?? []).enumerated().map { idx, t in
                let recording = t["recording"] as? [String: Any] ?? [:]
                let credit = t["artist-credit"] ?? recording["artist-credit"]
                var track = AudioTrackInfo(number: t["position"] as? Int ?? idx + 1)
                track.title = t["title"] as? String ?? recording["title"] as? String ?? "Track \(idx + 1)"
                let artist = artistCredit(credit)
                track.artist = artist.isEmpty ? albumArtist : artist
                track.artistID = firstArtist(credit)?["id"] as? String ?? ""
                track.recordingID = recording["id"] as? String ?? ""
                track.releaseTrackID = t["id"] as? String ?? ""
                track.isrc = (recording["isrcs"] as? [String])?.first ?? ""
                track.length = (t["length"] as? Int ?? recording["length"] as? Int ?? 0) / 1000
                return track
            }
        }
        release.tracks = tracks(medium)
        for (index, m) in media.enumerated() where m["tracks"] != nil {
            let position = m["position"] as? Int ?? index + 1
            release.discTracks[position] = tracks(m)
            release.discFormats[position] = m["format"] as? String ?? ""
        }
        return release
    }

    static func downloadImage(_ urlString: String, to dest: URL) async {
        guard let url = URL(string: urlString) else { return }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let (data, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
            try? data.write(to: dest)
        }
    }
}

/// Table of contents of an audio CD, read from the `.TOC.plist` macOS exposes on mounted audio CDs.
struct CDTOC: Equatable {
    struct Track: Equatable { let number: Int; let startSector: Int; let isData: Bool }
    let firstTrack: Int
    let lastTrack: Int
    let leadoutSector: Int
    let tracks: [Track]

    init(firstTrack: Int, lastTrack: Int, leadoutSector: Int, tracks: [Track]) {
        self.firstTrack = firstTrack
        self.lastTrack = lastTrack
        self.leadoutSector = leadoutSector
        self.tracks = tracks
    }

    init?(mountPoint: String) {
        let url = URL(fileURLWithPath: mountPoint).appendingPathComponent(".TOC.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let sessions = plist["Sessions"] as? [[String: Any]], let first = sessions.first
        else { return nil }
        // The MusicBrainz disc ID only covers the first (audio) session.
        let trackArray = first["Track Array"] as? [[String: Any]] ?? []
        let tracks = trackArray.compactMap { t -> Track? in
            guard let n = t["Point"] as? Int, let start = t["Start Block"] as? Int else { return nil }
            return Track(number: n, startSector: start, isData: t["Data"] as? Bool ?? false)
        }.filter { !$0.isData }
        guard let leadout = first["Leadout Block"] as? Int, !tracks.isEmpty else { return nil }
        self.init(firstTrack: tracks.first!.number, lastTrack: tracks.last!.number,
                  leadoutSector: leadout, tracks: tracks)
    }

    /// Track durations in seconds (75 sectors per second).
    var durations: [Int] {
        tracks.indices.map { i in
            let end = i + 1 < tracks.count ? tracks[i + 1].startSector : leadoutSector
            return max(0, (end - tracks[i].startSector) / 75)
        }
    }

    /// https://musicbrainz.org/doc/Disc_ID_Calculation
    var musicBrainzDiscID: String {
        var s = String(format: "%02X%02X%08X", firstTrack, lastTrack, leadoutSector + 150)
        for n in 1...99 {
            let offset = tracks.first { $0.number == n }.map { $0.startSector + 150 } ?? 0
            s += String(format: "%08X", offset)
        }
        let digest = Insecure.SHA1.hash(data: Data(s.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: ".")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
    }

    var musicBrainzTOCString: String {
        ([firstTrack, lastTrack, leadoutSector + 150] + tracks.map { $0.startSector + 150 })
            .map(String.init).joined(separator: " ")
    }
}

/// Spaces MusicBrainz requests at least 1.1 s apart across the whole app.
actor MusicBrainzThrottle {
    static let shared = MusicBrainzThrottle()
    private var next = ContinuousClock.now

    func wait() async {
        let now = ContinuousClock.now
        let slot = max(now, next)
        next = slot + .milliseconds(1100)
        if slot > now { try? await Task.sleep(until: slot, clock: .continuous) }
    }
}
