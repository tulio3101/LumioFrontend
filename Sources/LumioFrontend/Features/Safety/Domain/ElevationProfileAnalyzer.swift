/// Peligro de desnivel clasificado desde el perfil del suelo (SCRUM-33). `distance` = metros
/// adelante donde empieza el peligro.
enum ElevationHazard: Equatable {
    case flat
    case rampUp(distance: Float)
    case rampDown(distance: Float)
    case stepUp(distance: Float)
    case stairsUp(distance: Float)
    /// Una sola caída medida, un hueco persistente, o un bordillo.
    case stepDownOrCurb(distance: Float)
    /// Varias caídas medidas seguidas (escalera hacia abajo).
    case stairsDown(distance: Float)
}

/// Clasifica el perfil de altura del corredor en escalón/escalera/bordillo/rampa. Valor puro y
/// testeable (sin ARKit). Reglas (SCRUM-33, con las correcciones de prueba en campo):
/// - La **bajada es lo más crítico** y se evalúa primero. El "piso válido antes" puede venir del
///   plano bajo los pies (`hasKnownFloor`), aunque no se vean muestras de piso en la imagen: así se
///   detecta una escalera de bajada que arranca justo en el borde.
/// - Caídas MEDIDAS: repetidas → `stairsDown`; una sola → `stepDownOrCurb`. Hueco persistente con
///   piso conocido → `stepDownOrCurb` conservador.
/// - Una **subida** solo es escalón si va seguida de una **huella plana** de al menos `minTread`
///   a la nueva altura (si no, es un zócalo/pared → `flat`). Una subida mayor que `stepMax` es
///   pared (la maneja `DepthObstacleDetector`).
/// - Pendiente suave y sostenida → `rampUp`/`rampDown`. Prioridad: bajada > subida > rampa > plano.
struct ElevationProfileAnalyzer {
    func analyze(
        _ profile: ElevationProfile,
        config: DetectionFocusConfig,
        hasKnownFloor: Bool = false
    ) -> ElevationHazard {
        let samples = profile.samples
        guard !samples.isEmpty else { return .flat }
        let stepMin = config.stepMinMeters
        let stepMax = config.stepMaxMeters

        // Piso válido inicial: muestras consecutivas cerca de cero, o el plano bajo los pies.
        var floorBefore = 0
        for s in samples {
            guard let h = s.heightAboveFloor, abs(h) < stepMin else { break }
            floorBefore += 1
        }
        let floorKnown = hasKnownFloor || floorBefore >= config.minFloorSamplesBeforeDrop

        // Saltos abruptos entre muestras MEDIDAS adyacentes. Con piso conocido, la primera muestra
        // se compara contra el piso (altura 0): una escalera que arranca bajando ya cuenta.
        var drops: [Float] = []
        var prev: Float? = hasKnownFloor ? 0 : nil
        for s in samples {
            guard let h = s.heightAboveFloor else { prev = nil; continue }
            if let p = prev, h - p <= -stepMin { drops.append(s.forwardMeters) }
            prev = h
        }

        // 1. BAJADA (prioridad máxima), solo con piso conocido/válido.
        if floorKnown {
            if drops.count >= 2 { return .stairsDown(distance: drops[0]) }
            if drops.count == 1 { return .stepDownOrCurb(distance: drops[0]) }
            if let holeDist = firstPersistentHole(samples, after: floorBefore, minRun: config.minHoleRun) {
                return .stepDownOrCurb(distance: holeDist)
            }
        }

        // 2. SUBIDA: solo si cada subida va seguida de una huella plana. Una subida > stepMax es pared.
        switch upHazard(samples, stepMin: stepMin, stepMax: stepMax,
                        minTread: config.minTreadMeters, hasKnownFloor: hasKnownFloor) {
        case .some(let hazard): return hazard
        case .none: break
        }

        // 3. RAMPA: pendiente suave, continua y del mismo signo, que acumula ≥ stepMin.
        if let ramp = rampHazard(samples, stepMin: stepMin) { return ramp }

        return .flat
    }

    /// Subidas válidas = salto en `[stepMin, stepMax]` seguido de una huella plana ≥ `minTread`.
    /// Una subida > `stepMax` (pared) invalida la detección de subida. nil si no hay escalón válido.
    private func upHazard(
        _ samples: [ElevationSample], stepMin: Float, stepMax: Float,
        minTread: Float, hasKnownFloor: Bool
    ) -> ElevationHazard? {
        var validRises: [Float] = []
        var prev: Float? = hasKnownFloor ? 0 : nil
        var prevForward: Float = samples.first?.forwardMeters ?? 0
        var i = 0
        while i < samples.count {
            guard let h = samples[i].heightAboveFloor else { prev = nil; i += 1; continue }
            if let p = prev {
                let delta = h - p
                if delta > stepMax { return nil }           // pared: no es escalón
                if delta >= stepMin {
                    // Huella plana a la nueva altura tras la subida.
                    var lastFlat = samples[i].forwardMeters
                    var j = i + 1
                    while j < samples.count, let hj = samples[j].heightAboveFloor, abs(hj - h) < stepMin {
                        lastFlat = samples[j].forwardMeters
                        j += 1
                    }
                    if lastFlat - samples[i].forwardMeters >= minTread {
                        validRises.append(samples[i].forwardMeters)
                        prev = h
                        prevForward = lastFlat
                        i = j
                        continue
                    }
                    // Subida sin huella: zócalo/pared, no es escalón.
                }
            }
            prev = h
            prevForward = samples[i].forwardMeters
            i += 1
        }
        _ = prevForward
        guard let first = validRises.first else { return nil }
        return validRises.count >= 2 ? .stairsUp(distance: first) : .stepUp(distance: first)
    }

    /// Primer hueco (run de `nil`) de longitud ≥ `minRun` que empieza en/ tras `after`.
    private func firstPersistentHole(_ samples: [ElevationSample], after: Int, minRun: Int) -> Float? {
        var i = max(0, after)
        while i < samples.count {
            if samples[i].heightAboveFloor == nil {
                var run = 0
                var j = i
                while j < samples.count, samples[j].heightAboveFloor == nil { run += 1; j += 1 }
                if run >= minRun { return samples[i].forwardMeters }
                i = j
            } else {
                i += 1
            }
        }
        return nil
    }

    /// Rampa: todas las muestras medidas suben (o bajan) con deltas menores que `stepMin` y el
    /// total supera `stepMin`.
    private func rampHazard(_ samples: [ElevationSample], stepMin: Float) -> ElevationHazard? {
        let measured = samples.compactMap { s -> (Float, Float)? in
            s.heightAboveFloor.map { (s.forwardMeters, $0) }
        }
        guard measured.count >= 3 else { return nil }
        var total: Float = 0
        var sign = 0
        for k in 1..<measured.count {
            let delta = measured[k].1 - measured[k - 1].1
            if abs(delta) >= stepMin { return nil }  // hay un salto: no es rampa
            if delta > 0 { if sign < 0 { return nil }; sign = 1 }
            else if delta < 0 { if sign > 0 { return nil }; sign = -1 }
            total += delta
        }
        guard abs(total) >= stepMin else { return nil }
        let onset = measured.first?.0 ?? 0
        return total > 0 ? .rampUp(distance: onset) : .rampDown(distance: onset)
    }
}
