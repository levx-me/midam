// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Midam",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The agent terminal tabs' emulator (MIT, Resources/SwiftTerm.LICENSE.txt). Pinned: bump by hand.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.2")
    ],
    targets: [
        // Resources live in ./Resources and are copied into the .app by build.sh (no Bundle.module).
        .executableTarget(name: "Midam", dependencies: ["SwiftTerm"], path: "Sources/Midam")
    ]
)
