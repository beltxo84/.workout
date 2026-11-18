// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "WorkoutDesigner",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "WorkoutDesigner", path: "Sources/WorkoutDesigner")
    ]
)
