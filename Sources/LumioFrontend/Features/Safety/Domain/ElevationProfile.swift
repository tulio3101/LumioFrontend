/// Perfil 1-D del suelo frente al usuario, muestreado a lo largo del corredor de marcha
/// (SCRUM-33, desniveles). Lo produce el adaptador iOS `ElevationProfileSampler` y lo clasifica el
/// núcleo puro `ElevationProfileAnalyzer`. Valor puro y testeable (sin ARKit).
struct ElevationSample: Equatable {
    /// Distancia horizontal adelante del usuario (m), creciente.
    let forwardMeters: Float
    /// Altura de la superficie respecto al plano de piso (m). Positiva = sube, negativa = baja.
    /// `nil` = **hueco**: el bin no tuvo muestras de profundidad confiables (NO "por debajo del
    /// piso": una bajada medida conserva su altura negativa).
    let heightAboveFloor: Float?
}

struct ElevationProfile: Equatable {
    /// Muestras ordenadas por `forwardMeters` ascendente (de cerca a lejos).
    let samples: [ElevationSample]

    init(samples: [ElevationSample]) { self.samples = samples }
}
