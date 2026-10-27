import CoreGraphics

/// Converts a Vision bounding box (bottom-left origin) to top-left origin.
/// Vision and ARKit return rects with y=0 at the bottom; Detection.boundingBox uses y=0 at top.
func visionToTopLeft(_ rect: CGRect) -> CGRect {
    CGRect(x: rect.minX, y: 1.0 - rect.maxY, width: rect.width, height: rect.height)
}
