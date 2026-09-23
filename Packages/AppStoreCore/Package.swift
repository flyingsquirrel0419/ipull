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
        .target(name: "CBzip2"),
        .target(
            name: "CUnicorn",
            linkerSettings: [.unsafeFlags(["-L", "Vendor/unicorn/lib", "-L", "Packages/AppStoreCore/Vendor/unicorn/lib", "-lunicorn"])]
        ),
        .target(
            name: "AppStoreCore",
            dependencies: ["CZlib", "CBzip2", "CUnicorn"]
        ),
        .testTarget(
            name: "AppStoreCoreTests",
            dependencies: ["AppStoreCore"]
        )
    ]
)
