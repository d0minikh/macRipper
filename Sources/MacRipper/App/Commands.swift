import SwiftUI

/// Menu bar commands with the keyboard shortcuts of the toolbar actions.
struct MacRipperCommands: Commands {
    @ObservedObject var manager: JobManager
    @ObservedObject var monitor: DiscMonitor
    @FocusedValue(\.selectedJobID) private var selectedJobID
    @FocusedBinding(\.inspectorVisible) private var inspectorVisible
    @FocusedBinding(\.showLog) private var showLog
    @FocusedBinding(\.confirmAbandon) private var confirmAbandon
    @FocusedBinding(\.showMetadataSearch) private var showMetadataSearch
    @FocusedBinding(\.sidebarSelection) private var selection

    private var selectedJob: Job? { selectedJobID.flatMap(manager.job) }
    private var idleDiscs: [DetectedDisc] { monitor.discs.filter { !manager.isBusy($0.devicePath) } }

    /// The disc of the selected job, or the only inserted disc.
    private var ejectTarget: DetectedDisc? {
        if let job = selectedJob, let disc = monitor.discs.first(where: { $0.devicePath == job.devicePath }) { return disc }
        return monitor.discs.count == 1 ? monitor.discs.first : nil
    }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(inspectorVisible == true ? "Hide Inspector" : "Show Inspector") { inspectorVisible?.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(inspectorVisible == nil)
            Divider()
            Button("Drives") { selection = .drives }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(selection == nil)
            Button("Tools") { selection = .tools }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(selection == nil)
        }
        CommandMenu("Disc") {
            Button(idleDiscs.count > 1 ? "Rip All Inserted Discs" : "Rip Inserted Disc") {
                idleDiscs.forEach(manager.startJob(for:))
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(idleDiscs.isEmpty)
            Button("Eject Disc") {
                if let disc = ejectTarget { Task { await DiscMonitor.eject(disc.devicePath) } }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(ejectTarget.map { manager.isBusy($0.devicePath) } ?? true)
            Divider()
            Button("Start Now") { if let id = selectedJobID { manager.startNow(id) } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(selectedJob?.status != .waiting)
            Button("Abandon Job…") { confirmAbandon = true }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(selectedJob?.status.isActive != true || confirmAbandon == nil)
            Divider()
            Button("Search Metadata…") { showMetadataSearch = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(showMetadataSearch == nil)
            Button("Write Tags to Files") { if let id = selectedJobID { Task { await manager.writeTagsToFiles(id) } } }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(selectedJob?.audioInfo?.tagsChangedAfterRip != true || selectedJob?.status != .success)
            Button("Show Log") { showLog = true }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(showLog == nil)
        }
    }
}
