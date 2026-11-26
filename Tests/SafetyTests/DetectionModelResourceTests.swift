import Testing
import Foundation
@testable import LumioFrontend

// MARK: - fix/modelo-xtool: el modelo YOLO debe empaquetarse también con SwiftPM/xtool

/// Antes de este fix el `.mlmodelc` no viajaba en el bundle de SwiftPM (Package.swift apuntaba
/// `.process("Resources")` a una carpeta sin el modelo), así que xtool construía la app sin
/// modelo y la detección quedaba "no disponible". Esta prueba corre en el build portable
/// (`swift test`, el mismo que xtool) y falla si el `.mlmodelc` no está en `Bundle.module`.
@Test func modelIsBundledForSwiftPM() {
    #if SWIFT_PACKAGE
    let url = Bundle.module.url(
        forResource: DetectionModelResource.resourceName,
        withExtension: DetectionModelResource.resourceExtension
    )
    #expect(url != nil, "yolo26n_640_int8.mlmodelc no está en Bundle.module: xtool no lo empaquetaría.")
    // Un .mlmodelc es un directorio compilado: debe contener coremldata.bin.
    if let url {
        let coreMLData = url.appendingPathComponent("coremldata.bin")
        #expect(FileManager.default.fileExists(atPath: coreMLData.path))
    }
    #endif
}

/// El resolutor compartido encuentra el modelo en el bundle en el que lo pone cada toolchain.
@Test func detectionModelResourceResolvesTheBundledModel() {
    #if SWIFT_PACKAGE
    #expect(DetectionModelResource.isBundled)
    #expect(DetectionModelResource.url != nil)
    #endif
}
