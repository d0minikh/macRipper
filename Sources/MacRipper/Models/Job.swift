import Foundation

enum DiscType: String, Codable, CaseIterable, Identifiable {
    case dvd, bluray, audioCD = "audio_cd", data, unknown
    var id: String { rawValue }

    var label: String {
        switch self {
        case .dvd: "DVD"
        case .bluray: "Blu-ray"
        case .audioCD: "Audio CD"
        case .data: "Data Disc"
        case .unknown: "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .dvd, .bluray: "film"
        case .audioCD: "music.note"
        case .data: "externaldrive"
        case .unknown: "questionmark.circle"
        }
    }

    var isVideo: Bool { self == .dvd || self == .bluray }
}

enum VideoKind: String, Codable, CaseIterable, Identifiable {
    case movie, series, unknown
    var id: String { rawValue }
    var label: String {
        switch self {
        case .movie: "Movie"
        case .series: "Series"
        case .unknown: "Unknown"
        }
    }
}

enum JobStatus: String, Codable {
    case identifying, waiting, ripping, transcoding, finishing, success, failed, abandoned

    var label: String {
        switch self {
        case .identifying: "Identifying"
        case .waiting: "Waiting for input"
        case .ripping: "Ripping"
        case .transcoding: "Transcoding"
        case .finishing: "Finishing"
        case .success: "Finished"
        case .failed: "Failed"
        case .abandoned: "Abandoned"
        }
    }

    var isActive: Bool {
        switch self {
        case .success, .failed, .abandoned: false
        default: true
        }
    }
}

struct DiscTitle: Codable, Identifiable, Hashable {
    var id: Int                 // MakeMKV title index or CD track number
    var name: String = ""
    var durationSeconds: Int = 0
    var chapters: Int = 0
    var sizeBytes: Int64 = 0
    var sourceFile: String = ""  // e.g. 00800.mpls / title_t00.mkv / AIFF path
    var outputFile: String = ""
    var selected: Bool = true
    var isMainFeature = false
    var ripped = false
    var transcoded = false
    var audio: AudioTrackTags?       // audio CDs only; optional so older job histories still decode

    var durationText: String { Self.format(seconds: durationSeconds) }

    static func format(seconds: Int) -> String {
        String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}

struct Job: Codable, Identifiable, Hashable {
    var id = UUID()
    var created = Date()
    var finished: Date?

    // Drive / disc
    var devicePath: String           // /dev/disk4
    var mountPoint: String?
    var driveName: String = ""
    var discLabel: String = ""
    var discType: DiscType = .unknown

    // Identification
    var title: String = ""
    var year: String = ""
    var videoKind: VideoKind = .unknown
    var imdbID: String = ""
    var posterURL: String = ""
    var artist: String = ""          // audio
    var album: String = ""           // audio
    var musicBrainzDiscID: String = ""
    var musicBrainzReleaseID: String = ""
    var audioInfo: AudioAlbumInfo?   // audio CDs only; optional so older job histories still decode
    var identifiedByUser = false

    // Progress
    var status: JobStatus = .identifying
    var stage: String = ""
    var progress: Double = 0         // 0...1 of current stage
    var stageStarted: Date?
    var remainingSeconds: Int?       // estimated time left for the current stage
    var errorMessage: String?
    var titles: [DiscTitle] = []
    var outputPath: String = ""

    var displayTitle: String {
        if discType == .audioCD, !album.isEmpty {
            return artist.isEmpty ? album : "\(artist) – \(album)"
        }
        if !title.isEmpty { return year.isEmpty ? title : "\(title) (\(year))" }
        return discLabel.isEmpty ? "Untitled Disc" : discLabel
    }

    /// Time from inserting the disc until the job finished (or until now while it runs).
    var elapsedSeconds: Int { Int((finished ?? Date()).timeIntervalSince(created)) }

    var remainingText: String? {
        guard status.isActive, let remainingSeconds else { return nil }
        return "About \(Self.formatDuration(remainingSeconds)) remaining"
    }

    /// Short, locale aware duration like "1 hr, 5 min" or "40 sec".
    static func formatDuration(_ seconds: Int) -> String {
        let rounded = seconds >= 120 ? (seconds + 30) / 60 * 60 : seconds
        return Duration.seconds(rounded).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated,
                                                          maximumUnitCount: 2))
    }

    /// Estimate from the average speed since the stage started; nil until there is enough data.
    static func estimateRemaining(progress: Double, stageStarted: Date?, now: Date = Date()) -> Int? {
        guard let stageStarted, progress >= 0.02, progress < 1 else { return nil }
        let elapsed = now.timeIntervalSince(stageStarted)
        guard elapsed >= 10 else { return nil }
        return Int((elapsed / progress * (1 - progress)).rounded())
    }

    var logURL: URL { AppPaths.logs.appendingPathComponent("job-\(id.uuidString).log") }
}

// Decoding is lenient so fields added or changed later never make a saved job history unreadable.

extension Job {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, default: UUID())
        created = c.lenient(.created, default: Date())
        finished = c.lenientOptional(.finished)
        devicePath = c.lenient(.devicePath, default: "")
        mountPoint = c.lenientOptional(.mountPoint)
        driveName = c.lenient(.driveName, default: "")
        discLabel = c.lenient(.discLabel, default: "")
        discType = c.lenient(.discType, default: .unknown)
        title = c.lenient(.title, default: "")
        year = c.lenient(.year, default: "")
        videoKind = c.lenient(.videoKind, default: .unknown)
        imdbID = c.lenient(.imdbID, default: "")
        posterURL = c.lenient(.posterURL, default: "")
        artist = c.lenient(.artist, default: "")
        album = c.lenient(.album, default: "")
        musicBrainzDiscID = c.lenient(.musicBrainzDiscID, default: "")
        musicBrainzReleaseID = c.lenient(.musicBrainzReleaseID, default: "")
        audioInfo = c.lenientOptional(.audioInfo)
        identifiedByUser = c.lenient(.identifiedByUser, default: false)
        // An unknown status (e.g. written by a newer version) cannot be resumed anyway.
        status = c.lenient(.status, default: .failed)
        stage = c.lenient(.stage, default: "")
        progress = c.lenient(.progress, default: 0)
        stageStarted = c.lenientOptional(.stageStarted)
        remainingSeconds = c.lenientOptional(.remainingSeconds)
        errorMessage = c.lenientOptional(.errorMessage)
        titles = c.lenient(.titles, default: [])
        outputPath = c.lenient(.outputPath, default: "")
    }
}

extension DiscTitle {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = c.lenient(.name, default: "")
        durationSeconds = c.lenient(.durationSeconds, default: 0)
        chapters = c.lenient(.chapters, default: 0)
        sizeBytes = c.lenient(.sizeBytes, default: 0)
        sourceFile = c.lenient(.sourceFile, default: "")
        outputFile = c.lenient(.outputFile, default: "")
        selected = c.lenient(.selected, default: true)
        isMainFeature = c.lenient(.isMainFeature, default: false)
        ripped = c.lenient(.ripped, default: false)
        transcoded = c.lenient(.transcoded, default: false)
        audio = c.lenientOptional(.audio)
    }
}

extension KeyedDecodingContainer {
    /// The stored value, or `defaultValue` when it is missing or cannot be read.
    func lenient<T: Decodable>(_ key: Key, default defaultValue: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? defaultValue
    }

    func lenientOptional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}
