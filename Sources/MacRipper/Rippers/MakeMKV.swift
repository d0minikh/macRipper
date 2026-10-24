import Foundation

/// Wrapper around `makemkvcon` in robot mode (`-r`).
struct MakeMKV {
    let executable: String
    let extraArgs: [String]

    struct DiscInfo {
        var name = ""
        var titles: [DiscTitle] = []
    }

    /// Splits a robot-mode line like `TINFO:0,2,0,"Movie, The"` into its fields.
    static func fields(_ line: String) -> (key: String, values: [String])? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon])
        var values: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line[line.index(after: colon)...] {
            switch ch {
            case "\"": inQuotes.toggle()
            case "," where !inQuotes: values.append(current); current = ""
            default: current.append(ch)
            }
        }
        values.append(current)
        return (key, values)
    }

    /// PRGV:current,total,max → fraction of the overall operation.
    static func progress(_ line: String) -> Double? {
        guard line.hasPrefix("PRGV:"), let f = fields(line), f.values.count == 3,
              let total = Double(f.values[1]), let max = Double(f.values[2]), max > 0 else { return nil }
        return total / max
    }

    static func seconds(_ hms: String) -> Int {
        hms.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
    }

    /// MakeMKV source spec addressing the drive by its raw device, which avoids an extra drive scan.
    static func source(bsdName: String) -> String { "dev:/dev/r\(bsdName)" }

    func info(source: String, runner: ProcessRunner, log: JobLogger?, onProgress: @escaping (Double) -> Void) async throws -> DiscInfo {
        let out = try await runner.run(executable, ["-r", "--progress=-same", "info", source, "--minlength=0"] + extraArgs,
                                       log: log) { line in
            if let p = Self.progress(line) { onProgress(p) }
        }
        return Self.parseInfo(out)
    }

    static func parseInfo(_ output: String) -> DiscInfo {
        var info = DiscInfo()
        var titles: [Int: DiscTitle] = [:]
        for line in output.split(separator: "\n").map(String.init) {
            guard let f = fields(line) else { continue }
            switch f.key {
            case "CINFO" where f.values.count >= 3 && f.values[0] == "2":
                info.name = f.values[2]
            case "TINFO" where f.values.count >= 4:
                guard let t = Int(f.values[0]), let code = Int(f.values[1]) else { continue }
                var title = titles[t] ?? DiscTitle(id: t)
                let value = f.values[3]
                switch code {
                case 2: title.name = value
                case 8: title.chapters = Int(value) ?? 0
                case 9: title.durationSeconds = seconds(value)
                case 11: title.sizeBytes = Int64(value) ?? 0
                case 16: title.sourceFile = value
                case 27: title.outputFile = value
                default: break
                }
                titles[t] = title
            default: break
            }
        }
        info.titles = titles.values.sorted { $0.id < $1.id }
        return info
    }

    func ripTitle(source: String, title: Int, to dir: URL, runner: ProcessRunner, log: JobLogger?,
                  onProgress: @escaping (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await runner.run(executable, ["-r", "--progress=-same", "--noscan", "mkv", source, "\(title)", dir.path,
                                          "--minlength=0"] + extraArgs, log: log) { line in
            if let p = Self.progress(line) { onProgress(p) }
        }
    }

    func backup(source: String, to dir: URL, runner: ProcessRunner, log: JobLogger?,
                onProgress: @escaping (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await runner.run(executable, ["-r", "--progress=-same", "--noscan", "backup", "--decrypt", source, dir.path] + extraArgs,
                             log: log) { line in
            if let p = Self.progress(line) { onProgress(p) }
        }
    }
}
