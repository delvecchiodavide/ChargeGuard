// swift-tools-version:5.9
import PackageDescription

// The package builds every component from the command line (`swift build`)
// and is also consumed by the Xcode project (project.yml) as a local package
// for the shared libraries SMCKit and ChargeCore.
let package = Package(
    name: "ChargeGuard",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SMCKit", targets: ["SMCKit"]),
        .library(name: "ChargeCore", targets: ["ChargeCore"]),
        .executable(name: "cgctl", targets: ["cgctl"]),
    ],
    targets: [
        .target(name: "CSMC"),
        .target(name: "SMCKit", dependencies: ["CSMC"], linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "ChargeCore", dependencies: ["SMCKit"], linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "ChargeGuardHelper", dependencies: ["SMCKit", "ChargeCore"]),
        .executableTarget(name: "ChargeGuardApp", dependencies: ["SMCKit", "ChargeCore"],
                          linkerSettings: [.linkedFramework("ServiceManagement")]),
        .executableTarget(name: "cgctl", dependencies: ["SMCKit", "ChargeCore"]),
        .testTarget(name: "ChargeCoreTests", dependencies: ["ChargeCore"]),
    ]
)
