// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeSwitcher",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwitcherCore", targets: ["SwitcherCore"]),
        .executable(name: "ClaudeSwitcher", targets: ["ClaudeSwitcher"]),
    ],
    targets: [
        .target(name: "SwitcherCore"),
        .executableTarget(name: "ClaudeSwitcher", dependencies: ["SwitcherCore"]),
        .testTarget(name: "SwitcherCoreTests", dependencies: ["SwitcherCore"]),
    ],
    swiftLanguageModes: [.v6]
)
