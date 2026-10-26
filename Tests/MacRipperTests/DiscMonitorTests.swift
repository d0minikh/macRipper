import Foundation
import Testing
@testable import MacRipper

@Suite struct DiscMonitorTests {
    /// Every drive the I/O Registry lists must also be listed by drutil, with the same name and bus.
    @Test func ioKitDrivesMatchDrutil() async throws {
        let out = try await ProcessRunner().run("/usr/bin/drutil", ["list"])
        let fromDrutil = DiscMonitor.parseDrutilList(out)
        let fromIOKit = DiscMonitor.ioKitDrives()
        #expect(fromIOKit.map(\.name) == fromDrutil.map(\.name))
        #expect(fromIOKit.map(\.bus) == fromDrutil.map(\.bus))
        #expect(fromIOKit.map(\.id) == fromDrutil.map(\.id))
    }

    /// Ejects a mounted disk image the same way a disc is ejected after ripping, with Finder-style
    /// open files on the volume that the forced retry has to get past.
    @Test func ejectUnmountsAndDetachesAMountedImage() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macripper-eject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("disc.dmg")
        let runner = ProcessRunner()
        try await runner.run("/usr/bin/hdiutil", ["create", "-size", "2m", "-fs", "HFS+", "-volname", "EjectTest",
                                                  "-quiet", image.path])
        let attach = try await runner.run("/usr/bin/hdiutil", ["attach", "-nobrowse", image.path])
        // stderr is in the output too (a deprecation warning), so look for the first device line.
        let device = try #require(attach.split(separator: "\n").first { $0.hasPrefix("/dev/") }
            .flatMap { $0.split(separator: "\t").first }.map { $0.trimmingCharacters(in: .whitespaces) })
        let bsdName = device.replacingOccurrences(of: "/dev/", with: "")
        let mount = try #require(DiscMonitor.mountPoint(for: bsdName))
        let open = try FileHandle(forWritingTo: { () -> URL in
            let url = URL(fileURLWithPath: mount).appendingPathComponent("busy.txt")
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
            return url
        }())
        defer { try? open.close() }

        #expect(await DiscMonitor.eject(device))
        #expect(DiscMonitor.mountPoint(for: bsdName) == nil)
        #expect(!FileManager.default.fileExists(atPath: device))
    }
}
