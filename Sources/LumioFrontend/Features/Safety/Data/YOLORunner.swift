#if os(iOS)
import Vision
import CoreML
import CoreVideo

enum YOLORunnerError: Error {
    case modelNotFound
}

/// Runs yolo26n_640_int8 via Vision/Core ML.
/// NMS is baked into the model pipeline — Vision returns VNRecognizedObjectObservation directly.
/// Vision handles resize to 640×640; no manual preprocessing needed.
final class YOLORunner {
    private let request: VNCoreMLRequest
    let confidenceThreshold: Float

    init(confidenceThreshold: Float = 0.45) throws {
        // The model lives in the app bundle (Copy Bundle Resources build phase in Xcode),
        // not in the SPM module bundle, since it's an app-level asset.
        guard let modelURL = Bundle.main.url(
            forResource: "yolo26n_640_int8",
            withExtension: "mlpackage"
        ) else { throw YOLORunnerError.modelNotFound }

        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try MLModel(contentsOf: modelURL, configuration: config)
        let vnModel = try VNCoreMLModel(for: model)
        let req = VNCoreMLRequest(model: vnModel)
        req.imageCropAndScaleOption = .scaleFit
        self.request = req
        self.confidenceThreshold = confidenceThreshold
    }

    /// Call from a background thread; never call on the main thread.
    func detect(pixelBuffer: CVPixelBuffer) throws -> [Detection] {
        // ARKit frames arrive rotated 90° CW on iPhone — use .right orientation.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        try handler.perform([request])
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
