// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HeadroomCore", targets: ["HeadroomCore"]),
        // The app binary is renamed to "Headroom" inside Headroom.app by build.sh.
        // (A product named "Headroom" would collide with "headroom" on a
        // case-insensitive file system.)
        .executable(name: "HeadroomApp", targets: ["Headroom"]),
        .executable(name: "headroom", targets: ["headroom-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "HeadroomCore"),
        .executableTarget(name: "Headroom", dependencies: ["HeadroomCore"]),
        .executableTarget(
            name: "headroom-cli",
            dependencies: [
                "HeadroomCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(
            name: "HeadroomCoreTests",
            dependencies: ["HeadroomCore"],
            resources: [.copy("Fixtures")]),
    ]
)
