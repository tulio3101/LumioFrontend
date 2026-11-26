/// Nivel térmico abstracto (espejo de `ProcessInfo.ThermalState`), para que la política sea un
/// núcleo PURO y testeable sin plataforma (SCRUM-321).
enum ThermalLevel: Equatable {
    case nominal
    case fair
    case serious
    case critical
}

/// Carga de detección resultante de la política térmica: fps objetivo de la inferencia, si la
/// detección está en pausa (térmica crítica) y a cuántos Hz debe reconstruirse la malla LiDAR.
struct DetectionLoad: Equatable {
    /// Cuadros/segundo a procesar con YOLO. Ignorado si `isPaused`.
    let targetFPS: Int
    /// true en estado crítico: se pausa la inferencia (se avisa una vez) hasta que enfríe.
    let isPaused: Bool
    /// Frecuencia de la reconstrucción de malla (0 = malla apagada).
    let meshHz: Double
}

/// Política de rendimiento térmico (SCRUM-321). Mapea estado térmico + Modo de Bajo Consumo a una
/// `DetectionLoad`. Núcleo puro (sin ARKit/UIKit): el adaptador iOS lee `ProcessInfo` y traduce.
///
/// Regla base: nominal 15 fps, fair 10, serious 5, critical en pausa. El Modo de Bajo Consumo
/// baja un escalón (nominal→fair, fair→serious) para gastar menos. La malla va a 2-3 Hz y se apaga
/// en serious/critical o con Bajo Consumo.
struct ThermalPolicy {
    var nominalFPS: Int = 15
    var fairFPS: Int = 10
    var seriousFPS: Int = 5
    /// Malla LiDAR a 2-3 Hz cuando está encendida.
    var meshHz: Double = 2.5

    func load(for level: ThermalLevel, lowPowerMode: Bool) -> DetectionLoad {
        switch level {
        case .nominal:
            // Bajo Consumo gasta como "fair": 10 fps y sin malla.
            return lowPowerMode
                ? DetectionLoad(targetFPS: fairFPS, isPaused: false, meshHz: 0)
                : DetectionLoad(targetFPS: nominalFPS, isPaused: false, meshHz: meshHz)
        case .fair:
            // Bajo Consumo baja a "serious": 5 fps y sin malla.
            return lowPowerMode
                ? DetectionLoad(targetFPS: seriousFPS, isPaused: false, meshHz: 0)
                : DetectionLoad(targetFPS: fairFPS, isPaused: false, meshHz: meshHz)
        case .serious:
            // Ya exigido: 5 fps y malla apagada (con o sin Bajo Consumo).
            return DetectionLoad(targetFPS: seriousFPS, isPaused: false, meshHz: 0)
        case .critical:
            // Pausa la inferencia hasta enfriar; se reanuda al bajar de crítico.
            return DetectionLoad(targetFPS: seriousFPS, isPaused: true, meshHz: 0)
        }
    }
}
