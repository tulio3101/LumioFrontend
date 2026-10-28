#if os(iOS)
import Vision
import CoreML
import CoreVideo
import OSLog

enum YOLORunnerError: Error {
    case modelNotFound
}

/// Runs yolo26n_640_int8 via Vision/Core ML.
/// NMS is baked into the model pipeline — Vision returns VNRecognizedObjectObservation directly.
/// Vision handles resize to 640×640; no manual preprocessing needed.
final class YOLORunner {
    private let request: VNCoreMLRequest
    let confidenceThreshold: Float

    private static let logger = Logger(subsystem: "com.lumio.app", category: "YOLORunner")
    #if DEBUG
    private static var hasLoggedObservationType = false
    #endif

    init(confidenceThreshold: Float = 0.45) throws {
        // Xcode compiles .mlpackage → .mlmodelc (Compile Sources build phase).
        // The compiled artifact is what ends up in the app bundle.
        let logger = Self.logger
        #if DEBUG
        // Log what the bundle actually contains so we can diagnose missing-model issues.
        let compiled = Bundle.main.url(forResource: "yolo26n_640_int8", withExtension: "mlmodelc")
        let raw      = Bundle.main.url(forResource: "yolo26n_640_int8", withExtension: "mlpackage")
        logger.debug("Bundle .mlmodelc → \(compiled?.path ?? "nil")")
        logger.debug("Bundle .mlpackage → \(raw?.path ?? "nil")")
        if compiled == nil, raw == nil {
            logger.warning("Ni .mlmodelc ni .mlpackage encontrados — ¿está en Compile Sources y el proyecto regenerado?")
        }
        #endif

        guard let modelURL = Bundle.main.url(
            forResource: "yolo26n_640_int8",
            withExtension: "mlmodelc"
        ) else {
            logger.error("modelNotFound — .mlmodelc ausente del bundle")
            throw YOLORunnerError.modelNotFound
        }

        logger.info("Cargando modelo desde \(modelURL.lastPathComponent)")
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try MLModel(contentsOf: modelURL, configuration: config)
        let vnModel = try VNCoreMLModel(for: model)
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
        try handler.perform([request])

        #if DEBUG
        // Log result type once — if VNCoreMLFeatureValueObservation appears, Vision could not
        // decode the model output as bounding boxes; manual MLMultiArray [1,300,6] decoding needed.
        if !Self.hasLoggedObservationType, let first = request.results?.first {
            Self.hasLoggedObservationType = true
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
            return []
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
