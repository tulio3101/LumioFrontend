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
        .target(
            name: "LumioFrontend",
            resources: [
                .process("Resources"),
                // Modelo YOLO precompilado (.mlmodelc) para builds SwiftPM/xtool, que no
                // ejecutan el paso de Core ML de Xcode. `.copy` lo empaqueta tal cual en
                // Bundle.module. Xcode usa el .mlpackage de Resources/ (ver project.yml).
                .copy("MLModels/yolo26n_640_int8.mlmodelc"),
            ]
        ),
        .testTarget(name: "LumioFrontendTests", dependencies: ["LumioFrontend"]),
        .testTarget(name: "SafetyTests", dependencies: ["LumioFrontend"]),
    ],
    swiftLanguageModes: [.v5]
)
