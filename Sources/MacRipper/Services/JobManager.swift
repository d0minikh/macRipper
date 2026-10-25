import Foundation
import Combine

/// Orchestrates rip jobs from disc insertion to the finished files (ARM: ripper/main.py).
@MainActor
final class JobManager: ObservableObject {
    @Published private(set) var jobs: [Job] = []

    let configStore: ConfigStore
    let monitor: DiscMonitor
    private var config: AppConfig { configStore.config }
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var runners: [UUID: ProcessRunner] = [:]
    private var startRequested: Set<UUID> = []
    private var pendingAudioReleases: [UUID: [AudioRelease]] = [:]
    private var needsUserInput: Set<UUID> = []
    @Published private(set) var retagging: Set<UUID> = []
    @Published private(set) var retagErrors: [UUID: String] = [:]
    private let limiter = TranscodeLimiter()
    private var saveCancellable: AnyCancellable?

    init(configStore: ConfigStore, monitor: DiscMonitor) {
        self.configStore = configStore
        self.monitor = monitor
        loadJobs()
        saveCancellable = $jobs
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { Self.save($0) }
        monitor.onInserted = { [weak self] disc, atLaunch in
            guard let self else { return }
            if atLaunch || !self.config.autoRip { return }
            self.startJob(for: disc)
        }
        monitor.onRemoved = { [weak self] disc in
            // A disc pulled during identification or waiting cannot continue.
            guard let self else { return }
            for job in self.jobs where job.devicePath == disc.devicePath
                && [.identifying, .waiting, .ripping].contains(job.status) {
                self.fail(job.id, "Disc was removed")
            }
        }
    }

    private static func save(_ jobs: [Job]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(jobs) { try? AppPaths.writePrivate(data, to: AppPaths.jobsFile) }
    }

    /// Writes the job list right away; the regular save is debounced and would miss changes made just before quitting.
    func saveNow() { Self.save(jobs) }

    private func loadJobs() {
        guard let data = try? Data(contentsOf: AppPaths.jobsFile) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        jobs = (try? dec.decode([Job].self, from: data)) ?? []
        // Jobs that were running when the app quit cannot be resumed.
        for i in jobs.indices where jobs[i].status.isActive {
            jobs[i].status = .failed
            jobs[i].errorMessage = "Interrupted (app was quit)"
        }
    }

    // MARK: - Public API used by the UI and web server

    var activeJobs: [Job] { jobs.filter { $0.status.isActive }.sorted { $0.created > $1.created } }
    var finishedJobs: [Job] { jobs.filter { !$0.status.isActive }.sorted { $0.created > $1.created } }

    func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    func isBusy(_ devicePath: String) -> Bool {
        jobs.contains { $0.devicePath == devicePath && [.identifying, .waiting, .ripping].contains($0.status) }
    }

    func startJob(for disc: DetectedDisc) {
        guard !isBusy(disc.devicePath) else { return }
        let job = Job(devicePath: disc.devicePath, driveName: disc.deviceModel)
        jobs.append(job)
        let runner = ProcessRunner()
        runners[job.id] = runner
        tasks[job.id] = Task { [weak self] in
            await self?.run(job.id, disc: disc, runner: runner)
        }
    }

    func startNow(_ id: UUID) {
        guard job(id)?.status == .waiting else { return }
        startRequested.insert(id)
    }

    func abandon(_ id: UUID) {
        guard job(id)?.status.isActive == true else { return }
        runners[id]?.cancel()
        tasks[id]?.cancel()
        update(id) {
            $0.status = .abandoned
            $0.stage = "Abandoned by user"
            $0.finished = Date()
        }
    }

    func delete(_ id: UUID) {
        guard let job = job(id), !job.status.isActive else { return }
        removeFiles(of: job)
        jobs.removeAll { $0.id == id }
    }

    /// Stops all external tools, e.g. when the app quits.
    func cancelAll() { runners.values.forEach { $0.cancel() } }

    func clearHistory() {
        jobs.filter { !$0.status.isActive }.forEach(removeFiles)
        jobs.removeAll { !$0.status.isActive }
    }

    /// The app's own copies of a job (cover and log); ripped files in the library stay untouched.
    private func removeFiles(of job: Job) {
        if let cover = job.audioInfo?.cover?.path, cover.hasPrefix(CoverArt.coversFolder.path + "/") {
            try? FileManager.default.removeItem(atPath: cover)
        }
        try? FileManager.default.removeItem(at: job.logURL)
        retagErrors[job.id] = nil
    }

    #if DEBUG
    func insertForDebug(_ demo: [Job]) { jobs.append(contentsOf: demo) }
    #endif

    func setIdentification(_ id: UUID, _ change: (inout Job) -> Void) {
        update(id) {
            change(&$0)
            $0.identifiedByUser = true
            if $0.status == .success, $0.discType == .audioCD {
                // Edited after the rip: the files still carry the old tags until they are rewritten.
                var info = $0.audioInfo ?? AudioAlbumInfo()
                info.tagsChangedAfterRip = true
                $0.audioInfo = info
            }
        }
    }

    func toggleTitle(_ id: UUID, title: Int, selected: Bool) {
        update(id) { job in
            if let i = job.titles.firstIndex(where: { $0.id == title }) { job.titles[i].selected = selected }
        }
    }

    /// Takes over all album and track tags of a MusicBrainz release. The cover is kept.
    func applyRelease(_ id: UUID, _ release: AudioRelease, byUser: Bool = true) {
        update(id) { job in
            job.album = release.title
            job.artist = release.artist
            job.year = release.year
            job.musicBrainzReleaseID = release.id
            var info = job.audioInfo ?? AudioAlbumInfo()
            info.date = release.date
            info.originalDate = release.originalDate
            info.genre = release.genre
            info.label = release.label
            info.catalogNumber = release.catalogNumber
            info.barcode = release.barcode
            info.country = release.country
            info.media = release.format
            info.discNumber = release.discNumber
            info.discTotal = release.discTotal
            info.compilation = release.isCompilation
            info.releaseGroupID = release.releaseGroupID
            info.albumArtistID = release.artistID
            info.albumArtistSort = release.artistSort
            if job.status == .success { info.tagsChangedAfterRip = true }
            job.audioInfo = info
            for i in job.titles.indices {
                guard let t = release.tracks.first(where: { $0.number == job.titles[i].id }) else { continue }
                job.titles[i].name = t.title
                var tags = job.titles[i].audio ?? AudioTrackTags()
                // Store the track artist only where it differs from the album artist (features, compilations).
                tags.artist = t.artist == release.artist ? "" : t.artist
                tags.artistID = t.artistID
                tags.recordingID = t.recordingID
                tags.releaseTrackID = t.releaseTrackID
                tags.isrc = t.isrc
                job.titles[i].audio = tags
            }
            job.identifiedByUser = byUser
        }
        if !(pendingAudioReleases[id] ?? []).contains(where: { $0.id == release.id }) {
            pendingAudioReleases[id, default: []].insert(release, at: 0)
        }
    }

    /// Loads the full release if it came from a search, applies it, then looks for the best cover.
    func chooseRelease(_ id: UUID, _ release: AudioRelease) async throws {
        var full = release
        if !full.isComplete {
            full = try await Metadata.release(id: release.id, trackCount: job(id)?.titles.count ?? release.trackCount)
        }
        applyRelease(id, full)
        if job(id)?.audioInfo?.cover?.source != "File" { await findBestCover(id, log: nil) }
    }

    func audioCandidates(_ id: UUID) -> [AudioRelease] { pendingAudioReleases[id] ?? [] }

    // MARK: Covers

    func coverCandidates(_ id: UUID) async -> [CoverCandidate] {
        guard let job = job(id) else { return [] }
        return await CoverArt.candidates(releaseID: job.musicBrainzReleaseID,
                                         releaseGroupID: job.audioInfo?.releaseGroupID ?? "",
                                         artist: job.artist, album: job.album, trackCount: job.titles.count,
                                         includeAppleMusic: config.audioCoverFromAppleMusic)
    }

    func findBestCover(_ id: UUID, log: JobLogger?) async {
        guard let job = job(id) else { return }
        guard let (candidate, data, info) = await CoverArt.findBest(
            releaseID: job.musicBrainzReleaseID, releaseGroupID: job.audioInfo?.releaseGroupID ?? "",
            artist: job.artist, album: job.album, trackCount: job.titles.count,
            includeAppleMusic: config.audioCoverFromAppleMusic, log: log)
        else {
            log?.write("No cover found")
            return
        }
        try? storeCover(id, data: data, info: info, source: candidate.source)
        log?.write("Cover: \(candidate.source), \(info.width)×\(info.height) \(info.format)")
    }

    func useCover(_ id: UUID, _ candidate: CoverCandidate) async throws {
        let (data, info) = try await CoverArt.download(candidate)
        try storeCover(id, data: data, info: info, source: candidate.source)
    }

    func useCoverFile(_ id: UUID, _ file: URL) throws {
        let cover = try CoverArt.importFile(file, jobID: id)
        setCover(id, cover)
    }

    func removeCover(_ id: UUID) {
        if let path = job(id)?.audioInfo?.cover?.path { try? FileManager.default.removeItem(atPath: path) }
        setCover(id, nil)
    }

    private func storeCover(_ id: UUID, data: Data, info: CoverArt.ImageInfo, source: String) throws {
        setCover(id, try CoverArt.store(data, info: info, source: source, jobID: id))
    }

    private func setCover(_ id: UUID, _ cover: CoverImage?) {
        update(id) { job in
            var info = job.audioInfo ?? AudioAlbumInfo()
            info.cover = cover
            if job.status == .success { info.tagsChangedAfterRip = true }
            job.audioInfo = info
        }
    }

    // MARK: - Pipeline

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    private func setStage(_ id: UUID, _ status: JobStatus, _ stage: String, progress: Double = 0) {
        update(id) {
            if $0.status != status || $0.stage != stage {
                $0.stageStarted = Date()
                $0.remainingSeconds = nil
            }
            $0.status = status
            $0.stage = stage
            $0.progress = progress
        }
    }

    private func progressHandler(_ id: UUID, scale: (Double, Double) = (0, 1)) -> @Sendable (Double) -> Void {
        { [weak self] p in
            Task { @MainActor in
                self?.update(id) {
                    $0.progress = scale.0 + min(max(p, 0), 1) * (scale.1 - scale.0)
                    if $0.status == .ripping || $0.status == .transcoding {
                        $0.remainingSeconds = Job.estimateRemaining(progress: $0.progress, stageStarted: $0.stageStarted)
                    }
                }
            }
        }
    }

    /// Ejects the disc once ripping is done. The stage moves on first, so the disc disappearing is not
    /// mistaken for a disc pulled mid-rip.
    private func ejectAfterRip(_ id: UUID, _ devicePath: String) async {
        setStage(id, .finishing, "Ripping finished")
        guard config.autoEject else { return }
        setStage(id, .finishing, "Ejecting disc")
        await DiscMonitor.eject(devicePath)
    }

    private func isCancelled(_ id: UUID) -> Bool { job(id)?.status == .abandoned || Task.isCancelled }

    private func fail(_ id: UUID, _ message: String) {
        runners[id]?.cancel()
        tasks[id]?.cancel()
        update(id) {
            guard $0.status.isActive else { return }
            $0.status = .failed
            $0.errorMessage = message
            $0.finished = Date()
        }
    }

    private func run(_ id: UUID, disc: DetectedDisc, runner: ProcessRunner) async {
        guard let initial = job(id) else { return }
        let log = JobLogger(url: initial.logURL)
        log.write("New job for \(disc.devicePath) (\(disc.deviceModel), \(disc.mediaLabel))")
        defer {
            runners[id] = nil
            tasks[id] = nil
            startRequested.remove(id)
            pendingAudioReleases[id] = nil
            needsUserInput.remove(id)
        }

        do {
            try await identify(id, disc: disc, runner: runner, log: log)
            try await waitForUser(id, log: log)
            guard !isCancelled(id) else { throw CancellationError() }
            setStage(id, .ripping, "Starting")
            guard let current = job(id) else { throw CancellationError() }
            await Notifier.send(.ripStarted, job: current, config: config, log: log)

            switch current.discType {
            case .dvd, .bluray: try await ripVideo(id, disc: disc, runner: runner, log: log)
            case .audioCD: try await ripAudio(id, runner: runner, log: log)
            case .data, .unknown: try await ripData(id, runner: runner, log: log)
            }

            update(id) {
                $0.status = .success
                $0.stage = "Finished"
                $0.progress = 1
                $0.remainingSeconds = nil
                $0.finished = Date()
            }
            log.write("Job completed successfully: \(job(id)?.outputPath ?? "")")
            if let job = self.job(id) {
                await Notifier.send(.finished, job: job, config: config, log: log)
                await runPostScript(job, log: log)
            }
        } catch is CancellationError {
            log.write("Job abandoned")
            if job(id)?.status != .failed {
                update(id) {
                    if $0.status.isActive { $0.status = .abandoned; $0.finished = Date() }
                }
            }
        } catch {
            // An interrupted tool exits with an error after the user abandoned the job.
            if job(id)?.status == .abandoned {
                log.write("Job abandoned")
                return
            }
            log.write("ERROR: \(error.localizedDescription)")
            update(id) {
                $0.status = .failed
                $0.errorMessage = error.localizedDescription
                $0.finished = Date()
            }
            if let job = job(id) {
                await Notifier.send(.failed, job: job, config: config, log: log)
            }
            if config.ejectOnFailure, monitor.discs.contains(disc) { await DiscMonitor.eject(disc.devicePath) }
        }
    }

    // MARK: Identification

    private func identify(_ id: UUID, disc: DetectedDisc, runner: ProcessRunner, log: JobLogger) async throws {
        setStage(id, .identifying, "Waiting for the disc to mount")
        let mount = await DiscMonitor.waitForMount(disc.bsdName)
        let type = DiscIdentifier.discType(mountPoint: mount, mediaKind: disc.mediaKind)
        var label = mount.map(DiscIdentifier.volumeLabel) ?? ""
        if type == .bluray, let mount, let bdTitle = DiscIdentifier.blurayTitle(mountPoint: mount) { label = bdTitle }
        log.write("Type: \(type.label), label: \(label), mount: \(mount ?? "–")")
        update(id) {
            $0.mountPoint = mount
            $0.discType = type
            $0.discLabel = label
        }
        if type == .unknown { throw RipError.noMount }

        switch type {
        case .dvd, .bluray: try await identifyVideo(id, disc: disc, label: label, runner: runner, log: log)
        case .audioCD: try await identifyAudio(id, mount: mount, log: log)
        default:
            update(id) {
                $0.title = label
                $0.titles = [DiscTitle(id: 1, name: "\(label).iso")]
            }
        }
    }

    private func identifyVideo(_ id: UUID, disc: DetectedDisc, label: String, runner: ProcessRunner, log: JobLogger) async throws {
        let cleaned = DiscIdentifier.cleanLabel(label)
        update(id) {
            $0.title = cleaned
            $0.videoKind = DiscIdentifier.looksLikeSeries(label) ? .series : .movie
        }
        if config.getVideoTitle, config.metadataProvider != .none {
            setStage(id, .identifying, "Searching metadata (\(config.metadataProvider.label))")
            if let hit = await Metadata.identifyVideo(label: label, config: config) {
                log.write("Identified as \(hit.title) (\(hit.year)) [\(hit.kind.label)]")
                update(id) {
                    $0.title = hit.title
                    $0.year = hit.year
                    $0.videoKind = hit.kind == .unknown ? $0.videoKind : hit.kind
                    $0.imdbID = hit.imdbID
                    $0.posterURL = hit.posterURL
                }
            } else {
                log.write("No metadata found for \"\(cleaned)\"")
            }
        }

        guard let mkv = Tools.makemkvcon(config) else { throw RipError.missingTool("makemkvcon (MakeMKV)") }
        setStage(id, .identifying, "Reading titles with MakeMKV")
        let makemkv = MakeMKV(executable: mkv, extraArgs: VideoTranscoder.splitArgs(config.makemkvArgs))
        let info = try await makemkv.info(source: MakeMKV.source(bsdName: disc.bsdName), runner: runner, log: log, onProgress: progressHandler(id))
        var titles = info.titles
        guard !titles.isEmpty else { throw RipError.noTitles }
        if let main = titles.indices.max(by: { titles[$0].durationSeconds < titles[$1].durationSeconds }) {
            titles[main].isMainFeature = true
        }
        let kind = job(id)?.videoKind ?? .movie
        let fake = config.preventFakeTitles && titles.count >= 99
        if fake { log.write("\(titles.count) titles found – fake title protection active, ripping main feature only") }
        for i in titles.indices {
            let inRange = titles[i].durationSeconds >= config.minLengthSeconds
                && titles[i].durationSeconds <= config.maxLengthSeconds
            if fake || (config.mainFeatureOnly && kind != .series) {
                titles[i].selected = titles[i].isMainFeature
            } else {
                titles[i].selected = inRange || titles[i].isMainFeature && kind != .series
            }
        }
        log.write("\(titles.count) titles, \(titles.filter(\.selected).count) selected")
        update(id) { $0.titles = titles }
    }

    private func identifyAudio(_ id: UUID, mount: String?, log: JobLogger) async throws {
        guard let mount else { throw RipError.noMount }
        let files = AudioRipper.trackFiles(mountPoint: mount)
        let toc = CDTOC(mountPoint: mount)
        let durations = toc?.durations ?? []
        var titles = files.keys.sorted().map { n in
            DiscTitle(id: n, name: "Track \(n)", sourceFile: files[n]!.path)
        }
        if let toc {
            for i in titles.indices {
                if let idx = toc.tracks.firstIndex(where: { $0.number == titles[i].id }), idx < durations.count {
                    titles[i].durationSeconds = durations[idx]
                }
            }
        }
        guard !titles.isEmpty else { throw RipError.noTitles }
        update(id) {
            $0.titles = titles
            $0.album = "Unknown Album"
            $0.artist = "Unknown Artist"
            $0.musicBrainzDiscID = toc?.musicBrainzDiscID ?? ""
            $0.audioInfo = AudioAlbumInfo()
        }

        guard config.musicBrainzLookup, let toc else {
            needsUserInput.insert(id)
            return
        }
        setStage(id, .identifying, "Querying MusicBrainz")
        log.write("MusicBrainz disc ID: \(toc.musicBrainzDiscID)")
        do {
            let releases = try await Metadata.lookupDisc(toc)
            if let first = releases.first {
                log.write("Found: \(first.artist) – \(first.title) (\(releases.count) matching editions)")
                pendingAudioReleases[id] = releases
                applyRelease(id, first, byUser: false)
                setStage(id, .identifying, "Looking for the best cover")
                await findBestCover(id, log: log)
            } else {
                log.write("No MusicBrainz entry found")
                needsUserInput.insert(id)
            }
        } catch {
            log.write("MusicBrainz lookup failed: \(error.localizedDescription)")
            needsUserInput.insert(id)
        }
    }

    /// ARM's MANUAL_WAIT: give the user time to correct the title / title selection.
    private func waitForUser(_ id: UUID, log: JobLogger) async throws {
        // An unknown CD would otherwise be ripped as "Unknown Artist – Track 1 …".
        let indefinitely = needsUserInput.contains(id) && config.audioWaitWhenUnknown
        guard config.manualWaitEnabled || indefinitely else { return }
        let total = max(1, config.manualWaitSeconds)
        let deadline = Date().addingTimeInterval(TimeInterval(total))
        log.write(indefinitely ? "CD not identified – waiting for the user" : "Waiting \(total)s for user input")
        while !startRequested.contains(id) {
            if isCancelled(id) { throw CancellationError() }
            let remaining = deadline.timeIntervalSinceNow
            if !indefinitely, remaining <= 0 { break }
            update(id) {
                $0.status = .waiting
                $0.stage = indefinitely
                    ? "CD not found online – enter or search the album, then click Start Now"
                    : "Starting automatically in \(Int(remaining.rounded()))s – review titles now"
                $0.progress = indefinitely ? 0 : 1 - remaining / Double(total)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    // MARK: Video

    private func baseName(_ job: Job) -> String {
        let t = AudioRipper.sanitize(job.title.isEmpty ? job.discLabel : job.title)
        return job.year.isEmpty ? t : "\(t) (\(job.year))"
    }

    private func finalVideoDir(_ job: Job) -> URL {
        let root = AppConfig.expand(config.completedPath)
        let identified = !job.year.isEmpty || job.identifiedByUser
        let category = !identified ? "unidentified" : job.videoKind == .series ? "tv" : "movies"
        return root.appendingPathComponent(category).appendingPathComponent(baseName(job))
    }

    private func uniqueDirectory(_ url: URL) -> URL {
        var candidate = url
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            n += 1
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent) \(n)")
        }
        return candidate
    }

    private func ripVideo(_ id: UUID, disc: DetectedDisc, runner: ProcessRunner, log: JobLogger) async throws {
        guard let job = job(id), let mkvPath = Tools.makemkvcon(config) else {
            throw RipError.missingTool("makemkvcon (MakeMKV)")
        }
        let makemkv = MakeMKV(executable: mkvPath, extraArgs: VideoTranscoder.splitArgs(config.makemkvArgs))
        let selected = job.titles.filter(\.selected)
        guard !selected.isEmpty else { throw RipError.noTitles }
        let rawDir = AppConfig.expand(config.rawPath).appendingPathComponent("\(baseName(job)) [\(id.uuidString.prefix(8))]")
        update(id) { $0.outputPath = rawDir.path }
        let source = MakeMKV.source(bsdName: disc.bsdName)

        var rippedFiles: [(title: DiscTitle, file: URL)] = []
        if config.ripMethod == .backup {
            setStage(id, .ripping, "Creating decrypted backup")
            try await makemkv.backup(source: source, to: rawDir, runner: runner, log: log, onProgress: progressHandler(id))
        } else {
            for (n, title) in selected.enumerated() {
                if isCancelled(id) { throw CancellationError() }
                setStage(id, .ripping, "Ripping title \(title.id) (\(n + 1)/\(selected.count), \(title.durationText))")
                let before = Set((try? FileManager.default.contentsOfDirectory(atPath: rawDir.path)) ?? [])
                try await makemkv.ripTitle(source: source, title: title.id, to: rawDir, runner: runner, log: log,
                                           onProgress: progressHandler(id))
                let after = (try? FileManager.default.contentsOfDirectory(atPath: rawDir.path)) ?? []
                let produced = after.filter { !before.contains($0) && $0.hasSuffix(".mkv") }.sorted()
                let file = produced.first.map { rawDir.appendingPathComponent($0) }
                    ?? rawDir.appendingPathComponent(title.outputFile)
                guard FileManager.default.fileExists(atPath: file.path) else {
                    throw RipError.failed("MakeMKV did not produce a file for title \(title.id)")
                }
                rippedFiles.append((title, file))
                update(id) { j in
                    if let i = j.titles.firstIndex(where: { $0.id == title.id }) { j.titles[i].ripped = true }
                }
            }
        }
        log.write("Ripping finished")
        await ejectAfterRip(id, disc.devicePath)

        // Title, year and kind may have been corrected while the disc was ripping.
        let current = self.job(id) ?? job
        let finalDir = uniqueDirectory(finalVideoDir(current))
        try FileManager.default.createDirectory(at: finalDir, withIntermediateDirectories: true)
        update(id) { $0.outputPath = finalDir.path }
        if config.ripPosters, !current.posterURL.isEmpty {
            await Metadata.downloadImage(current.posterURL, to: finalDir.appendingPathComponent("poster.jpg"))
        }

        let ext = config.destinationExtension.isEmpty ? "mkv" : config.destinationExtension
        let name = baseName(current)
        func destination(for title: DiscTitle, index: Int) -> URL {
            if current.videoKind == .series {
                return finalDir.appendingPathComponent("\(name) - t\(String(format: "%02d", title.id)).\(ext)")
            }
            if title.isMainFeature || selected.count == 1 {
                return finalDir.appendingPathComponent("\(name).\(ext)")
            }
            let extras = config.extrasSubfolder.isEmpty ? finalDir : finalDir.appendingPathComponent(config.extrasSubfolder)
            return extras.appendingPathComponent("\(name) - Extra \(String(format: "%02d", title.id)).\(ext)")
        }

        if config.ripMethod == .backup {
            if config.skipTranscode {
                let target = finalDir.appendingPathComponent("\(name) [Backup]")
                try FileManager.default.moveItem(at: rawDir, to: target)
                update(id) { $0.outputPath = target.path }
                return
            }
            let main = selected.first(where: \.isMainFeature) ?? selected[0]
            try await transcode(id, .backupTitle(rawDir, title: nil), title: main,
                                to: finalDir.appendingPathComponent("\(name).\(ext)"), discType: current.discType,
                                runner: runner, log: log)
        } else {
            for (n, item) in rippedFiles.enumerated() {
                if isCancelled(id) { throw CancellationError() }
                let dest = destination(for: item.title, index: n)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if config.skipTranscode {
                    setStage(id, .finishing, "Moving \(item.file.lastPathComponent)", progress: Double(n) / Double(rippedFiles.count))
                    let target = dest.deletingPathExtension().appendingPathExtension("mkv")
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: item.file, to: target)
                } else {
                    setStage(id, .transcoding, "Transcoding \(n + 1)/\(rippedFiles.count)")
                    try await transcode(id, .file(item.file), title: item.title, to: dest, discType: current.discType,
                                        runner: runner, log: log, label: "Transcoding \(n + 1)/\(rippedFiles.count)")
                }
                update(id) { j in
                    if let i = j.titles.firstIndex(where: { $0.id == item.title.id }) { j.titles[i].transcoded = true }
                }
            }
        }

        setStage(id, .finishing, "Cleaning up", progress: 1)
        if config.deleteRawFiles {
            try? FileManager.default.removeItem(at: rawDir)
            log.write("Deleted raw files: \(rawDir.path)")
        }
    }

    private func transcode(_ id: UUID, _ source: VideoTranscoder.Source, title: DiscTitle, to dest: URL, discType: DiscType,
                           runner: ProcessRunner, log: JobLogger, label: String = "Transcoding") async throws {
        setStage(id, .transcoding, "\(label) – waiting for a free slot")
        await limiter.acquire(limit: config.maxConcurrentTranscodes)
        do {
            setStage(id, .transcoding, "\(label) (\(config.transcoder.label))")
            // Encode into TRANSCODE_PATH first so the library never sees half-written files.
            let work = AppConfig.expand(config.transcodePath).appendingPathComponent(id.uuidString)
                .appendingPathComponent(dest.lastPathComponent)
            try await VideoTranscoder(config: config, discType: discType)
                .transcode(source, to: work, durationSeconds: title.durationSeconds, runner: runner, log: log,
                           onProgress: progressHandler(id))
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: work, to: dest)
            try? FileManager.default.removeItem(at: work.deletingLastPathComponent())
            await limiter.release()
        } catch {
            await limiter.release()
            throw error
        }
    }

    // MARK: Audio

    /// Album level tags of a job, without track specific fields.
    private func albumTags(_ job: Job) -> AudioTags {
        let info = job.audioInfo ?? AudioAlbumInfo()
        var tags = AudioTags()
        tags.album = job.album
        tags.albumArtist = job.artist
        tags.artist = job.artist
        tags.date = info.date.isEmpty ? job.year : info.date
        tags.trackTotal = job.titles.count
        tags.disc = info.discNumber
        tags.discTotal = info.discTotal
        tags.genre = info.genre
        tags.comment = info.comment
        tags.label = info.label
        tags.catalogNumber = info.catalogNumber
        tags.barcode = info.barcode
        tags.country = info.country
        tags.media = info.media
        tags.originalDate = info.originalDate
        tags.albumArtistSort = info.albumArtistSort
        tags.compilation = info.compilation
        tags.musicBrainzReleaseID = job.musicBrainzReleaseID
        tags.musicBrainzReleaseGroupID = info.releaseGroupID
        tags.musicBrainzAlbumArtistID = info.albumArtistID
        tags.musicBrainzDiscID = job.musicBrainzDiscID
        return tags
    }

    private func trackTags(_ album: AudioTags, _ track: DiscTitle) -> AudioTags {
        var tags = album
        let audio = track.audio ?? AudioTrackTags()
        tags.track = track.id
        tags.title = track.name
        tags.artist = audio.artist.isEmpty ? album.albumArtist : audio.artist
        tags.musicBrainzArtistID = audio.artistID.isEmpty ? album.musicBrainzAlbumArtistID : audio.artistID
        tags.musicBrainzRecordingID = audio.recordingID
        tags.musicBrainzReleaseTrackID = audio.releaseTrackID
        tags.isrc = audio.isrc
        tags.composer = audio.composer
        return tags
    }

    private func embeddedCover(_ job: Job) -> AudioTags.EmbeddedCover? {
        guard let cover = job.audioInfo?.cover,
              let e = CoverArt.embeddedData(cover, maxPixels: config.audioEmbedCoverMaxPixels) else { return nil }
        return AudioTags.EmbeddedCover(data: e.data, format: e.format, width: e.width, height: e.height)
    }

    private func audioFolder(_ album: AudioTags) -> URL {
        AppConfig.expand(config.musicPath).appendingPathComponent(AudioRipper.expand(config.audioFolderPattern, album))
    }

    private func audioFileName(_ tags: AudioTags, ext: String) -> String {
        let pattern = AudioRipper.filePattern(config.audioFilePattern, discTotal: tags.discTotal)
        return AudioRipper.expand(pattern, tags) + "." + ext
    }

    /// Saves the original cover next to the music files (cover.jpg / folder.png …), replacing an older one.
    private func saveCoverFile(_ job: Job, in folder: URL) {
        let name = config.audioCoverFileName.isEmpty ? "cover" : config.audioCoverFileName
        for ext in ["jpg", "png"] { try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(name).\(ext)")) }
        guard let cover = job.audioInfo?.cover else { return }
        try? FileManager.default.copyItem(at: cover.url, to: folder.appendingPathComponent("\(name).\(cover.fileExtension)"))
    }

    private func ripAudio(_ id: UUID, runner: ProcessRunner, log: JobLogger) async throws {
        guard let job = job(id) else { return }
        let selected = job.titles.filter(\.selected)
        guard !selected.isEmpty else { throw RipError.noTitles }
        let ripper = AudioRipper(config: config)
        var album = albumTags(job)
        album.cover = embeddedCover(job)
        if let cover = album.cover { log.write("Embedding cover \(cover.width)×\(cover.height) (\(cover.data.count) bytes)") }
        let folder = audioFolder(album)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        update(id) { $0.outputPath = folder.path }
        saveCoverFile(job, in: folder)

        let audioStarted = Date()
        for (n, track) in selected.enumerated() {
            if isCancelled(id) { throw CancellationError() }
            setStage(id, .ripping, "Ripping track \(track.id) (\(n + 1)/\(selected.count))", progress: Double(n) / Double(selected.count))
            update(id) {
                // Track stages change per track, so estimate from the whole audio rip.
                $0.remainingSeconds = Job.estimateRemaining(progress: $0.progress, stageStarted: audioStarted)
            }
            let tags = trackTags(album, track)
            let out = folder.appendingPathComponent(audioFileName(tags, ext: config.audioFormat.fileExtension))
            try await ripper.encode(URL(fileURLWithPath: track.sourceFile), to: out, tags: tags, runner: runner, log: log)
            update(id) { j in
                if let i = j.titles.firstIndex(where: { $0.id == track.id }) {
                    j.titles[i].ripped = true
                    j.titles[i].outputFile = out.lastPathComponent
                }
            }
        }
        update(id) { $0.audioInfo?.tagsChangedAfterRip = false }
        await ejectAfterRip(id, job.devicePath)
    }

    /// Rewrites tags and cover of an already ripped CD after edits and renames files and folder to match.
    func writeTagsToFiles(_ id: UUID) async {
        guard let job = job(id), job.discType == .audioCD, job.status == .success, !retagging.contains(id) else { return }
        retagging.insert(id)
        retagErrors[id] = nil
        defer { retagging.remove(id) }
        let log = JobLogger(url: job.logURL)
        log.write("Rewriting tags of \(job.displayTitle)")
        let runner = ProcessRunner()
        do {
            var album = albumTags(job)
            album.cover = embeddedCover(job)
            let oldFolder = URL(fileURLWithPath: job.outputPath)
            let newFolder = audioFolder(album)
            try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
            // Rename in two steps: a new name may equal the old name of another track, which a direct move
            // would overwrite.
            var moves: [(track: DiscTitle, temp: URL, new: URL, tags: AudioTags)] = []
            for track in job.titles where track.ripped && !track.outputFile.isEmpty {
                let old = oldFolder.appendingPathComponent(track.outputFile)
                guard FileManager.default.fileExists(atPath: old.path) else {
                    log.write("Missing file, skipped: \(old.path)")
                    continue
                }
                let tags = trackTags(album, track)
                let new = newFolder.appendingPathComponent(audioFileName(tags, ext: old.pathExtension))
                let temp = newFolder.appendingPathComponent(".macripper-\(UUID().uuidString).\(old.pathExtension)")
                do {
                    try FileManager.default.moveItem(at: old, to: temp)
                } catch {
                    // Put the files moved so far back, so the job still matches what is on disk.
                    for move in moves {
                        try? FileManager.default.moveItem(at: move.temp, to: oldFolder.appendingPathComponent(move.track.outputFile))
                    }
                    throw error
                }
                moves.append((track, temp, new, tags))
            }
            for move in moves {
                try? FileManager.default.removeItem(at: move.new)
                try FileManager.default.moveItem(at: move.temp, to: move.new)
            }
            // The files now live in the new folder, so the job must point there even if tagging fails below.
            update(id) { j in
                j.outputPath = newFolder.path
                for move in moves {
                    if let i = j.titles.firstIndex(where: { $0.id == move.track.id }) { j.titles[i].outputFile = move.new.lastPathComponent }
                }
            }
            for move in moves {
                try await AudioRipper.writeTags(move.tags, to: move.new, config: config, runner: runner, log: log)
            }
            if let current = self.job(id) { saveCoverFile(current, in: newFolder) }
            if newFolder.standardizedFileURL != oldFolder.standardizedFileURL {
                // Move leftovers (e.g. the old cover) away and remove the old, now empty folders.
                let name = config.audioCoverFileName.isEmpty ? "cover" : config.audioCoverFileName
                for ext in ["jpg", "png"] { try? FileManager.default.removeItem(at: oldFolder.appendingPathComponent("\(name).\(ext)")) }
                removeEmptyFolders(from: oldFolder, stopAt: AppConfig.expand(config.musicPath))
            }
            update(id) { $0.audioInfo?.tagsChangedAfterRip = false }
            log.write("Tags written to \(newFolder.path)")
        } catch {
            log.write("Rewriting tags failed: \(error.localizedDescription)")
            retagErrors[id] = error.localizedDescription
        }
    }

    private func removeEmptyFolders(from folder: URL, stopAt root: URL) {
        var current = folder.standardizedFileURL
        let root = root.standardizedFileURL
        let fm = FileManager.default
        while current.path.hasPrefix(root.path + "/"),
              let items = try? fm.contentsOfDirectory(atPath: current.path),
              items.allSatisfy({ $0 == ".DS_Store" }) {
            try? fm.removeItem(at: current)
            current = current.deletingLastPathComponent()
        }
    }

    // MARK: Data

    private func ripData(_ id: UUID, runner: ProcessRunner, log: JobLogger) async throws {
        guard let job = job(id) else { return }
        let name = AudioRipper.sanitize(job.title.isEmpty ? (job.discLabel.isEmpty ? "Disc" : job.discLabel) : job.title)
        var out = AppConfig.expand(config.dataPath).appendingPathComponent("\(name).iso")
        var n = 1
        while FileManager.default.fileExists(atPath: out.path) {
            n += 1
            out = AppConfig.expand(config.dataPath).appendingPathComponent("\(name) \(n).iso")
        }
        update(id) { $0.outputPath = out.path }
        setStage(id, .ripping, "Creating ISO image")
        try await DataRipper(config: config).rip(devicePath: job.devicePath, mountPoint: job.mountPoint, to: out,
                                                 runner: runner, log: log, onProgress: progressHandler(id))
        await ejectAfterRip(id, job.devicePath)
    }

    // MARK: Post processing

    private func runPostScript(_ job: Job, log: JobLogger) async {
        let script = (config.postJobScript as NSString).expandingTildeInPath
        guard !script.isEmpty else { return }
        guard FileManager.default.isExecutableFile(atPath: script) else {
            log.write("Post-job script is not executable: \(script)")
            return
        }
        // Same positional arguments as ARM's BASH_SCRIPT: title, path, disc type, status
        _ = try? await ProcessRunner().run(script, [job.displayTitle, job.outputPath, job.discType.rawValue, job.status.rawValue],
                                           log: log)
    }
}
