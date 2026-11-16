// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nate",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "nate", targets: ["NateApp"]),
        .library(name: "NateCore", targets: ["NateCore"]),
        .library(name: "NateSearch", targets: ["NateSearch"]),
        .library(name: "NateSyntax", targets: ["NateSyntax"]),
        .library(name: "NateStorage", targets: ["NateStorage"]),
    ],
    targets: [
        .target(name: "NateCore"),
        .target(name: "NateSearch", dependencies: ["NateCore"]),
        .target(name: "NateSyntax", dependencies: ["NateCore"]),
        .target(name: "NateStorage", dependencies: ["NateCore"]),
        .target(name: "NatePlatform"),
        .target(name: "NateUI", dependencies: ["NateCore", "NateSearch", "NateSyntax", "NatePlatform"]),
        .executableTarget(
            name: "NateApp",
            dependencies: ["NateCore", "NateSearch", "NateSyntax", "NateStorage", "NatePlatform", "NateUI"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
