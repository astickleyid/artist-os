// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ArtistOS",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ArtistOS", targets: ["ArtistOS"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "6.29.0"))
    ],
    targets: [
        .executableTarget(
            name: "ArtistOS",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/ArtistOS"
        ),
        .testTarget(
            name: "ArtistOSTests",
            dependencies: ["ArtistOS"],
            path: "Tests/ArtistOSTests"
        )
    ]
)
