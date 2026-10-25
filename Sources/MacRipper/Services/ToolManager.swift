import Foundation
import CryptoKit

/// Installs and updates the external tools MacRipper depends on: Homebrew formulae
/// (HandBrakeCLI, ffmpeg, apprise) and MakeMKV straight from makemkv.com.
@MainActor
final class ToolManager: ObservableObject {
    enum Source: Equatable {
        case brew(formula: String)
        case makemkv
        case system
    }

    struct Tool: Identifiable {
        let id: String
        let name: String
        let purpose: String
        let source: Source
        var path: String?
        var installedVersion: String?
        var latestVersion: String?
        var updateAvailable = false

        var isInstalled: Bool { path != nil }
    }

    @Published private(set) var tools: [Tool] = []
    @Published private(set) var brewPath: String?
    @Published private(set) var busyTool: String?       // id of the tool being installed/updated
    @Published private(set) var activity = ""           // current step shown in the UI
    @Published private(set) var progress: Double?       // download progress, nil = indeterminate
    @Published private(set) var output = ""             // console output of the last operation
    @Published private(set) var lastError: String?
    @Published private(set) var refreshing = false

    private let configStore: ConfigStore
    private var runner = ProcessRunner()
    nonisolated static let makemkvDownloadPage = URL(string: "https://www.makemkv.com/download/")!
    nonisolated static let homebrewInstallCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    init(configStore: ConfigStore) {
        self.configStore = configStore
        tools = baseTools()
    }

    private func baseTools() -> [Tool] {
        let cfg = configStore.config
        return [
            Tool(id: "makemkv", name: "MakeMKV", purpose: "Rips DVDs and Blu-rays (provides makemkvcon)",
                 source: .makemkv, path: Tools.makemkvcon(cfg)),
            Tool(id: "handbrake", name: "HandBrakeCLI", purpose: "Transcodes video",
                 source: .brew(formula: "handbrake"), path: Tools.handbrakeCLI(cfg)),
            Tool(id: "ffmpeg", name: "FFmpeg", purpose: "Optional: FFmpeg transcoder, MP3 and tags for all audio formats",
                 source: .brew(formula: "ffmpeg"), path: Tools.ffmpeg(cfg)),
            Tool(id: "apprise", name: "Apprise", purpose: "Optional: Apprise notifications",
                 source: .brew(formula: "apprise"), path: Tools.apprise),
            Tool(id: "afconvert", name: "afconvert", purpose: "Encodes audio CDs (part of macOS)",
                 source: .system, path: Tools.resolve("", name: "afconvert")),
        ]
    }

    var updatesAvailable: Int { tools.filter(\.updateAvailable).count }

    // MARK: - Version checks

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        var updated = baseTools()
        brewPath = Tools.resolve("", name: "brew")

        if let brew = brewPath {
            let formulae = updated.compactMap { if case .brew(let f) = $0.source { f } else { nil } }
            if let json = try? await ProcessRunner().run(brew, ["info", "--json=v2"] + formulae),
               let data = json.data(using: .utf8),
               let info = Self.parseBrewInfo(data) {
                for i in updated.indices {
                    guard case .brew(let formula) = updated[i].source, let entry = info[formula] else { continue }
                    updated[i].latestVersion = entry.stable
                    updated[i].installedVersion = entry.installed
                    updated[i].updateAvailable = entry.installed != nil && entry.outdated
                }
            }
        }

        if let i = updated.firstIndex(where: { $0.source == .makemkv }) {
            updated[i].installedVersion = Self.installedMakeMKVVersion(executable: updated[i].path)
            if let latest = try? await Self.latestMakeMKV() {
                updated[i].latestVersion = latest.version
                if let installed = updated[i].installedVersion {
                    updated[i].updateAvailable = Self.compareVersions(installed, latest.version) == .orderedAscending
                }
            }
        }
        tools = updated
    }

    struct BrewFormulaInfo: Equatable {
        let stable: String
        let installed: String?
        let outdated: Bool
    }

    nonisolated static func parseBrewInfo(_ data: Data) -> [String: BrewFormulaInfo]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formulae = root["formulae"] as? [[String: Any]] else { return nil }
        var out: [String: BrewFormulaInfo] = [:]
        for f in formulae {
            guard let name = f["name"] as? String else { continue }
            let stable = (f["versions"] as? [String: Any])?["stable"] as? String ?? ""
            let installed = (f["installed"] as? [[String: Any]])?.last?["version"] as? String
            out[name] = BrewFormulaInfo(stable: stable, installed: installed, outdated: f["outdated"] as? Bool ?? false)
        }
        return out
    }

    nonisolated static func installedMakeMKVVersion(executable: String?) -> String? {
        guard let executable else { return nil }
        // .../MakeMKV.app/Contents/MacOS/makemkvcon → .../MakeMKV.app
        let app = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
        return version.hasPrefix("v") ? String(version.dropFirst()) : version
    }

    nonisolated static func latestMakeMKV() async throws -> (version: String, url: URL) {
        var req = URLRequest(url: makemkvDownloadPage, timeoutInterval: 20)
        req.setValue(Metadata.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let version = parseMakeMKVVersion(String(decoding: data, as: UTF8.self)) else {
            throw RipError.failed("Could not find the MakeMKV download on makemkv.com")
        }
        return (version, URL(string: "https://www.makemkv.com/download/makemkv_v\(version)_osx.dmg")!)
    }

    /// Picks the highest `makemkv_vX.Y.Z_osx.dmg` linked on the download page.
    nonisolated static func parseMakeMKVVersion(_ html: String) -> String? {
        let regex = try! NSRegularExpression(pattern: #"makemkv_v([0-9]+(?:\.[0-9]+)+)_osx\.dmg"#)
        let versions = regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range(at: 1), in: html).map { String(html[$0]) }
        }
        return versions.max { compareVersions($0, $1) == .orderedAscending }
    }

    nonisolated static func publishedMakeMKVHash(version: String) async throws -> String {
        let url = URL(string: "https://www.makemkv.com/download/makemkv-sha-\(version).txt")!
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(Metadata.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let hash = parseHashFile(String(decoding: data, as: UTF8.self), file: "makemkv_v\(version)_osx.dmg") else {
            throw RipError.failed("No published checksum found for MakeMKV \(version) – not installing")
        }
        return hash
    }

    /// Finds `<sha256>  <file>` in MakeMKV's (PGP clear-signed) hash file.
    nonisolated static func parseHashFile(_ text: String, file: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, parts[1] == file, parts[0].count == 64,
               parts[0].allSatisfy(\.isHexDigit) {
                return parts[0].lowercased()
            }
        }
        return nil
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let pb = b.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: - Install / update

    func installOrUpdate(_ id: String) async {
        guard busyTool == nil, let tool = tools.first(where: { $0.id == id }) else { return }
        busyTool = id
        runner = ProcessRunner()
        output = ""
        lastError = nil
        progress = nil
        defer {
            busyTool = nil
            activity = ""
            progress = nil
        }
        do {
            switch tool.source {
            case .brew(let formula):
                try await brew(tool.isInstalled ? "upgrade" : "install", formula: formula, name: tool.name)
            case .makemkv:
                try await installMakeMKV()
            case .system:
                return
            }
            await refresh()
        } catch is CancellationError {
            lastError = "\(tool.name): cancelled"
        } catch {
            lastError = "\(tool.name): \(error.localizedDescription)"
            await refresh()
        }
    }

    func updateAll() async {
        for tool in tools where tool.updateAvailable {
            await installOrUpdate(tool.id)
        }
    }

    func cancel() { runner.cancel() }

    private func append(_ line: String) {
        output += line + "\n"
        if output.count > 60_000 { output = String(output.suffix(50_000)) }
    }

    private func brew(_ command: String, formula: String, name: String) async throws {
        guard let brew = Tools.resolve("", name: "brew") else {
            throw RipError.missingTool("Homebrew (https://brew.sh)")
        }
        activity = command == "install" ? "Installing \(name) with Homebrew…" : "Updating \(name) with Homebrew…"
        try await runner.run(brew, [command, formula],
                             environment: ["HOMEBREW_NO_ENV_HINTS": "1", "NONINTERACTIVE": "1"]) { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }
    }

    private func installMakeMKV() async throws {
        activity = "Looking up the latest MakeMKV…"
        let latest = try await Self.latestMakeMKV()
        append("Latest MakeMKV: \(latest.version) (\(latest.url.absoluteString))")

        activity = "Downloading MakeMKV \(latest.version)…"
        let dmg = try await Downloader.download(latest.url) { [weak self] fraction in
            Task { @MainActor in self?.progress = fraction }
        }
        defer { try? FileManager.default.removeItem(at: dmg) }
        progress = nil
        append("Downloaded to \(dmg.path)")

        // MakeMKV is not code signed, so the published SHA-256 is the only integrity check available.
        activity = "Verifying the download…"
        let expected = try await Self.publishedMakeMKVHash(version: latest.version)
        let actual = try Self.sha256(of: dmg)
        guard actual == expected else {
            throw RipError.failed("Checksum mismatch for the MakeMKV download – not installing (expected \(expected), got \(actual))")
        }
        append("SHA-256 verified: \(actual)")

        activity = "Installing MakeMKV \(latest.version)…"
        let attach = try await runner.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", dmg.path])
        guard let mountPoint = Self.mountPoint(fromAttachPlist: attach) else {
            throw RipError.failed("Could not mount the MakeMKV disk image")
        }
        defer { Task.detached { _ = try? await ProcessRunner().run("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"]) } }

        let source = URL(fileURLWithPath: mountPoint).appendingPathComponent("MakeMKV.app")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw RipError.failed("MakeMKV.app not found in the disk image")
        }
        let destination = Self.makemkvInstallLocation()
        let fm = FileManager.default
        // Copy next to the destination first: a failed or cancelled copy must not leave the user without MakeMKV.
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".MakeMKV-\(UUID().uuidString).app")
        do {
            try await runner.run("/usr/bin/ditto", [source.path, staging.path]) { [weak self] line in
                Task { @MainActor in self?.append(line) }
            }
            var trashed: NSURL?
            if fm.fileExists(atPath: destination.path) {
                append("Moving the old version to the Trash")
                try fm.trashItem(at: destination, resultingItemURL: &trashed)
            }
            do {
                try fm.moveItem(at: staging, to: destination)
            } catch {
                // Put the old version back.
                if let trashed = trashed as URL? { try? fm.moveItem(at: trashed, to: destination) }
                throw error
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        append("Installed MakeMKV \(latest.version) to \(destination.path)")
    }

    /// /Applications when writable (admin users), otherwise ~/Applications.
    nonisolated static func makemkvInstallLocation() -> URL {
        let system = URL(fileURLWithPath: "/Applications/MakeMKV.app")
        if FileManager.default.fileExists(atPath: system.path) || FileManager.default.isWritableFile(atPath: "/Applications") {
            return system
        }
        let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        try? FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        return user.appendingPathComponent("MakeMKV.app")
    }

    nonisolated static func mountPoint(fromAttachPlist output: String) -> String? {
        // hdiutil may print warnings before the plist.
        guard let start = output.range(of: "<?xml") else { return nil }
        let data = Data(output[start.lowerBound...].utf8)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first
    }
}

/// URLSession download with progress reporting.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    static func download(_ url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = Downloader(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                delegate.continuation = cont
                var req = URLRequest(url: url)
                req.setValue(Metadata.userAgent, forHTTPHeaderField: "User-Agent")
                session.downloadTask(with: req).resume()
            }
        } onCancel: { session.invalidateAndCancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this method returns, so move it first.
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).dmg")
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw RipError.failed("Download failed: HTTP \(http.statusCode)")
            }
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
