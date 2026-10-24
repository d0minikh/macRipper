import Foundation

/// Creates an ISO image of data discs (ARM: data disc → ISO).
struct DataRipper {
    let config: AppConfig

    static func mediaSize(_ devicePath: String) async -> Int64 {
        guard let out = try? await ProcessRunner().run("/usr/sbin/diskutil", ["info", "-plist", devicePath]),
              let plist = try? PropertyListSerialization.propertyList(from: Data(out.utf8), format: nil) as? [String: Any]
        else { return 0 }
        return (plist["TotalSize"] as? Int64) ?? (plist["Size"] as? Int64) ?? 0
    }

    func rip(devicePath: String, mountPoint: String?, to output: URL, runner: ProcessRunner, log: JobLogger?,
             onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if config.dataImageFormat == .rawISO {
            let raw = devicePath.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
            if FileManager.default.isReadableFile(atPath: raw) {
                try await rawCopy(raw, size: await Self.mediaSize(devicePath), to: output, runner: runner, log: log,
                                  onProgress: onProgress)
                return
            }
            log?.write("No read access to \(raw) – creating ISO with hdiutil instead")
        }
        guard let mountPoint else { throw RipError.noMount }
        let base = output.deletingPathExtension()
        try? FileManager.default.removeItem(at: output)
        try await runner.run("/usr/bin/hdiutil", ["makehybrid", "-puppetstrings", "-iso", "-joliet", "-udf",
                                                  "-o", base.path, mountPoint], log: log) { line in
            if line.hasPrefix("PERCENT:"), let p = Double(line.dropFirst(8)), p >= 0 { onProgress(p / 100) }
        }
    }

    /// Sector-by-sector copy of the raw device.
    private func rawCopy(_ raw: String, size: Int64, to output: URL, runner: ProcessRunner, log: JobLogger?,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws {
        log?.write("Copying \(raw) → \(output.path) (\(size.formatted(.byteCount(style: .file))))")
        try await Task.detached(priority: .utility) {
            guard let input = FileHandle(forReadingAtPath: raw) else { throw RipError.failed("Cannot open \(raw)") }
            defer { try? input.close() }
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let out = try FileHandle(forWritingTo: output)
            defer { try? out.close() }
            let chunk = 2048 * 512
            var copied: Int64 = 0
            var lastReport = Date.distantPast
            while true {
                if runner.cancelled || Task.isCancelled { throw CancellationError() }
                let data = try input.read(upToCount: chunk) ?? Data()
                if data.isEmpty { break }
                try out.write(contentsOf: data)
                copied += Int64(data.count)
                if size > 0, Date().timeIntervalSince(lastReport) > 0.5 {
                    lastReport = Date()
                    onProgress(Double(copied) / Double(size))
                }
            }
        }.value
    }
}
