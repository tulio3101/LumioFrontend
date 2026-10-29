import Foundation

/// Subconjunto de clases COCO relevantes para la movilidad de peatones.
/// Solo estas clases se propagan como detecciones; el resto se descarta en el decoder.
enum ObstacleClass: String, CaseIterable, Equatable {
    // Personas y vehículos
    case person        = "person"
    case bicycle       = "bicycle"
    case car           = "car"
    case motorcycle    = "motorcycle"
    case bus           = "bus"
    case truck         = "truck"
    // Señalética vial
    case trafficLight  = "traffic light"
    case fireHydrant   = "fire hydrant"
    case stopSign      = "stop sign"
    case parkingMeter  = "parking meter"
    // Mobiliario exterior
    case bench         = "bench"
    // Animales
    case dog           = "dog"
    // Objetos de interior relevantes para navegación en espacios cerrados
    case chair         = "chair"
    case pottedPlant   = "potted plant"
    case diningTable   = "dining table"
    case bed           = "bed"
    case couch         = "couch"
    case toilet        = "toilet"
    case refrigerator  = "refrigerator"
    case tv            = "tv"
    case laptop        = "laptop"
    case suitcase      = "suitcase"
    case backpack      = "backpack"
    case umbrella      = "umbrella"

    /// Mapea la etiqueta COCO literal devuelta por Vision/Core ML al enum de movilidad.
    /// Devuelve nil si la clase no pertenece al subconjunto de movilidad.
    static func from(cocoLabel: String) -> ObstacleClass? {
        ObstacleClass(rawValue: cocoLabel)
    }
}
