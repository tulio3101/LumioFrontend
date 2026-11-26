#if os(iOS)
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// SCRUM-261 / ADR-308 §2: convierte el `capturedImage` de ARKit en el JPEG que se envía.
///
/// - 768 px de lado largo y orientación vertical (el sensor entrega la imagen girada).
/// - Calidad 0,7.
/// - Se codifica desde un `CGImage` sin propiedades: no lleva EXIF, GPS ni otros metadatos.
/// - Todo en memoria: nunca se escribe en el carrete, en caché ni en disco.
struct NarrationFrameEncoder {
    static let longSide: CGFloat = 768
    static let quality: CGFloat = 0.7

    private let context = CIContext(options: [.cacheIntermediates: false])

    /// Reduce y orienta la imagen en un `CGImage` propio: después el `ARFrame` ya no se
    /// necesita y ARKit lo puede liberar.
    func downscaledImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        // Teléfono en vertical: la imagen del sensor está girada 90° a la izquierda.
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let extent = image.extent
        let longest = max(extent.width, extent.height)
        guard longest > 0 else { return nil }
        let scale = min(1, Self.longSide / longest)
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let target = CGRect(
            x: 0, y: 0,
            width: (extent.width * scale).rounded(.down),
            height: (extent.height * scale).rounded(.down)
        )
        return context.createCGImage(scaled, from: target)
    }

    static func jpeg(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        // Solo la calidad: sin diccionarios EXIF, GPS ni TIFF.
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif
