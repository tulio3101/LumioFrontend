import Foundation

/// Localiza el modelo YOLO precompilado (`.mlmodelc`) en el bundle de la app, con el mismo
/// criterio que usa `YOLORunner` para cargarlo:
///  - SwiftPM/xtool: el `.mlmodelc` va como `.copy` del target → `Bundle.module`.
///  - Xcode/XcodeGen: el `.mlpackage` se compila a `.mlmodelc` → `Bundle.main`.
/// Es portable (sin `#if os(iOS)`) para que las pruebas puedan verificar que el modelo quedó
/// empaquetado en builds SwiftPM, que es justo lo que fallaba con xtool.
enum DetectionModelResource {
    static let resourceName = "yolo26n_640_int8"
    static let resourceExtension = "mlmodelc"

    /// URL del `.mlmodelc` empaquetado, o nil si no está en ningún bundle conocido.
    static var url: URL? {
        #if SWIFT_PACKAGE
        if let moduleURL = Bundle.module.url(forResource: resourceName, withExtension: resourceExtension) {
            return moduleURL
        }
        #endif
        return Bundle.main.url(forResource: resourceName, withExtension: resourceExtension)
    }

    /// True si el modelo está empaquetado y, por tanto, la detección puede cargarlo.
    static var isBundled: Bool { url != nil }
}
