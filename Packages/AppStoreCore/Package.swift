// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppStoreCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AppStoreCore", targets: ["AppStoreCore"])
    ],
    targets: [
        .target(name: "AppStoreCore"),
        .testTarget(
            name: "AppStoreCoreTests",
            dependencies: ["AppStoreCore"]
        )
    ]
)
