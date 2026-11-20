// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AnyBrowser",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "AnyBrowser", targets: ["AnyBrowser"])],
    targets: [
        .target(name: "AnyBrowserCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "AnyBrowser", dependencies: ["AnyBrowserCore"]),
    ]
)
