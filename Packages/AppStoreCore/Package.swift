// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppStoreCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AppStoreCore", targets: ["AppStoreCore"])
    ],
    targets: [
        .target(name: "CZlib"),
        .target(
            name: "CUnicorn",
            cSettings: [.unsafeFlags(["-I/tmp/unicorn-src/include"])],
            linkerSettings: [.unsafeFlags(["-L/tmp/unicorn-src/build", "-lunicorn"])]
        ),
        .target(
            name: "AppStoreCore",
            dependencies: ["CZlib", "CUnicorn"]
        ),
        .testTarget(
            name: "AppStoreCoreTests",
            dependencies: ["AppStoreCore"]
        )
    ]
)
