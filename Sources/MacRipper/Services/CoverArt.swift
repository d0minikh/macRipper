import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One possible album cover from an online source.
struct CoverCandidate: Identifiable, Hashable {
    var id: String { imageURL.absoluteString }
    let source: String
    let imageURL: URL                // full resolution
    let thumbnailURL: URL
    let caption: String
    /// Known size before downloading (Apple Music delivers exactly this), otherwise nil.
    var expectedSize: Int?
}

/// Finds, measures and stores album covers in the best available quality.
enum CoverArt {
    static let appleMusicSize = 3000

    // MARK: Searching

    static func candidates(releaseID: String, releaseGroupID: String, artist: String, album: String,
                           trackCount: Int, includeAppleMusic: Bool) async -> [CoverCandidate] {
        async let release = coverArtArchive(path: releaseID.isEmpty ? nil : "release/\(releaseID)", caption: "This edition")
        async let group = coverArtArchive(path: releaseGroupID.isEmpty ? nil : "release-group/\(releaseGroupID)",
                                          caption: "Any edition of the album")
        async let apple = includeAppleMusic
            ? appleMusic(artist: artist, album: album, trackCount: trackCount) : []
        var seen = Set<URL>()
        return (await release + group + apple).filter { seen.insert($0.imageURL).inserted }
    }

    /// Front covers of a Cover Art Archive release or release group (originals, often scans in full size).
    static func coverArtArchive(path: String?, caption: String) async -> [CoverCandidate] {
        guard let path, let url = URL(string: "https://coverartarchive.org/\(path)"),
              let data = try? await fetch(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return (json["images"] as? [[String: Any]] ?? []).compactMap { image in
            guard image["front"] as? Bool == true || (image["types"] as? [String] ?? []).contains("Front"),
                  let full = (image["image"] as? String).flatMap(httpsURL) else { return nil }
            let thumbs = image["thumbnails"] as? [String: Any] ?? [:]
            let thumb = (thumbs["500"] ?? thumbs["large"] ?? thumbs["250"]) as? String
            return CoverCandidate(source: "Cover Art Archive", imageURL: full,
                                  thumbnailURL: thumb.flatMap(httpsURL) ?? full, caption: caption)
        }
    }

    /// Apple Music artwork is available up to 3000 × 3000 px through the public iTunes Search API.
    static func appleMusic(artist: String, album: String, trackCount: Int) async -> [CoverCandidate] {
        guard !album.isEmpty else { return [] }
        var results: [[String: Any]] = []
        let region = Locale.current.region?.identifier.lowercased() ?? "us"
        for country in Array(Set([region, "us"])) {
            var c = URLComponents(string: "https://itunes.apple.com/search")!
            c.queryItems = [URLQueryItem(name: "term", value: "\(artist) \(album)"),
                            URLQueryItem(name: "entity", value: "album"),
                            URLQueryItem(name: "limit", value: "25"),
                            URLQueryItem(name: "country", value: country)]
            guard let url = c.url, let data = try? await fetch(url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            results += json["results"] as? [[String: Any]] ?? []
        }
        let matches = results.filter { r in
            matches(artist: r["artistName"] as? String ?? "", wanted: artist)
                && matches(album: r["collectionName"] as? String ?? "", wanted: album)
        }
        // Same track count first: most likely the same edition.
        let sorted = matches.sorted { a, b in
            (a["trackCount"] as? Int == trackCount ? 0 : 1) < (b["trackCount"] as? Int == trackCount ? 0 : 1)
        }
        return sorted.compactMap { r in
            guard let art = r["artworkUrl100"] as? String,
                  let full = URL(string: appleMusicArtwork(art, size: appleMusicSize)),
                  let thumb = URL(string: appleMusicArtwork(art, size: 600)) else { return nil }
            let name = r["collectionName"] as? String ?? album
            let tracks = r["trackCount"] as? Int
            return CoverCandidate(source: "Apple Music", imageURL: full, thumbnailURL: thumb,
                                  caption: tracks.map { "\(name) · \($0) tracks" } ?? name,
                                  expectedSize: appleMusicSize)
        }
    }

    /// `…/100x100bb.jpg` → `…/3000x3000bb.jpg`
    static func appleMusicArtwork(_ url: String, size: Int) -> String {
        url.replacingOccurrences(of: #"/\d+x\d+bb\.(jpg|png)$"#, with: "/\(size)x\(size)bb.jpg", options: .regularExpression)
    }

    static func normalized(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        // Drop edition notes like "(Remastered 2011)" or "[Deluxe Edition]".
        t = t.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)\b(deluxe|remaster(ed)?|expanded|edition|version|anniversary)\b"#,
                                   with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "&", with: " and ")
        t = t.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func matches(artist: String, wanted: String) -> Bool {
        let a = normalized(artist), w = normalized(wanted)
        guard !a.isEmpty, !w.isEmpty else { return false }
        return a == w || a.contains(w) || w.contains(a) || (w == "various artists" && a.contains("various"))
    }

    static func matches(album: String, wanted: String) -> Bool {
        let a = normalized(album), w = normalized(wanted)
        guard !a.isEmpty, !w.isEmpty else { return false }
        return a == w || a.hasPrefix(w + " ") || w.hasPrefix(a + " ")
    }

    // MARK: Downloading and measuring

    struct ImageInfo: Equatable {
        let width: Int
        let height: Int
        let format: String           // jpeg / png
    }

    static func imageInfo(_ data: Data) -> ImageInfo? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = props[kCGImagePropertyPixelWidth] as? Int,
              var height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
        let format = UTType(type)?.conforms(to: .png) == true ? "png" : "jpeg"
        return ImageInfo(width: width, height: height, format: format)
    }

    static func download(_ candidate: CoverCandidate) async throws -> (Data, ImageInfo) {
        let data = try await fetch(candidate.imageURL, timeout: 60)
        guard let info = imageInfo(data) else { throw RipError.failed("The cover from \(candidate.source) is not a valid image") }
        return (data, info)
    }

    /// Picks the sharpest roughly square front cover. Cover Art Archive wins ties because it shows the exact edition.
    static func best(of downloaded: [(CoverCandidate, Data, ImageInfo)]) -> (CoverCandidate, Data, ImageInfo)? {
        downloaded
            .filter { _, _, info in
                let ratio = Double(info.width) / Double(max(info.height, 1))
                return ratio > 0.8 && ratio < 1.25 && min(info.width, info.height) >= 200
            }
            .max { a, b in
                let sa = min(a.2.width, a.2.height), sb = min(b.2.width, b.2.height)
                if sa != sb { return sa < sb }
                return a.0.source != "Cover Art Archive" && b.0.source == "Cover Art Archive"
            }
    }

    /// Automatic choice during identification: the edition's own cover unless another source is clearly sharper.
    static func findBest(releaseID: String, releaseGroupID: String, artist: String, album: String, trackCount: Int,
                         includeAppleMusic: Bool, log: JobLogger?) async -> (CoverCandidate, Data, ImageInfo)? {
        let all = await candidates(releaseID: releaseID, releaseGroupID: releaseGroupID, artist: artist, album: album,
                                   trackCount: trackCount, includeAppleMusic: includeAppleMusic)
        // Edition cover, album cover, and the best Apple Music match are enough to compare.
        var picks: [CoverCandidate] = []
        if let edition = all.first(where: { $0.caption == "This edition" }) { picks.append(edition) }
        if let group = all.first(where: { $0.caption == "Any edition of the album" }) { picks.append(group) }
        if let apple = all.first(where: { $0.source == "Apple Music" }) { picks.append(apple) }
        var downloaded: [(CoverCandidate, Data, ImageInfo)] = []
        for candidate in picks {
            do {
                let (data, info) = try await download(candidate)
                log?.write("Cover candidate: \(candidate.source) (\(candidate.caption)) \(info.width)×\(info.height)")
                downloaded.append((candidate, data, info))
            } catch {
                log?.write("Cover from \(candidate.source) failed: \(error.localizedDescription)")
            }
        }
        return best(of: downloaded)
    }

    // MARK: Storing and embedding

    static var coversFolder: URL {
        let url = AppPaths.support.appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Keeps the original bytes (no recompression) as the job's cover.
    static func store(_ data: Data, info: ImageInfo, source: String, jobID: UUID) throws -> CoverImage {
        let ext = info.format == "png" ? "png" : "jpg"
        for old in ["jpg", "png"] {
            try? FileManager.default.removeItem(at: coversFolder.appendingPathComponent("\(jobID.uuidString).\(old)"))
        }
        let url = coversFolder.appendingPathComponent("\(jobID.uuidString).\(ext)")
        try data.write(to: url, options: .atomic)
        return CoverImage(path: url.path, width: info.width, height: info.height, bytes: data.count,
                          format: info.format, source: source)
    }

    static func importFile(_ file: URL, jobID: UUID) throws -> CoverImage {
        let data = try Data(contentsOf: file)
        guard let info = imageInfo(data) else { throw RipError.failed("\(file.lastPathComponent) is not an image") }
        if info.format == "png" || data.prefix(2) == Data([0xFF, 0xD8]) {
            return try store(data, info: info, source: "File", jobID: jobID)
        }
        // HEIC, TIFF … are converted, because players only understand JPEG and PNG covers.
        guard let jpeg = jpegData(data, maxPixels: max(info.width, info.height)) else {
            throw RipError.failed("\(file.lastPathComponent) could not be converted")
        }
        return try store(jpeg, info: ImageInfo(width: info.width, height: info.height, format: "jpeg"),
                         source: "File", jobID: jobID)
    }

    /// Image to embed into the audio files: the original when it fits, otherwise a high quality downscale.
    /// `maxPixels` 0 means "do not embed".
    static func embeddedData(_ cover: CoverImage, maxPixels: Int) -> (data: Data, format: String, width: Int, height: Int)? {
        guard maxPixels > 0, let data = try? Data(contentsOf: cover.url) else { return nil }
        let largest = max(cover.width, cover.height)
        // Many players and the ID3 standard choke on very large pictures, so 8 MB is the hard limit.
        if largest <= maxPixels, data.count <= 8_000_000 {
            return (data, cover.format, cover.width, cover.height)
        }
        let target = min(maxPixels, largest)
        guard let jpeg = jpegData(data, maxPixels: target), let info = imageInfo(jpeg) else { return nil }
        return (jpeg, "jpeg", info.width, info.height)
    }

    static func jpegData(_ data: Data, maxPixels: Int, quality: Double = 0.92) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: Networking

    private static func httpsURL(_ s: String) -> URL? {
        URL(string: s.replacingOccurrences(of: "http://", with: "https://"))
    }

    static func fetch(_ url: URL, timeout: TimeInterval = 20) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue(Metadata.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MetadataError.badResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }
}
