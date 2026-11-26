import Foundation

/// SCRUM-40: huella compacta de una foto para saber si la escena cambió sin mandarla al
/// backend. El vector se normaliza (longitud 1): así la distancia entre dos huellas queda
/// entre 0 (iguales) y 2 (opuestas) sin importar la escala que use el generador.
struct SceneSignature: Equatable {
    let vector: [Float]

    /// nil si el vector está vacío o es todo ceros (no hay nada que comparar).
    init?(_ raw: [Float]) {
        let norm = raw.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard !raw.isEmpty, norm.isFinite, norm > 0 else { return nil }
        vector = raw.map { $0 / norm }
    }

    /// Distancia euclídea entre huellas normalizadas. nil si no son comparables (distinto
    /// tamaño: por ejemplo, otra revisión del generador).
    func distance(to other: SceneSignature) -> Float? {
        guard vector.count == other.vector.count else { return nil }
        var sum: Float = 0
        for (a, b) in zip(vector, other.vector) {
            let delta = a - b
            sum += delta * delta
        }
        return sum.squareRoot()
    }
}

/// Calcula la huella de una foto JPEG. En iOS usa `VNFeaturePrint` (ADR-308); en pruebas, un
/// doble. Todo ocurre en el teléfono: la foto no sale de la memoria.
protocol SceneSignatureProviding {
    func signature(for jpeg: Data) -> SceneSignature?
}

/// SCRUM-40: cuándo una escena merece una narración nueva. Los valores salen de ADR-308 (loop
/// lento de narración); el umbral de cambio hay que afinarlo con el iPhone.
struct AutoNarrationConfiguration: Equatable {
    /// Cada cuánto se mira si la escena cambió. Solo se toma la foto si ya pasó el mínimo
    /// entre narraciones, así que revisar no cuesta red.
    var pollInterval: TimeInterval = 5
    /// Mínimo entre dos narraciones (botón o automáticas): ADR-308.
    var minInterval: TimeInterval = 10
    /// Con el modo de bajo consumo activo el mínimo se multiplica por esto.
    var lowPowerMultiplier: Double = 2
    /// Distancia mínima entre la escena narrada y la actual para pedir otra descripción.
    var changeThreshold: Float = 0.35
    /// Tope de solicitudes automáticas por ruta: acota datos, batería y costo aunque la
    /// escena cambie siempre.
    var maxRequestsPerRoute = 90
    /// Espera tras una falla; se duplica con cada falla seguida hasta `maxBackoff`.
    var initialBackoff: TimeInterval = 30
    var maxBackoff: TimeInterval = 120

    func backoff(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let doublings = Double(min(failures - 1, 10))
        return min(initialBackoff * pow(2, doublings), maxBackoff)
    }
}
