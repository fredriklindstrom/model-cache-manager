// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ModelCacheManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ModelCacheManager", path: "Sources/ModelCacheManager")
    ]
)
