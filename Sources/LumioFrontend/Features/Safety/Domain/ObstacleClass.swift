import Foundation

/// Subconjunto de clases COCO relevantes para la movilidad de peatones.
/// Solo estas clases se propagan como detecciones; el resto se descarta en el decoder.
enum ObstacleClass: String, CaseIterable, Equatable {
    case person        = "person"
    case bicycle       = "bicycle"
    case car           = "car"
    case motorcycle    = "motorcycle"
    case bus           = "bus"
    case truck         = "truck"
    case trafficLight  = "traffic light"
    case fireHydrant   = "fire hydrant"
    case stopSign      = "stop sign"
    case parkingMeter  = "parking meter"
    case bench         = "bench"
    case chair         = "chair"
    case dog           = "dog"
    case pottedPlant   = "potted plant"

    /// Mapea la etiqueta COCO literal devuelta por Vision/Core ML al enum de movilidad.
    /// Devuelve nil si la clase no pertenece al subconjunto de movilidad.
    static func from(cocoLabel: String) -> ObstacleClass? {
        ObstacleClass(rawValue: cocoLabel)
    }
}
