// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Midam",
    platforms: [.macOS(.v14)],
    targets: [
        // Resources live in ./Resources and are copied into the .app by build.sh (no Bundle.module).
        .executableTarget(name: "Midam", path: "Sources/Midam")
    ]
)
