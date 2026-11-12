import CoreGraphics

/// Sliding-window temporal filter: a detection is stable only when the same class
/// appears in ≥ minAppearances of the last windowSize frames, with IoU ≥ minIoU
/// between bounding boxes — confirming the same physical object, not a single-frame glitch.
///
/// Usage: create once per pipeline Task (local `var smoother = TemporalSmoother()`).
/// Resets automatically when the Task is recreated on pipeline restart.
struct TemporalSmoother {
    let windowSize: Int      // default 5
    let minAppearances: Int  // default 3
    let minIoU: Float        // default 0.3

    private var window: [[Detection]] = []

    init(windowSize: Int = 5, minAppearances: Int = 3, minIoU: Float = 0.3) {
        self.windowSize = windowSize
        self.minAppearances = minAppearances
        self.minIoU = minIoU
    }

    /// Adds `current` to the sliding window and returns only stable detections.
    /// Returns empty until the window accumulates ≥ minAppearances frames.
    mutating func filter(_ current: [Detection]) -> [Detection] {
        window.append(current)
        if window.count > windowSize { window.removeFirst() }
        guard window.count >= minAppearances else { return [] }

        return current.filter { det in
            // Count frames containing a detection of the same class
            // whose box overlaps the current box enough to be the same object.
            // The current frame always contributes 1 (IoU with itself = 1.0).
            let appearances = window.filter { frame in
                frame.contains { other in
                    other.obstacleClass == det.obstacleClass &&
                    iou(det.boundingBox, other.boundingBox) >= minIoU
                }
            }.count
            return appearances >= minAppearances
        }
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let iArea = Float(inter.width * inter.height)
        let uArea = Float(a.width * a.height) + Float(b.width * b.height) - iArea
        return uArea > 0 ? iArea / uArea : 0
    }
}
