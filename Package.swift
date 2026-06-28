// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ArtistOS",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ArtistOS", targets: ["ArtistOS"])
    ],
    targets: [
        .executableTarget(
            name: "ArtistOS",
            path: "Sources/ArtistOS"
        )
    ]
)
