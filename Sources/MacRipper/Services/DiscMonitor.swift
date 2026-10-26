import AppKit
import DiskArbitration
import IOKit

struct DetectedDisc: Identifiable, Hashable {
    var id: String { bsdName }
    let bsdName: String          // disk4
    let mediaKind: String        // IOCDMedia / IODVDMedia / IOBDMedia
    let deviceModel: String
    var devicePath: String { "/dev/\(bsdName)" }

    var mediaLabel: String {
        switch mediaKind {
        case "IOBDMedia": "Blu-ray"
        case "IODVDMedia": "DVD"
        case "IOCDMedia": "CD"
        default: mediaKind
        }
    }
}

struct OpticalDrive: Identifiable, Hashable {
    let id: Int
    let vendor: String
    let product: String
    let bus: String
    var name: String { "\(vendor) \(product)" }
}

/// Watches DiskArbitration for optical media being inserted or removed
/// (the macOS equivalent of ARM's udev rule).
@MainActor
final class DiscMonitor: ObservableObject {
    @Published private(set) var discs: [DetectedDisc] = []
    @Published private(set) var drives: [OpticalDrive] = []

    var onInserted: ((DetectedDisc, _ presentAtLaunch: Bool) -> Void)?
    var onRemoved: ((DetectedDisc) -> Void)?

    private var session: DASession?
    private var drivePort: IONotificationPortRef?
    private var driveIterators: [io_iterator_t] = []
    private var wakeObserver: NSObjectProtocol?
    /// Discs reported again while rescanning; nil outside a rescan.
    private var rescanSeen: Set<String>?
    private let launchDate = Date()

    nonisolated static let opticalKinds: Set<String> = ["IOCDMedia", "IODVDMedia", "IOBDMedia"]

    func start() {
        guard session == nil else { return }
        startSession()
        watchDrives()
        // A USB drive can drop off and come back while the Mac sleeps, and events in between may be missed.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self?.refresh()
            }
        }
        refreshDrives()
    }

    /// Lists the drives again and asks DiskArbitration for the discs that are in them right now.
    func refresh() {
        refreshDrives()
        rescanDiscs()
    }

    private func startSession() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let match = [kDADiskDescriptionMediaWholeKey as String: true] as CFDictionary

        DARegisterDiskAppearedCallback(session, match, { disk, ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<DiscMonitor>.fromOpaque(ctx).takeUnretainedValue()
            let info = DiscMonitor.describe(disk)
            MainActor.assumeIsolated { monitor.appeared(info) }
        }, ctx)

        DARegisterDiskDisappearedCallback(session, match, { disk, ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<DiscMonitor>.fromOpaque(ctx).takeUnretainedValue()
            let info = DiscMonitor.describe(disk)
            MainActor.assumeIsolated { monitor.disappeared(info) }
        }, ctx)

        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    /// A new session replays every disc that is present; discs it no longer reports are gone.
    private func rescanDiscs() {
        guard rescanSeen == nil else { return }
        if let session {
            DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        session = nil
        rescanSeen = []
        startSession()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let seen = rescanSeen ?? []
            rescanSeen = nil
            for disc in discs where !seen.contains(disc.bsdName) { disappeared(disc) }
        }
    }

    nonisolated static func describe(_ disk: DADisk) -> DetectedDisc? {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any],
              let kind = desc[kDADiskDescriptionMediaKindKey as String] as? String,
              opticalKinds.contains(kind),
              let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) })
        else { return nil }
        let model = (desc[kDADiskDescriptionDeviceModelKey as String] as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return DetectedDisc(bsdName: bsd, mediaKind: kind, deviceModel: model)
    }

    private func appeared(_ disc: DetectedDisc?) {
        guard let disc else { return }
        rescanSeen?.insert(disc.bsdName)
        guard !discs.contains(disc) else { return }
        discs.append(disc)
        // DiskArbitration replays already present disks right after registration. Neither those nor discs found
        // by a rescan start a rip on their own: after a wake that may be a disc that was ripped already.
        onInserted?(disc, rescanSeen != nil || Date().timeIntervalSince(launchDate) < 3)
    }

    private func disappeared(_ disc: DetectedDisc?) {
        guard let disc else { return }
        discs.removeAll { $0.bsdName == disc.bsdName }
        onRemoved?(disc)
    }

    func refreshDrives() {
        let found = Self.ioKitDrives()
        if !found.isEmpty {
            drives = found
            return
        }
        // Fallback for drives IOKit does not describe; drutil may block on a busy drive, so off the main thread.
        Task.detached {
            let out = (try? await ProcessRunner().run("/usr/bin/drutil", ["list"])) ?? ""
            let drives = DiscMonitor.parseDrutilList(out)
            await MainActor.run { self.drives = drives }
        }
    }

    /// Reads the drives from the I/O Registry, which answers at once even while a drive is busy or asleep.
    /// They are numbered in registry order, the order drutil uses for `-drive`.
    nonisolated static func ioKitDrives() -> [OpticalDrive] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOCDBlockStorageDevice"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var drives: [OpticalDrive] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func dict(_ key: String) -> [String: Any] {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] ?? [:]
            }
            let device = dict("Device Characteristics"), proto = dict("Protocol Characteristics")
            let trim = { (v: Any?) in ((v as? String) ?? "").trimmingCharacters(in: .whitespaces) }
            drives.append(OpticalDrive(id: drives.count + 1, vendor: trim(device["Vendor Name"]),
                                       product: trim(device["Product Name"]),
                                       bus: trim(proto["Physical Interconnect"])))
        }
        return drives
    }

    /// Updates the drive list when a drive is connected or disconnected.
    private func watchDrives() {
        guard drivePort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        drivePort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { ctx, iterator in
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
            guard let ctx else { return }
            let monitor = Unmanaged<DiscMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refreshDrives() }
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(port, type, IOServiceMatching("IOCDBlockStorageDevice"),
                                                   callback, ctx, &iterator) == KERN_SUCCESS else { continue }
            // Arms the notification; the drives present now are read by refreshDrives().
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
            driveIterators.append(iterator)
        }
    }

    nonisolated static func parseDrutilList(_ output: String) -> [OpticalDrive] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 5, let idx = Int(parts[0]) else { return nil }
            return OpticalDrive(id: idx, vendor: parts[1], product: parts[2..<(parts.count - 3)].joined(separator: " "),
                                bus: parts[parts.count - 2])
        }
    }

    // MARK: - Helpers

    /// Finds the mount point of a disc (the volume may live on the whole disk or a slice).
    nonisolated static func mountPoint(for bsdName: String) -> String? {
        var count: Int32 = 0
        var mounts: UnsafeMutablePointer<statfs>?
        count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return nil }
        for i in 0..<Int(count) {
            var fs = mounts[i]
            let from = withUnsafePointer(to: &fs.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let dev = from.replacingOccurrences(of: "/dev/", with: "")
            if dev == bsdName || dev.hasPrefix(bsdName + "s") {
                return withUnsafePointer(to: &fs.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
            }
        }
        return nil
    }

    nonisolated static func waitForMount(_ bsdName: String, timeout: TimeInterval = 45) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            if let mp = mountPoint(for: bsdName) { return mp }
            try? await Task.sleep(for: .seconds(1))
        }
        return nil
    }

    /// Unmounts and ejects the disc. A drive that just finished reading can stay locked for a few seconds, and
    /// Finder or Spotlight may still hold the volume, so it retries and forces the unmount from the second try.
    @discardableResult
    nonisolated static func eject(_ devicePath: String, log: JobLogger? = nil) async -> Bool {
        let bsdName = devicePath.replacingOccurrences(of: "/dev/", with: "")
        for attempt in 1...5 {
            if attempt > 1 { try? await Task.sleep(for: .seconds(attempt)) }
            switch await DiskEjector.eject(bsdName: bsdName, force: attempt > 1) {
            case .ejected:
                log?.write("Disc ejected")
                return true
            case .gone:
                return true
            case .failed(let reason):
                log?.write("Eject attempt \(attempt) failed: \(reason)")
            }
        }
        if (try? await ProcessRunner().run("/usr/sbin/diskutil", ["eject", devicePath], log: log)) != nil {
            log?.write("Disc ejected")
            return true
        }
        log?.write("Could not eject the disc")
        return false
    }

    nonisolated static func unmount(_ devicePath: String) async {
        _ = try? await ProcessRunner().run("/usr/sbin/diskutil", ["unmountDisk", devicePath])
    }

    nonisolated static func mount(_ devicePath: String) async {
        _ = try? await ProcessRunner().run("/usr/sbin/diskutil", ["mountDisk", devicePath])
    }
}

/// Unmount and eject through DiskArbitration, which reports why it failed (unlike `diskutil`, whose output
/// was lost before).
private enum DiskEjector {
    enum Result: Sendable { case ejected, gone, failed(String) }

    private final class Box: @unchecked Sendable {
        let continuation: CheckedContinuation<String?, Never>
        init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
    }

    private static let queue = DispatchQueue(label: "MacRipper.eject")

    static func eject(bsdName: String, force: Bool) async -> Result {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return .failed("No DiskArbitration session") }
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
              DADiskCopyDescription(disk) != nil else { return .gone }

        var options = DADiskUnmountOptions(kDADiskUnmountOptionWhole)
        if force { options |= DADiskUnmountOptions(kDADiskUnmountOptionForce) }
        if let error = await withCheckedContinuation({ (cont: CheckedContinuation<String?, Never>) in
            DADiskUnmount(disk, options, { _, dissenter, ctx in
                Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue().continuation.resume(returning: DiskEjector.describe(dissenter))
            }, Unmanaged.passRetained(Box(cont)).toOpaque())
        }) {
            return .failed("unmount: \(error)")
        }
        if let error = await withCheckedContinuation({ (cont: CheckedContinuation<String?, Never>) in
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, ctx in
                Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue().continuation.resume(returning: DiskEjector.describe(dissenter))
            }, Unmanaged.passRetained(Box(cont)).toOpaque())
        }) {
            return .failed("eject: \(error)")
        }
        return .ejected
    }

    fileprivate static func describe(_ dissenter: DADissenter?) -> String? {
        guard let dissenter else { return nil }
        let status = DADissenterGetStatus(dissenter)
        if status == kDAReturnNotMounted { return nil }
        let text = DADissenterGetStatusString(dissenter) as String?
        return String(format: "0x%08x", UInt32(bitPattern: status)) + (text.map { " (\($0))" } ?? "")
    }
}
