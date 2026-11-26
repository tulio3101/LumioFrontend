import Foundation

/// Subconjunto de clases COCO relevantes para la movilidad de peatones EN EXTERIORES.
/// Solo estas clases se propagan como detecciones; el resto se descarta en el decoder.
/// Las clases de interior puro (toilet, refrigerator, tv, laptop, bed, couch, dining table) se
/// excluyeron: no aparecen en la banqueta y eran fuente de falsos positivos.
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
    // Mobiliario de exterior
    case bench         = "bench"
    case chair         = "chair"
    case pottedPlant   = "potted plant"
    // Mesas: terrazas de café y, con malla LiDAR, se fusiona con la clase .table (FASE 1).
    case diningTable   = "dining table"
    // Animales
    case dog           = "dog"
    // Objetos portátiles que aparecen en la vía
    case suitcase      = "suitcase"
    case backpack      = "backpack"
    case umbrella      = "umbrella"

    /// Mapea la etiqueta COCO literal devuelta por Vision/Core ML al enum de movilidad.
    /// Devuelve nil si la clase no pertenece al subconjunto de movilidad.
    static func from(cocoLabel: String) -> ObstacleClass? {
        ObstacleClass(rawValue: cocoLabel)
    }
}
