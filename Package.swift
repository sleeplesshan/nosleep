// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sleeplesshan",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Sleeplesshan", targets: ["NoSleep"]), .library(name: "NoSleepCore", targets: ["NoSleepCore"])],
    targets: [
        .target(name: "NoSleepCore"),
        .executableTarget(name: "NoSleep", dependencies: ["NoSleepCore"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("IOKit"), .linkedFramework("ServiceManagement"), .linkedFramework("ApplicationServices")]),
        .testTarget(name: "NoSleepCoreTests", dependencies: ["NoSleepCore"]),
        .testTarget(name: "MacAdapterTests", dependencies: ["NoSleep"])
    ]
)
