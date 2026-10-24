// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacRipper",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "MacRipper",
            path: "Sources/MacRipper",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "MacRipperTests",
            dependencies: ["MacRipper"],
            path: "Tests/MacRipperTests"
        ),
    ]
)
