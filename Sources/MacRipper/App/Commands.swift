import SwiftUI

/// Menu bar commands with the keyboard shortcuts of the toolbar actions.
struct MacRipperCommands: Commands {
    @ObservedObject var manager: JobManager
    @ObservedObject var monitor: DiscMonitor
    @ObservedObject var tagEditor: TagEditor
    @FocusedValue(\.tagTargets) private var tagTargets
    @FocusedValue(\.tagSaveScope) private var tagSaveScope
    @FocusedValue(\.tagSingleAlbum) private var tagSingleAlbum
    @FocusedBinding(\.tagSheet) private var tagSheet
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

    /// Changed songs of the album on screen or the selected albums, or every changed song on the Tag Editor page.
    /// The whole album is saved even when only some songs are selected, as with the toolbar button.
    private var tagSaveTargets: [UUID] {
        (tagSaveScope ?? []).filter { tagEditor.tracks[$0]?.isModified == true && !tagEditor.saving.contains($0) }
    }

    /// Lookups, covers and numbering work on one album at a time.
    private var oneAlbumTargets: [UUID]? { tagSingleAlbum == true ? tagTargets : nil }

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
            Button("Tag Editor") { selection = .tagEditor }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(selection == nil)
        }
        CommandGroup(after: .newItem) {
            Button("Add Music to Tag Editor…") {
                if selection??.isTagEditor != true { selection = .tagEditor }
                tagEditor.chooseAndAdd()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(tagEditor.loading != nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Tags") { Task { await tagEditor.save(tagSaveTargets) } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(tagSaveTargets.isEmpty)
        }
        CommandMenu("Tags") {
            Button("Look Up on MusicBrainz…") { if let ids = oneAlbumTargets { tagSheet = .albumLookup(ids) } }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(oneAlbumTargets == nil || tagSheet == nil)
            Button("Look Up Song on MusicBrainz…") {
                if let id = oneAlbumTargets?.first { tagSheet = .songLookup(id) }
            }
            .disabled(oneAlbumTargets?.count != 1 || tagSheet == nil)
            Button("Find Covers…") { if let ids = oneAlbumTargets { tagSheet = .covers(ids) } }
                .disabled(oneAlbumTargets == nil || tagSheet == nil)
            Divider()
            Button("Number Tracks in Order") { if let ids = oneAlbumTargets { tagEditor.numberTracks(ids) } }
                .disabled(oneAlbumTargets == nil)
            Button("Capitalize Titles") { if let tagTargets { tagEditor.capitalizeTitles(tagTargets) } }
                .disabled(tagTargets == nil)
            Button("Tags from File Names") { if let tagTargets { tagEditor.tagsFromFileNames(tagTargets) } }
                .disabled(tagTargets == nil)
            Button("Rename Files…") { if let tagTargets { tagSheet = .rename(tagTargets) } }
                .disabled(tagTargets == nil || tagSheet == nil)
            Divider()
            Button("Revert Changes") { tagEditor.revert(tagSaveTargets) }
                .disabled(tagSaveTargets.isEmpty)
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
