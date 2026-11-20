import Foundation

/// Compuerta de persistencia + cooldown por clave (tipo de obstáculo/desnivel). Igual que el
/// tracker de YOLO: una clave solo "pasa" si apareció en N de los últimos M frames, y luego no
/// se repite hasta que vence el cooldown. Así un frame ruidoso aislado nunca alerta.
/// Valor puro y reutilizable por el detector de profundidad (Parte 2) y los desniveles (Parte 3).
struct PersistenceGate {
    let minAppearances: Int
    let windowFrames: Int
    let cooldown: TimeInterval

    private var windows: [String: [Bool]] = [:]
    private var lastAnnounced: [String: Date] = [:]

    init(minAppearances: Int = 3, windowFrames: Int = 5, cooldown: TimeInterval = 4.0) {
        self.minAppearances = minAppearances
        self.windowFrames = windowFrames
        self.cooldown = cooldown
    }

    /// Procesa un frame: `present` son las claves vistas este frame. Devuelve las claves que deben
    /// anunciarse (cumplen persistencia y no están en cooldown).
    mutating func update(present: Set<String>, now: Date) -> Set<String> {
        // Avanzar todas las ventanas conocidas (y las nuevas de este frame).
        let keys = Set(windows.keys).union(present)
        var announce: Set<String> = []
        for key in keys {
            var window = windows[key] ?? []
            window.append(present.contains(key))
            if window.count > windowFrames { window.removeFirst() }
            windows[key] = window

            let appearances = window.lazy.filter { $0 }.count
            guard appearances >= minAppearances else {
                // Si lleva toda la ventana sin verse, olvidar su estado.
                if !window.contains(true) {
                    windows.removeValue(forKey: key)
                    lastAnnounced.removeValue(forKey: key)
                }
                continue
            }
            let due = lastAnnounced[key].map { now.timeIntervalSince($0) >= cooldown } ?? true
            if due {
                announce.insert(key)
                lastAnnounced[key] = now
            }
        }
        return announce
    }
}
