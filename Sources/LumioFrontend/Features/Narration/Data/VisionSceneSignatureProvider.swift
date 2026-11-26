#if canImport(Vision)
import Foundation
import Vision

/// SCRUM-40 / ADR-308: huella de la foto con `VNFeaturePrint`, en el teléfono y sin red. La
/// foto ya viene reducida (768 px), así que calcularla es barato. Solo compila donde existe
/// Vision: se valida en el iPhone.
struct VisionSceneSignatureProvider: SceneSignatureProviding {
    func signature(for jpeg: Data) -> SceneSignature? {
        let request = VNGenerateImageFeaturePrintRequest()
        // Toda la foto cuenta: recortar el centro ignoraría lo que aparece a los lados.
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(data: jpeg, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNFeaturePrintObservation,
              observation.elementType == .float, observation.elementCount > 0 else { return nil }
        let values = observation.data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self).prefix(observation.elementCount))
        }
        return SceneSignature(values)
    }
}
#endif
