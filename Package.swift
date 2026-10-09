// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Procul",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Procul",
            path: "Sources/Procul"
        ),
        .testTarget(
            name: "ProculTests",
            dependencies: ["Procul"],
            path: "Tests/ProculTests"
        ),
    ]
)
