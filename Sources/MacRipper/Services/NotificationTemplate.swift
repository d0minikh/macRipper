import Foundation

enum NotificationEvent: String, CaseIterable, Identifiable {
    case ripStarted, finished, failed
    var id: String { rawValue }

    var label: String {
        switch self {
        case .ripStarted: "Rip started"
        case .finished: "Job finished"
        case .failed: "Job failed"
        }
    }

    var titleKeyPath: WritableKeyPath<AppConfig, String> {
        switch self {
        case .ripStarted: \.templateRipStartedTitle
        case .finished: \.templateFinishedTitle
        case .failed: \.templateFailedTitle
        }
    }

    var bodyKeyPath: WritableKeyPath<AppConfig, String> {
        switch self {
        case .ripStarted: \.templateRipStartedBody
        case .finished: \.templateFinishedBody
        case .failed: \.templateFailedBody
        }
    }

    var isEnabledKeyPath: WritableKeyPath<AppConfig, Bool> {
        switch self {
        case .ripStarted: \.notifyOnRipStart
        case .finished: \.notifyOnFinish
        case .failed: \.notifyOnFailure
        }
    }
}

/// User editable notification texts with `{variable}` placeholders.
enum NotificationTemplate {
    struct Variable: Identifiable {
        var id: String { name }
        let name: String
        let description: String
    }

    static let variables: [Variable] = [
        Variable(name: "title", description: "Display title: movie with year, or “Artist – Album” for CDs"),
        Variable(name: "name", description: "Title without the year (album name for CDs)"),
        Variable(name: "year", description: "Release year, if known"),
        Variable(name: "type", description: "Disc type: DVD, Blu-ray, Audio CD or Data Disc"),
        Variable(name: "kind", description: "Movie or Series (video discs)"),
        Variable(name: "artist", description: "Artist (audio CDs)"),
        Variable(name: "album", description: "Album (audio CDs)"),
        Variable(name: "label", description: "Volume label of the disc"),
        Variable(name: "status", description: "Job status, e.g. Finished or Failed"),
        Variable(name: "error", description: "Error message (only for failed jobs)"),
        Variable(name: "duration", description: "How long the job took, e.g. “1 hr, 12 min”"),
        Variable(name: "duration_hms", description: "How long the job took as h:mm:ss"),
        Variable(name: "started", description: "Date and time the disc was inserted"),
        Variable(name: "finished", description: "Date and time the job ended"),
        Variable(name: "titles", description: "Number of selected titles or tracks"),
        Variable(name: "path", description: "Output folder or file"),
        Variable(name: "drive", description: "Name of the optical drive"),
        Variable(name: "imdb", description: "IMDb ID, e.g. tt1375666"),
        Variable(name: "imdb_url", description: "Link to the IMDb page"),
        Variable(name: "host", description: "Name of this Mac"),
        Variable(name: "job_id", description: "Unique job ID"),
    ]

    static func values(for job: Job) -> [String: String] {
        let isAudio = job.discType == .audioCD
        let finished = job.finished
        return [
            "title": job.displayTitle,
            "name": isAudio ? job.album : (job.title.isEmpty ? job.discLabel : job.title),
            "year": job.year,
            "type": job.discType.label,
            "kind": job.discType.isVideo ? job.videoKind.label : "",
            "artist": job.artist,
            "album": job.album,
            "label": job.discLabel,
            "status": job.status.label,
            "error": job.errorMessage ?? "",
            "duration": Job.formatDuration(job.elapsedSeconds),
            "duration_hms": DiscTitle.format(seconds: job.elapsedSeconds),
            "started": job.created.formatted(date: .abbreviated, time: .shortened),
            "finished": finished?.formatted(date: .abbreviated, time: .shortened) ?? "",
            "titles": "\(job.titles.filter(\.selected).count)",
            "path": job.outputPath,
            "drive": job.driveName,
            "imdb": job.imdbID,
            "imdb_url": job.imdbID.isEmpty ? "" : "https://www.imdb.com/title/\(job.imdbID)/",
            "host": Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            "job_id": job.id.uuidString,
        ]
    }

    /// Replaces `{name}` with its value. Unknown placeholders are left untouched so typos stay visible.
    static func render(_ template: String, values: [String: String]) -> String {
        var out = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            rest = rest[open...]
            guard let close = rest.firstIndex(of: "}") else { break }
            let key = String(rest[rest.index(after: open)..<close])
            if let value = values[key] { out += value } else { out += rest[open...close] }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    static func render(_ event: NotificationEvent, job: Job, config: AppConfig) -> (title: String, body: String) {
        let values = values(for: job)
        let title = render(config[keyPath: event.titleKeyPath], values: values)
        let body = render(config[keyPath: event.bodyKeyPath], values: values)
        return (title.isEmpty ? "MacRipper" : title, body)
    }

    /// Example job used for the settings preview and test notifications.
    static var sampleJob: Job {
        var job = Job(devicePath: "/dev/disk4", driveName: "BD-RE Drive")
        job.created = Date().addingTimeInterval(-4_325)
        job.finished = Date()
        job.discType = .bluray
        job.discLabel = "INCEPTION"
        job.title = "Inception"
        job.year = "2010"
        job.videoKind = .movie
        job.imdbID = "tt1375666"
        job.status = .success
        job.outputPath = (AppConfig.expand("~/Movies/MacRipper/completed/movies/Inception (2010)").path)
        job.titles = [DiscTitle(id: 0, name: "Inception", durationSeconds: 8_880, isMainFeature: true)]
        return job
    }
}
