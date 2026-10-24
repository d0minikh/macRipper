import Foundation
import DiskArbitration

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
    private let launchDate = Date()

    nonisolated static let opticalKinds: Set<String> = ["IOCDMedia", "IODVDMedia", "IOBDMedia"]

    func start() {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
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
        refreshDrives()
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
        guard let disc, !discs.contains(disc) else { return }
        discs.append(disc)
        // DiskArbitration replays already present disks right after registration.
        onInserted?(disc, Date().timeIntervalSince(launchDate) < 3)
    }

    private func disappeared(_ disc: DetectedDisc?) {
        guard let disc else { return }
        discs.removeAll { $0.bsdName == disc.bsdName }
        onRemoved?(disc)
    }

    func refreshDrives() {
        Task.detached {
            let out = (try? await ProcessRunner().run("/usr/bin/drutil", ["list"])) ?? ""
            let drives = DiscMonitor.parseDrutilList(out)
            await MainActor.run { self.drives = drives }
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

    nonisolated static func eject(_ devicePath: String) async {
        let runner = ProcessRunner()
        if (try? await runner.run("/usr/sbin/diskutil", ["eject", devicePath])) == nil {
            _ = try? await runner.run("/usr/bin/drutil", ["eject"])
        }
    }

    nonisolated static func unmount(_ devicePath: String) async {
        _ = try? await ProcessRunner().run("/usr/sbin/diskutil", ["unmountDisk", devicePath])
    }

    nonisolated static func mount(_ devicePath: String) async {
        _ = try? await ProcessRunner().run("/usr/sbin/diskutil", ["mountDisk", devicePath])
    }
}
