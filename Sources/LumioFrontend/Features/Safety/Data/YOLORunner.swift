#if os(iOS)
import Vision
import CoreML
import CoreVideo
import OSLog

typealias YOLORunnerError = DetectionModelError

protocol ObstacleDetecting: AnyObject {
    func detect(pixelBuffer: CVPixelBuffer) throws -> [Detection]
}

#if DEBUG
/// Solo para el log de diagnóstico de abajo: el bundle de recursos del módulo según el
/// toolchain (`Bundle.module` con SwiftPM/xtool, `Bundle.main` con Xcode). La resolución real
/// del modelo la hace `DetectionModelResource`.
#if SWIFT_PACKAGE
private let modelResourceBundle = Bundle.module
#else
private let modelResourceBundle = Bundle.main
#endif
#endif

/// Runs yolo26n_640_int8 via Vision/Core ML.
/// NMS is baked into the model pipeline — Vision returns VNRecognizedObjectObservation directly.
/// Vision handles resize to 640×640; no manual preprocessing needed.
final class YOLORunner: ObstacleDetecting {
    private let request: VNCoreMLRequest
    let confidenceThreshold: Float

    private static let logger = Logger(subsystem: "com.lumio.app", category: "YOLORunner")
    #if DEBUG
    private var hasLoggedObservationType = false
    #endif

    init(confidenceThreshold: Float = 0.45) throws {
        // El `.mlmodelc` puede venir de dos sitios según el toolchain:
        //  - SwiftPM/xtool: `.copy` del `.mlmodelc` precompilado → Bundle.module.
        //  - Xcode/XcodeGen: compila el `.mlpackage` (Compile Sources) → Bundle.main.
        // Se busca primero en el bundle de recursos del módulo y luego en Bundle.main.
        let logger = Self.logger
        #if DEBUG
        let moduleURL = modelResourceBundle.url(forResource: "yolo26n_640_int8", withExtension: "mlmodelc")
        let mainURL = Bundle.main.url(forResource: "yolo26n_640_int8", withExtension: "mlmodelc")
        let rawPackage = Bundle.main.url(forResource: "yolo26n_640_int8", withExtension: "mlpackage")
        logger.debug("modelResourceBundle(.mlmodelc) → \(moduleURL?.path ?? "nil")")
        logger.debug("Bundle.main(.mlmodelc) → \(mainURL?.path ?? "nil")")
        logger.debug("Bundle.main(.mlpackage) → \(rawPackage?.path ?? "nil")")
        #endif

        guard let modelURL = DetectionModelResource.url else {
            // Causa real nº1: el archivo no está en el bundle (recurso no empaquetado).
            let reason = "modelNotFound — 'yolo26n_640_int8.mlmodelc' ausente en Bundle.module y Bundle.main. "
                + "SwiftPM/xtool: ¿está en MLModels/ y declarado como .copy en Package.swift? "
                + "Xcode: ¿el .mlpackage está en Compile Sources y se regeneró el proyecto?"
            logger.error("\(reason)")
            throw YOLORunnerError.modelNotFound
        }

        logger.info("Cargando modelo desde \(modelURL.path)")
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let vnModel: VNCoreMLModel
        do {
            let model = try MLModel(contentsOf: modelURL, configuration: config)
            vnModel = try VNCoreMLModel(for: model)
        } catch {
            // Causa real nº2: el archivo existe pero Core ML no lo cargó. Se registra el error
            // tal cual (dominio/código/descripción) para distinguir un fallo de Core ML de un
            // problema de hardware/cómputo del dispositivo. (La incompatibilidad de ARKit se
            // detecta aparte en ARKitFrameSource con ARWorldTrackingConfiguration.isSupported.)
            let nsError = error as NSError
            logger.error("modelLoadingFailed — Core ML no cargó el modelo: domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)")
            throw DetectionModelError.modelLoadingFailed
        }
        let req = VNCoreMLRequest(model: vnModel)
        req.imageCropAndScaleOption = .scaleFit
        self.request = req
        self.confidenceThreshold = confidenceThreshold
        logger.info("YOLORunner listo (umbral=\(confidenceThreshold))")
    }

    /// Call from a background thread; never call on the main thread.
    func detect(pixelBuffer: CVPixelBuffer) throws -> [Detection] {
        // ARKit frames arrive rotated 90° CW on iPhone — use .right orientation.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        do {
            try handler.perform([request])
        } catch {
            Self.logger.error("Inferencia fallida: \(error)")
            throw DetectionModelError.inferenceFailed
        }

        #if DEBUG
        // Log result type once — if VNCoreMLFeatureValueObservation appears, Vision could not
        // decode the model output as bounding boxes; manual MLMultiArray [1,300,6] decoding needed.
        if !hasLoggedObservationType, let first = request.results?.first {
            hasLoggedObservationType = true
            if first is VNCoreMLFeatureValueObservation {
                Self.logger.error("resultado: VNCoreMLFeatureValueObservation — Vision no decodificó el modelo como detector; se necesita fallback MLMultiArray (ver lumio-spikes/DepthProto/YOLORunner.swift)")
            } else if first is VNRecognizedObjectObservation {
                Self.logger.info("resultado: VNRecognizedObjectObservation ✓")
            } else {
                Self.logger.warning("resultado: tipo desconocido \(type(of: first))")
            }
        }
        #endif

        guard let observations = request.results as? [VNRecognizedObjectObservation] else {
            throw DetectionModelError.invalidOutput
        }
        return observations.compactMap { obs in
            guard obs.confidence >= confidenceThreshold,
                  let top = obs.labels.first,
                  let cls = ObstacleClass.from(cocoLabel: top.identifier) else { return nil }
            return Detection(
                obstacleClass: cls,
                confidence: top.confidence,
                boundingBox: visionToTopLeft(obs.boundingBox)
            )
        }
    }
}

#endif
