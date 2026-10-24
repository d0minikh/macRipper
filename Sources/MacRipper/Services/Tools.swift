import Foundation

/// Locates the external command line tools MacRipper drives.
enum Tools {
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func makemkvcon(_ cfg: AppConfig) -> String? {
        resolve(cfg.makemkvconPath, name: "makemkvcon", extra: [
            "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon",
            NSHomeDirectory() + "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon",
        ])
    }

    static func handbrakeCLI(_ cfg: AppConfig) -> String? {
        resolve(cfg.handbrakeCLIPath, name: "HandBrakeCLI", extra: ["/Applications/HandBrakeCLI"])
    }

    static func ffmpeg(_ cfg: AppConfig) -> String? { resolve(cfg.ffmpegPath, name: "ffmpeg") }
    static var ffprobe: String? { resolve("", name: "ffprobe") }
    static var apprise: String? { resolve("", name: "apprise") }

    static func resolve(_ configured: String, name: String, extra: [String] = []) -> String? {
        let fm = FileManager.default
        let configured = (configured as NSString).expandingTildeInPath
        if !configured.isEmpty, fm.isExecutableFile(atPath: configured) { return configured }
        let candidates = extra + searchPath.split(separator: ":").map { "\($0)/\(name)" }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }
}
