// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LumioFrontend",
    platforms: [.iOS(.v16), .macOS(.v13)],
    targets: [
        .executableTarget(name: "LumioFrontend"),
        .testTarget(name: "LumioFrontendTests", dependencies: ["LumioFrontend"]),
    ],
    swiftLanguageModes: [.v5]
)
