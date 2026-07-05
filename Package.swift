// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ArtistOS",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "ArtistOS", targets: ["ArtistOS"]),
        // Cross-platform pure logic shared by the macOS app and the iOS companion.
        .library(name: "ArtistOSCore", targets: ["ArtistOSCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "6.29.0"))
    ],
    targets: [
        // Platform-agnostic intelligence: segmentation, assembly, and (over time)
        // the version/decision/sync logic shared across platforms. No UI, no AppKit.
        .target(
            name: "ArtistOSCore",
            path: "Sources/ArtistOSCore"
        ),
        .executableTarget(
            name: "ArtistOS",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "ArtistOSCore"
            ],
            path: "Sources/ArtistOS"
        ),
        .testTarget(
            name: "ArtistOSTests",
            dependencies: ["ArtistOS"],
            path: "Tests/ArtistOSTests"
        ),
        .testTarget(
            name: "ArtistOSCoreTests",
            dependencies: ["ArtistOSCore"],
            path: "Tests/ArtistOSCoreTests"
        )
    ]
)
