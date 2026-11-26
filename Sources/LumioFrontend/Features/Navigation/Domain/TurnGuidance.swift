import Foundation

/// Guiar Giros durante el Trayecto (SCRUM-312): lado de cada maniobra, cuándo anunciarla y qué
/// se dice. La guía trabaja solo con la copia local de la ruta y el GPS; nunca con el backend.

/// Lado de la maniobra. Decide el patrón háptico: izquierda y derecha vibran distinto.
enum TurnDirection: Equatable {
    case left
    case right
    /// Seguir recto, cruzar o una instrucción sin lado.
    case none

    var hapticCue: HapticCue? {
        switch self {
        case .left: return .turnLeft
        case .right: return .turnRight
        case .none: return nil
        }
    }
}

/// Lo que la guía sabe de una maniobra a partir de su instrucción de MapKit (en español o,
/// si el sistema la da en inglés, en inglés).
struct TurnManeuver: Equatable {
    let direction: TurnDirection
    /// Giro cerrado (esquina) o amplio (curva, «ligeramente», «mantente»). Decide el margen de
    /// reacción del spike SCRUM-309 (`TurnGeometry`).
    let geometry: TurnGeometry

    init(direction: TurnDirection, geometry: TurnGeometry) {
        self.direction = direction
        self.geometry = geometry
    }

    init(instruction: String) {
        let text = instruction
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
        // Si la instrucción nombra los dos lados, cuenta el que aparece primero.
        let left = Self.firstIndex(of: ["izquierda", "left"], in: text)
        let right = Self.firstIndex(of: ["derecha", "right"], in: text)
        switch (left, right) {
        case let (left?, right?): direction = left < right ? .left : .right
        case (.some, nil): direction = .left
        case (nil, .some): direction = .right
        case (nil, nil): direction = .none
        }
        let wideWords = ["ligeramente", "levemente", "mantente", "curva", "slight", "keep", "bear"]
        geometry = wideWords.contains(where: { text.contains($0) }) ? .wide : .sharp
    }

    private static func firstIndex(of words: [String], in text: String) -> String.Index? {
        words.compactMap { text.range(of: $0)?.lowerBound }.min()
    }
}

/// Los dos anuncios de cada giro.
enum TurnStage: String, Equatable {
    /// «En 40 metros, gira a la izquierda…»: tiempo para prepararse.
    case prepare
    /// «Ahora, gira a la izquierda…»: el giro está a unos pasos.
    case now
}

/// Cuándo anunciar cada giro según la distancia y la velocidad de marcha. Valores iniciales
/// acordados por el equipo; se validan caminando rutas reales (SCRUM-329).
struct TurnGuidancePolicy: Equatable {
    /// El aviso previo se da unos 25 s antes del giro, entre 30 y 60 m.
    var prepareLeadSeconds: TimeInterval = 25
    var minimumPrepareDistanceMeters = 30.0
    var maximumPrepareDistanceMeters = 60.0
    /// «Ahora» se da unos 6 s antes (lo que tarda la frase más 1,5–2,5 s de reacción), entre
    /// 8 y 15 m.
    var imminentLeadSeconds: TimeInterval = 6
    var minimumImminentDistanceMeters = 8.0
    var maximumImminentDistanceMeters = 15.0
    /// Las lecturas menos precisas no anuncian ni avanzan pasos; cuentan como señal débil.
    var maximumAccuracyMeters = 25.0
    /// Más lejos del trayecto no se anuncian giros: decide Recalcular Ruta (SCRUM-26).
    var offRouteThresholdMeters = DeviationPolicy().offRouteThresholdMeters
    /// Una maniobra tan cerca del inicio ya se dijo con «Ruta lista» (o «Ruta actualizada» o
    /// «Ruta recalculada»): no se repite.
    var startRadiusMeters = 15.0
    /// Velocidades fuera de este rango no son de marcha (GPS ruidoso, vehículo): se usa la
    /// típica.
    var minimumWalkingSpeed = 0.2
    var maximumWalkingSpeed = 3.0
    /// Lecturas imprecisas seguidas para avisar de señal débil.
    var weakSignalFixes = 3
    /// Lecturas precisas seguidas para avisar de que la señal volvió.
    var recoveredSignalFixes = 2
    /// Sin ninguna lectura durante este tiempo, la señal es débil.
    var signalTimeoutSeconds: TimeInterval = 15
    /// Margen tras el momento estimado del giro antes de descartar su anuncio si aún no sonó.
    var announcementGraceSeconds: TimeInterval = 3

    func isPrecise(_ fix: LocationFix) -> Bool {
        fix.coordinate.isValid && fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= maximumAccuracyMeters
    }

    /// Velocidad de marcha del GPS o, si no sirve, la típica (`TurnDeadline.typicalWalkingSpeed`).
    func walkingSpeed(of fix: LocationFix) -> Double {
        guard let speed = fix.speedMetersPerSecond, speed.isFinite,
              speed >= minimumWalkingSpeed, speed <= maximumWalkingSpeed else {
            return TurnDeadline.typicalWalkingSpeed
        }
        return speed
    }

    func prepareDistance(speed: Double) -> Double {
        min(maximumPrepareDistanceMeters, max(minimumPrepareDistanceMeters, speed * prepareLeadSeconds))
    }

    func imminentDistance(speed: Double) -> Double {
        min(maximumImminentDistanceMeters, max(minimumImminentDistanceMeters, speed * imminentLeadSeconds))
    }

    /// Qué anuncio toca a esta distancia del giro; nil si aún está lejos.
    func stage(distanceMeters: Double, speed: Double) -> TurnStage? {
        if distanceMeters <= imminentDistance(speed: speed) { return .now }
        if distanceMeters <= prepareDistance(speed: speed) { return .prepare }
        return nil
    }
}

/// Textos de Guiar Giros. Se locutan por el AudioArbiter (P2) y la pantalla no los repite.
enum TurnAnnouncements {
    static let gpsWeak = "Señal de GPS débil. Las indicaciones de giro pueden llegar tarde; "
        + "avanza con precaución. La detección de obstáculos sigue activa."
    static let gpsRecovered = "Señal de GPS recuperada. Sigue la guía de giros."
    static let offline = "Sin conexión a internet. La guía de giros sigue con la ruta guardada "
        + "en el teléfono y la detección de obstáculos sigue activa."
    static let online = "Volvió la conexión a internet."

    /// «En 40 metros, gira a la izquierda en la Carrera 5.»
    static func prepare(_ step: RouteStep, distanceMeters: Double) -> String {
        "En \(spokenDistance(distanceMeters)), \(lowercasingFirst(step.instruction))."
    }

    /// «Ahora, gira a la izquierda en la Carrera 5 y continúa 260 metros.»
    static func now(_ step: RouteStep, instructions: NavigationInstructionBuilder) -> String {
        "Ahora, " + lowercasingFirst(instructions.spokenText(for: step))
    }

    /// Aviso previo a la llegada: «En 30 metros, llegas a Farmacia Central. El destino está a
    /// la derecha.» La llegada misma la anuncia Finalizar Ruta («Llegaste a…»).
    static func approaching(_ route: ActiveRoute, step: RouteStep, distanceMeters: Double) -> String {
        var text = "En \(spokenDistance(distanceMeters)), llegas a \(route.destination.name)."
        if TurnManeuver(instruction: step.instruction).direction != .none {
            text += " \(step.instruction)."
        }
        return text
    }

    /// Distancia al giro como la diría una persona: de 5 en 5 metros por debajo de 100.
    static func spokenDistance(_ meters: Double) -> String {
        guard meters < 97.5 else { return SpokenDistance.text(meters: meters) }
        return SpokenDistance.text(meters: max(5, (meters / 5).rounded() * 5))
    }

    private static func lowercasingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + String(text.dropFirst())
    }
}
