#if DEBUG
import AppKit
import SwiftUI

/// Development helpers, only compiled into debug builds:
/// - MACRIPPER_DEMO=1 adds sample jobs so every view can be inspected without a disc.
/// - MACRIPPER_SNAPSHOT=/path/prefix writes PNG snapshots of the app's windows.
/// - MACRIPPER_RIP_PRESENT=1 starts jobs for discs that were already inserted at launch.
/// - MACRIPPER_SELECT=tools|history|tags|tagalbum|tagall opens the Tools section, the newest history job, the Tag Editor,
///   its first album, or the Tag Editor with all albums selected on launch.
/// - MACRIPPER_TAG_FILES=<path>[:<path>…] adds these files or folders to the Tag Editor.
/// - MACRIPPER_TAG_INSPECTOR_WINDOW=info|artwork|file shows the Tag Editor inspector of the first album in a plain window;
///   with MACRIPPER_TAG_INSPECTOR_ALL=1 it edits all albums together.
/// - MACRIPPER_DROP_PREVIEW=1 shows the Tag Editor's drop highlights as if files were dragged over them.
/// - MACRIPPER_CLEAR_HISTORY=<seconds> clears the job history after the given delay.
/// - MACRIPPER_INSPECTOR_WINDOW=info|artwork|file shows the inspector of the newest job in a plain window
///   (window snapshots cannot capture the Liquid Glass inspector column).
/// - MACRIPPER_INSPECTOR=0|1 hides or shows the inspector panel on launch.
/// - MACRIPPER_SETTINGS_TAB=<tab> opens Settings on that tab (general, video, audio, metadata, notifications, advanced).
@MainActor
enum DebugSupport {
    private static var inspectorWindow: NSWindow?

    static func setUp(_ manager: JobManager, tagEditor: TagEditor) {
        let env = ProcessInfo.processInfo.environment
        if let paths = env["MACRIPPER_TAG_FILES"] {
            let urls = paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            Task { await tagEditor.add(urls) }
        }
        if let tab = env["MACRIPPER_TAG_INSPECTOR_WINDOW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let albums = tagEditor.sortedAlbums.map(\.album.id)
                guard let first = albums.first else { return }
                UserDefaults.standard.set(tab, forKey: "inspectorTab")
                let ids = env["MACRIPPER_TAG_INSPECTOR_ALL"] == "1" ? albums : [first]
                let view = TagEditorInspector(albumIDs: ids, selection: [], sheet: .constant(nil))
                    .environmentObject(tagEditor)
                    .frame(width: 340, height: 900)
                let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 340, height: 900),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.title = "Tag Inspector (debug)"
                window.contentView = NSHostingView(rootView: view)
                window.orderFront(nil)
                inspectorWindow = window
            }
        }
        if env["MACRIPPER_DEMO"] == "1" {
            // Delayed so the sidebar auto-selects the new job like a freshly inserted disc.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { manager.injectDemoJobs() }
        }
        if let tab = env["MACRIPPER_INSPECTOR_WINDOW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let job = manager.activeJobs.first ?? manager.finishedJobs.first else { return }
                UserDefaults.standard.set(tab, forKey: "inspectorTab")
                let view = JobInspector(jobID: job.id)
                    .environmentObject(manager)
                    .environmentObject(manager.configStore)
                    .frame(width: 340, height: 760)
                let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 340, height: 760),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.title = "Inspector (debug)"
                window.contentView = NSHostingView(rootView: view)
                window.orderFront(nil)
                inspectorWindow = window
            }
        }
        if let delay = Double(env["MACRIPPER_CLEAR_HISTORY"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { manager.clearHistory() }
        }
        if env["MACRIPPER_RIP_PRESENT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                manager.monitor.discs.forEach(manager.startJob(for:))
            }
        }
        if let prefix = env["MACRIPPER_SNAPSHOT"] {
            let delay = Double(env["MACRIPPER_SNAPSHOT_DELAY"] ?? "") ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { snapshot(prefix) }
        }
    }

    static func snapshot(_ prefix: String) {
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(i).png"))
        }
    }
}

extension JobManager {
    func injectDemoJobs() {
        var movie = Job(devicePath: "/dev/disk4", driveName: "TSSTcorp BDDVDW SE-506CB")
        movie.discType = .bluray
        movie.discLabel = "INCEPTION_DISC_1"
        movie.title = "Inception"
        movie.year = "2010"
        movie.videoKind = .movie
        movie.imdbID = "tt1375666"
        movie.status = .transcoding
        movie.stage = "Transcoding 1/2 (HandBrakeCLI)"
        movie.progress = 0.42
        movie.titles = [
            DiscTitle(id: 0, name: "Inception", durationSeconds: 8880, chapters: 28, sizeBytes: 32_000_000_000,
                      sourceFile: "00800.mpls", isMainFeature: true, ripped: true),
            DiscTitle(id: 3, name: "Making of", durationSeconds: 1460, chapters: 4, sizeBytes: 3_200_000_000,
                      sourceFile: "00801.mpls", ripped: true),
            DiscTitle(id: 7, name: "Trailer", durationSeconds: 140, sizeBytes: 200_000_000, sourceFile: "00810.mpls",
                      selected: false),
        ]
        var cd = Job(devicePath: "/dev/disk5", driveName: "USB SuperDrive")
        cd.discType = .audioCD
        cd.artist = "Daft Punk"
        cd.album = "Discovery"
        cd.year = "2001"
        cd.status = .waiting
        cd.stage = "Starting automatically in 42s – review titles now"
        cd.progress = 0.3
        cd.musicBrainzDiscID = "49HHV7Eb8UKF3aQiNmu1GR8vKTY-"
        cd.titles = ["One More Time", "Aerodynamic", "Digital Love", "Harder, Better, Faster, Stronger"]
            .enumerated().map { DiscTitle(id: $0 + 1, name: $1, durationSeconds: 200 + $0 * 17) }
        var iso = Job(devicePath: "/dev/disk4")
        iso.discType = .data
        iso.discLabel = "BACKUP_2019"
        iso.status = .success
        iso.finished = Date()
        var failed = Job(devicePath: "/dev/disk4")
        failed.discType = .dvd
        failed.discLabel = "SCRATCHED"
        failed.status = .failed
        failed.errorMessage = "makemkvcon exited with code 1"
        failed.finished = Date()
        insertForDebug([movie, cd, iso, failed])
    }
}
#endif
