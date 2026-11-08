// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LimbaKit",
    platforms: [.macOS(.v13)],
    products: [
        // What an app adds to become translatable.
        .library(name: "LimbaKit", targets: ["LimbaKit"]),
        // The protocol's file formats and types, for tools that read or write translations.
        .library(name: "LimbaCore", targets: ["LimbaCore"]),
    ],
    targets: [
        .target(name: "LimbaHook", path: "Sources/LimbaHook"),
        .target(name: "LimbaCore", path: "Sources/LimbaCore"),
        .target(name: "LimbaKit", dependencies: ["LimbaHook", "LimbaCore"], path: "Sources/LimbaKit", resources: [.copy("Resources/Limba.png")]),
        .testTarget(name: "LimbaCoreTests", dependencies: ["LimbaCore"], path: "Tests/LimbaCoreTests"),
        .testTarget(name: "LimbaKitTests", dependencies: ["LimbaKit", "LimbaHook"], path: "Tests/LimbaKitTests"),
    ]
)
