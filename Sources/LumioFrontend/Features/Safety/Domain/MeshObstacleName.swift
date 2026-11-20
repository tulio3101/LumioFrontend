/// Clasificación de superficie, independiente de ARKit (para poder testear sin device).
/// El adaptador iOS mapea `ARMeshClassification` a estos casos.
enum MeshClass: Equatable {
    case none, wall, floor, ceiling, table, seat, window, door, other
}

/// Tipo de obstáculo detectado por profundidad (sin YOLO). Da el nombre que se anuncia y sirve de
/// clave para la persistencia/cooldown por tipo.
enum DepthObstacleKind: String, CaseIterable, Equatable {
    case generic, wall, door, seat, table

    /// Nombre corto en español para el anuncio ("pared al frente, a 1,0 metros").
    var spanishName: String {
        switch self {
        case .generic: return "obstáculo"
        case .wall:    return "pared"
        case .door:    return "puerta"
        case .seat:    return "asiento"
        case .table:   return "mesa"
        }
    }

    /// Mapea la clasificación de la malla LiDAR al tipo anunciable. Lo que no sabemos nombrar
    /// queda como "obstáculo" genérico (seguimos avisando la distancia).
    init(meshClass: MeshClass) {
        switch meshClass {
        case .wall:           self = .wall
        case .door, .window:  self = .door
        case .seat:           self = .seat
        case .table:          self = .table
        case .none, .floor, .ceiling, .other:
            self = .generic
        }
    }
}
