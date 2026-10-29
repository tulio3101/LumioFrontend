// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LumioFrontend",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "LumioFrontend",
            targets: ["LumioFrontend"]
        ),
    ],
    targets: [
        .target(name: "LumioFrontend"),
        .testTarget(name: "LumioFrontendTests", dependencies: ["LumioFrontend"]),
    ],
    swiftLanguageModes: [.v5]
)
