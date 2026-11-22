// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AnyBrowser",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "AnyBrowser", targets: ["AnyBrowser"]),
        .executable(name: "AnyBrowserRelay", targets: ["AnyBrowserRelay"]),
        .executable(name: "anybrowserctl", targets: ["anybrowserctl"]),
    ],
    targets: [
        .target(name: "AnyBrowserCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "AnyBrowser", dependencies: ["AnyBrowserCore"]),
        // Forwards one Profile's browser traffic to its upstream proxy and answers proxy sign-in.
        .executableTarget(name: "AnyBrowserRelay", dependencies: ["AnyBrowserCore"]),
        // Command-line client for the local automation API.
        .executableTarget(name: "anybrowserctl", dependencies: ["AnyBrowserCore"]),
        .testTarget(name: "AnyBrowserCoreTests", dependencies: ["AnyBrowserCore"]),
    ]
)
