import Foundation

/// Con qué sensor se estimó la distancia (SCRUM-320 / ADR-307).
enum DepthMode: Equatable {
    /// iPhone con LiDAR: metros exactos hasta ~3 m, útil hasta ~4 m.
    case lidar
    /// iPhone sin LiDAR (cámara dual): aproximado y de corto alcance. Nunca se dicen metros.
    case reduced
}

/// SCRUM-34: nivel de proximidad de un obstáculo.
enum ProximityLevel: Equatable {
    /// Zona de riesgo: alerta de seguridad P1 que interrumpe cualquier audio.
    case urgent
    /// Cerca, pero sin urgencia por distancia: información P3.
    case near
    /// Detectado más allá del rango confiable del LiDAR: solo se informa que está lejos.
    case far
    /// Sin distancia confiable (sin profundidad, sin muestras o fuera del alcance del modo
    /// reducido): no se promete ningún aviso de distancia.
    case unknown
}

struct ProximityReading: Equatable {
    let level: ProximityLevel
    /// Si el aviso puede decir los metros. Con LiDAR solo hasta `lidarMetersLimit`; en modo
    /// reducido nunca (ADR-307).
    let speaksMeters: Bool
}

/// SCRUM-34: tabla de umbrales del spike SCRUM-309 (reglas de audio, umbral urgente) con los
/// rangos de confianza de ADR-307. Valor puro, sin ARKit: se prueba sin dispositivo.
///
/// | Modo | Distancia | Resultado |
/// |---|---|---|
/// | LiDAR | ≤ 2,5 m (≤ 3,0 m si se acerca de frente) | Urgente: P1 |
/// | LiDAR | hasta 3 m | Cerca, con metros: P3 |
/// | LiDAR | 3–4 m | Cerca, sin metros: P3 |
/// | LiDAR | > 4 m | Lejos: sin alerta de distancia |
/// | Sin LiDAR | < 1,5 m | «Muy cerca»: P1 |
/// | Sin LiDAR | 1,5–2,5 m | «Cerca»: P3 |
/// | Sin LiDAR | > 2,5 m | Sin aviso de distancia |
///
/// El riesgo para la trayectoria no lo decide esta política: el pipeline solo entrega los
/// objetos que están en el corredor de marcha (`WalkingCorridor`).
struct ProximityPolicy: Equatable {
    /// Obstáculo estático: margen cómodo para frenar o esquivar (pruebas de campo del spike).
    var urgentStaticMeters: Float = 2.5
    /// Persona u objeto que se acerca de frente: mayor velocidad relativa, más margen.
    var urgentApproachingMeters: Float = 3.0
    /// Con LiDAR los metros solo se dicen hasta aquí (ADR-307).
    var lidarMetersLimit: Float = 3.0
    /// Más allá de aquí el LiDAR pierde fiabilidad y no hay alerta de distancia.
    var lidarRangeMeters: Float = 4.0
    /// Modo reducido: «muy cerca» (urgente) por debajo de esto, siempre dentro de 1,5 m (ADR-307).
    var reducedUrgentMeters: Float = 1.5
    /// Modo reducido: «cerca» hasta aquí; más allá no se promete aviso.
    var reducedRangeMeters: Float = 2.5

    func reading(distance: Float?, isApproaching: Bool, mode: DepthMode) -> ProximityReading {
        guard let distance, distance.isFinite, distance >= 0 else {
            return ProximityReading(level: .unknown, speaksMeters: false)
        }
        switch mode {
        case .lidar:
            let urgent = isApproaching ? urgentApproachingMeters : urgentStaticMeters
            if distance <= urgent {
                return ProximityReading(level: .urgent, speaksMeters: true)
            }
            if distance <= lidarRangeMeters {
                return ProximityReading(level: .near, speaksMeters: distance <= lidarMetersLimit)
            }
            return ProximityReading(level: .far, speaksMeters: false)
        case .reduced:
            if distance < reducedUrgentMeters {
                return ProximityReading(level: .urgent, speaksMeters: false)
            }
            if distance <= reducedRangeMeters {
                return ProximityReading(level: .near, speaksMeters: false)
            }
            return ProximityReading(level: .unknown, speaksMeters: false)
        }
    }
}
