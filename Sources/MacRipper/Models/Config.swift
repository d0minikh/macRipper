import Foundation

enum AppPaths {
    /// Test runs and launches with the MACRIPPER_* debug hooks (sample jobs, clearing the history …) keep their own
    /// data, so they never touch the real job history or settings. Normal launches, Xcode's Debug runs included,
    /// share the real data.
    static let isolated: Bool = {
        let info = ProcessInfo.processInfo
        if info.processName != "MacRipper" { return true }    // xctest, swiftpm-testing-helper
        return info.environment.keys.contains { $0.hasPrefix("XCTest") || $0.hasPrefix("MACRIPPER_") }
    }()

    static let folderName = isolated ? "MacRipper-Debug" : "MacRipper"

    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return url
    }()

    static let logs: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(folderName)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var configFile: URL { support.appendingPathComponent("config.json") }

    /// Writes app data readable by the current user only.
    static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static var jobsFile: URL { support.appendingPathComponent("jobs.json") }
}

enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case dark, system, light
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum VideoRipMethod: String, Codable, CaseIterable, Identifiable {
    case mkv, backup
    var id: String { rawValue }
    var label: String { self == .mkv ? "MKV (individual titles)" : "Backup (decrypted folder)" }
}

enum Transcoder: String, Codable, CaseIterable, Identifiable {
    case handbrake, ffmpeg
    var id: String { rawValue }
    var label: String { self == .handbrake ? "HandBrakeCLI" : "FFmpeg" }
}

enum MetadataProvider: String, Codable, CaseIterable, Identifiable {
    case omdb, tmdb, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .omdb: "OMDb"
        case .tmdb: "TMDb"
        case .none: "None"
        }
    }
}

enum AudioFormat: String, Codable, CaseIterable, Identifiable {
    case flac, alac, aac, mp3, wav
    var id: String { rawValue }
    var label: String {
        switch self {
        case .flac: "FLAC"
        case .alac: "Apple Lossless (ALAC)"
        case .aac: "AAC"
        case .mp3: "MP3 (requires ffmpeg)"
        case .wav: "WAV"
        }
    }
    var fileExtension: String {
        switch self {
        case .flac: "flac"
        case .alac, .aac: "m4a"
        case .mp3: "mp3"
        case .wav: "wav"
        }
    }
}

enum DataImageFormat: String, Codable, CaseIterable, Identifiable {
    case rawISO = "raw", hybridISO = "hybrid"
    var id: String { rawValue }
    var label: String { self == .rawISO ? "1:1 image (dd)" : "Remastered ISO (hdiutil)" }
}

/// Mirrors the options of ARM's arm.yaml, adapted to macOS.
struct AppConfig: Codable, Equatable {
    // General
    var showDockIcon = true                    // at least one of Dock / menu bar icon stays visible
    var showMenuBarIcon = true
    var appearance: AppAppearance = .dark
    var autoRip = true                         // start automatically when a disc is inserted
    var manualWaitEnabled = true               // MANUAL_WAIT
    var manualWaitSeconds = 60                 // MANUAL_WAIT_TIME
    var autoEject = true                       // AUTO_EJECT
    var ejectOnFailure = true
    var maxConcurrentTranscodes = 1            // MAX_CONCURRENT_TRANSCODES
    var rawPath = "~/Movies/MacRipper/raw"     // RAW_PATH
    var transcodePath = "~/Movies/MacRipper/transcode" // TRANSCODE_PATH
    var completedPath = "~/Movies/MacRipper/completed" // COMPLETED_PATH
    var musicPath = "~/Music/MacRipper"
    var dataPath = "~/Documents/MacRipper/ISO"
    var postJobScript = ""                     // BASH_SCRIPT
    var webServerEnabled = false               // ARM web UI
    var webServerPort = 8080
    var webServerToken = ""
    var webServerAllowRemote = false           // listen on all interfaces instead of localhost

    // Video
    var ripMethod: VideoRipMethod = .mkv       // RIPMETHOD
    var mainFeatureOnly = false                // MAINFEATURE
    var minLengthSeconds = 600                 // MINLENGTH
    var maxLengthSeconds = 99_999              // MAXLENGTH
    var preventFakeTitles = true               // PREVENT_99
    var skipTranscode = false                  // SKIP_TRANSCODE
    var transcoder: Transcoder = .handbrake    // USE_FFMPEG
    var handbrakePresetDVD = "HQ 720p30 Surround"   // HB_PRESET_DVD
    var handbrakePresetBD = "HQ 1080p30 Surround"   // HB_PRESET_BD
    var handbrakeExtraArgs = ""                // HB_ARGS_DVD / HB_ARGS_BD
    var ffmpegArgs = "-map 0 -c:v libx265 -crf 22 -preset medium -c:a copy -c:s copy"
    var destinationExtension = "mkv"           // DEST_EXT
    var deleteRawFiles = true                  // DELRAWFILES
    var extrasSubfolder = "Extras"             // EXTRAS_SUB
    var makemkvArgs = ""                       // MKV_ARGS
    var ripPosters = true

    // Metadata
    var metadataProvider: MetadataProvider = .omdb   // METADATA_PROVIDER
    var omdbAPIKey = ""                        // OMDB_API_KEY
    var tmdbAPIKey = ""                        // TMDB_API_KEY
    var getVideoTitle = true                   // GET_VIDEO_TITLE

    // Audio
    var audioFormat: AudioFormat = .flac
    var aacBitrate = 256_000
    var musicBrainzLookup = true
    var audioFolderPattern = "{artist}/{album} ({year})"
    var audioFilePattern = "{track} - {title}"
    var audioEmbedCoverMaxPixels = 3000       // 0 = do not embed; larger covers are downscaled for embedding
    var audioCoverFileName = "cover"          // saved as cover.jpg / cover.png next to the music
    var audioCoverFromAppleMusic = true       // also search Apple Music (up to 3000 × 3000 px)
    var audioWaitWhenUnknown = true           // do not rip unknown CDs before the user identified them

    // Data
    var dataImageFormat: DataImageFormat = .rawISO

    // Notifications
    var notifyOnRipStart = true                // NOTIFY_RIP
    var notifyOnFinish = true                  // NOTIFY_TRANSCODE
    var notifyOnFailure = true
    var notifyLocal = true
    var templateRipStartedTitle = "MacRipper: Rip started"
    var templateRipStartedBody = "{type}: {title}"
    var templateFinishedTitle = "MacRipper: {title} is ready"
    var templateFinishedBody = "{type} finished in {duration}."
    var templateFailedTitle = "MacRipper: Rip failed"
    var templateFailedBody = "{title}: {error}"
    var pushoverEnabled = true
    var pushoverPriority = 0                   // -2 (lowest) … 1 (high)
    var pushoverSound = ""                     // empty = the user's default sound
    var pushoverDevice = ""                    // empty = all devices
    var pushbulletEnabled = true
    var iftttEnabled = true
    var ntfyEnabled = true
    var webhookEnabled = true
    var appriseEnabled = true
    var pushoverUserKey = ""                   // PO_USER_KEY
    var pushoverAppToken = ""                  // PO_APP_KEY
    var pushbulletKey = ""                     // PB_KEY
    var iftttKey = ""                          // IFTTT_KEY
    var iftttEvent = "macripper_event"         // IFTTT_EVENT
    var ntfyURL = ""                           // e.g. https://ntfy.sh/my-topic
    var webhookURL = ""                        // JSON_URL
    var appriseURLs = ""                       // APPRISE (one URL per line, needs `apprise` CLI)

    // Tool paths (empty = auto-detect)
    var makemkvconPath = ""
    var handbrakeCLIPath = ""
    var ffmpegPath = ""

    /// Link to the web interface including the access token.
    var webInterfaceURL: URL? {
        guard !webServerToken.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = "http"
        c.host = webServerAllowRemote ? ProcessInfo.processInfo.hostName : "localhost"
        c.port = webServerPort
        c.path = "/"
        c.queryItems = [URLQueryItem(name: "token", value: webServerToken)]
        return c.url
    }

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Decodes a stored config on top of the defaults, so options added in newer
    /// versions never invalidate an older config file.
    static func decodeMerged(from data: Data) throws -> AppConfig {
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppConfig())) as? [String: Any] ?? [:]
        let stored = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let merged = defaults.merging(stored) { _, new in new }
        return try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: merged))
    }
}
