// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Verse",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Verse",
            path: "Sources/Verse"
        )
    ]
)
