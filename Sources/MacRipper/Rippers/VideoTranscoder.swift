import Foundation

/// HandBrakeCLI / FFmpeg transcoding (ARM: HB_PRESET_*, USE_FFMPEG).
struct VideoTranscoder {
    let config: AppConfig
    let discType: DiscType

    enum Source {
        case file(URL)
        case backupTitle(URL, title: Int?)   // nil = main feature
    }

    static func handbrakeProgress(_ line: String) -> Double? {
        // "Encoding: task 1 of 1, 45.67 % (63.12 fps, avg 60.01 fps, ETA 00h12m03s)"
        guard line.hasPrefix("Encoding: task"),
              let range = line.range(of: #"([0-9.]+) %"#, options: .regularExpression) else { return nil }
        let number = line[range].replacingOccurrences(of: " %", with: "")
        guard var p = Double(number).map({ $0 / 100 }) else { return nil }
        // Multi-pass encodes report "task 2 of 2".
        if let t = line.range(of: #"task (\d+) of (\d+)"#, options: .regularExpression) {
            let nums = line[t].split(separator: " ").compactMap { Double($0) }
            if nums.count == 2, nums[1] > 0 { p = ((nums[0] - 1) + p) / nums[1] }
        }
        return p
    }

    static func splitArgs(_ s: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == " " {
                if !current.isEmpty { args.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { args.append(current) }
        return args
    }

    func transcode(_ source: Source, to output: URL, durationSeconds: Int, runner: ProcessRunner,
                   log: JobLogger?, onProgress: @escaping (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch config.transcoder {
        case .handbrake: try await handbrake(source, output, runner, log, onProgress)
        case .ffmpeg: try await ffmpeg(source, output, durationSeconds, runner, log, onProgress)
        }
    }

    private func handbrake(_ source: Source, _ output: URL, _ runner: ProcessRunner, _ log: JobLogger?,
                           _ onProgress: @escaping (Double) -> Void) async throws {
        guard let hb = Tools.handbrakeCLI(config) else { throw RipError.missingTool("HandBrakeCLI (brew install handbrake)") }
        let preset = discType == .bluray ? config.handbrakePresetBD : config.handbrakePresetDVD
        var args: [String]
        switch source {
        case .file(let url): args = ["-i", url.path]
        case .backupTitle(let url, let title):
            args = ["-i", url.path] + (title.map { ["-t", "\($0)"] } ?? ["--main-feature"])
        }
        args += ["-o", output.path, "--preset", preset] + Self.splitArgs(config.handbrakeExtraArgs)
        try await runner.run(hb, args, log: log) { line in
            if let p = Self.handbrakeProgress(line) { onProgress(p) }
        }
    }

    private func ffmpeg(_ source: Source, _ output: URL, _ duration: Int, _ runner: ProcessRunner,
                        _ log: JobLogger?, _ onProgress: @escaping (Double) -> Void) async throws {
        guard let ff = Tools.ffmpeg(config) else { throw RipError.missingTool("ffmpeg (brew install ffmpeg)") }
        guard case .file(let input) = source else {
            throw RipError.failed("FFmpeg cannot process backup folders – use HandBrake or the MKV method")
        }
        let args = ["-y", "-hide_banner", "-nostats", "-i", input.path] + Self.splitArgs(config.ffmpegArgs)
            + ["-progress", "pipe:1", output.path]
        try await runner.run(ff, args, log: log) { line in
            if duration > 0, line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) {
                onProgress(min(1, us / 1_000_000 / Double(duration)))
            }
        }
    }
}

enum RipError: LocalizedError {
    case missingTool(String), failed(String), noMount, noTitles
    var errorDescription: String? {
        switch self {
        case .missingTool(let t): "Required tool missing: \(t)"
        case .failed(let m): m
        case .noMount: "The disc was not mounted (blank or unreadable?)"
        case .noTitles: "No matching titles found on the disc"
        }
    }
}
