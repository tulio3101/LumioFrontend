import CoreGraphics

/// Rastreador de obstáculos por objeto: asigna IDs estables entre frames (emparejando por clase
/// e IoU), filtra al corredor de marcha, exige persistencia (N de M) y marca si el objeto se
/// acerca. Así las alertas son por objeto rastreado y no por frame (SCRUM-33).
///
/// Uso: crear una instancia por Task del pipeline (`var tracker = ObstacleTracker(config:)`).
/// Se reinicia solo cuando el Task se recrea al reiniciar el pipeline, igual que `TemporalSmoother`.
struct ObstacleTracker {
    private struct Track {
        let id: Int
        var lastDetection: Detection
        var lastDistance: Float?
        var isApproaching: Bool
        /// Vistos en los últimos `windowFrames` frames (true = visto ese frame).
        var window: [Bool]
        /// Frames consecutivos sin ver el objeto.
        var missed: Int
    }

    let config: DetectionFocusConfig
    private let corridor: WalkingCorridor
    private var tracks: [Track] = []
    private var nextID = 1

    init(config: DetectionFocusConfig = DetectionFocusConfig()) {
        self.config = config
        self.corridor = WalkingCorridor(config: config)
    }

    /// Procesa las detecciones de un frame y devuelve los objetos del corredor que, además de
    /// verse este frame, ya cumplieron la persistencia. `pitchDegrees` ajusta el corredor.
    mutating func update(_ detections: [Detection], pitchDegrees: Float? = nil) -> [TrackedDetection] {
        let pitch = pitchDegrees ?? 0

        // 1. Objetos dentro del corredor de marcha. Además se conservan los objetos grandes (caja
        //    alta = cerca/parcialmente visible) aunque queden en el borde: no deben descartarse.
        let keepLargeBox = config.corridorKeepLargeBoxHeightFraction
        let inCorridor = detections.filter {
            corridor.contains($0.boundingBox, pitchDegrees: pitch)
                || $0.boundingBox.height >= keepLargeBox
        }

        // 2. Avanzar la ventana: por defecto nadie se vio este frame.
        for i in tracks.indices {
            tracks[i].window.append(false)
            if tracks[i].window.count > config.windowFrames { tracks[i].window.removeFirst() }
        }

        // 3. Emparejar cada detección con el mejor track libre de su misma clase.
        var matched = Set<Int>()
        for det in inCorridor {
            var bestIdx: Int?
            var bestIoU = config.iouMatchThreshold
            for (i, t) in tracks.enumerated()
            where !matched.contains(i) && t.lastDetection.obstacleClass == det.obstacleClass {
                let overlap = iou(t.lastDetection.boundingBox, det.boundingBox)
                if overlap >= bestIoU { bestIoU = overlap; bestIdx = i }
            }
            if let idx = bestIdx {
                matched.insert(idx)
                updateTrack(&tracks[idx], with: det)
            } else {
                tracks.append(Track(
                    id: nextID, lastDetection: det, lastDistance: det.distanceMeters,
                    isApproaching: false, window: [true], missed: 0
                ))
                matched.insert(tracks.count - 1)
                nextID += 1
            }
        }

        // 4. Contar frames perdidos y olvidar los que superan el umbral.
        for i in tracks.indices where !matched.contains(i) {
            tracks[i].missed += 1
        }
        tracks.removeAll { $0.missed > config.maxMissedFrames }

        // 5. Salida: vistos este frame y con persistencia suficiente (N de M).
        return tracks.compactMap { t in
            guard t.window.last == true else { return nil }
            guard t.window.lazy.filter({ $0 }).count >= config.minAppearances else { return nil }
            return TrackedDetection(id: t.id, detection: t.lastDetection, isApproaching: t.isApproaching)
        }
    }

    private func updateTrack(_ t: inout Track, with det: Detection) {
        // Acercamiento: la distancia bajó al menos `approachingDeltaMeters` entre lecturas.
        if let new = det.distanceMeters, let old = t.lastDistance {
            if old - new >= config.approachingDeltaMeters { t.isApproaching = true }
            else if new - old >= config.approachingDeltaMeters { t.isApproaching = false }
            // Cambios menores: conserva el estado anterior (evita parpadeo).
        }
        if let new = det.distanceMeters { t.lastDistance = new }
        t.lastDetection = det
        t.window[t.window.count - 1] = true
        t.missed = 0
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let iArea = Float(inter.width * inter.height)
        let uArea = Float(a.width * a.height) + Float(b.width * b.height) - iArea
        return uArea > 0 ? iArea / uArea : 0
    }
}
