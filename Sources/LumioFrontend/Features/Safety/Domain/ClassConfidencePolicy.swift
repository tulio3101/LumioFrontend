/// Per-class confidence thresholds for YOLO detections.
/// Adjust here when the model confuses specific classes — single source of truth.
/// Higher threshold → fewer false positives, may miss distant/partial objects.
struct ClassConfidencePolicy {
    static let `default` = ClassConfidencePolicy()

    private let overrides: [ObstacleClass: Float] = [
        // Person is the most over-detected class; raise threshold to cut false positives.
        .person:      0.55,
        // Vehicles are distinctive shapes and safety-critical — moderate threshold.
        .bicycle:     0.50,
        .car:         0.50,
        .motorcycle:  0.50,
        .bus:         0.50,
        .truck:       0.50,
        // Benches have a clear silhouette on the street.
        .bench:       0.50,
        // Dogs matter for mobility and are often partially visible near the edge: lower threshold.
        .dog:         0.35,
        // Tables (café terraces): clear silhouette, also confirmed by the LiDAR mesh (.table).
        .diningTable: 0.45,
        // Small / easily-confused objects (chair, plant, bags, umbrella): raise threshold to
        // cut false positives seen in street tests.
        .chair:       0.55,
        .pottedPlant: 0.55,
        .backpack:    0.55,
        .suitcase:    0.55,
        .umbrella:    0.55,
    ]

    /// Applied to any class not listed above.
    let fallback: Float = 0.50

    func threshold(for cls: ObstacleClass) -> Float {
        overrides[cls] ?? fallback
    }
}
