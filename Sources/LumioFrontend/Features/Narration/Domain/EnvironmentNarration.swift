import Foundation

/// SCRUM-38: foto preparada para narrar (ADR-308 §2). JPEG de 768 px de lado largo, calidad
/// 0,7, vertical y sin metadatos (ni EXIF ni GPS). Vive solo en memoria.
struct NarrationFrame: Equatable {
    let jpeg: Data
    let capturedAt: Date
}

enum NarrationCapture: Equatable {
    case frame(NarrationFrame)
    /// La cámara no está corriendo (no hay trayecto activo o la detección no arrancó).
    case cameraInactive
    /// No llegó una foto útil a tiempo: ARKit sin seguimiento normal (cámara movida o tapada).
    case noUsableFrame
}

/// SCRUM-261: toma una foto para narrar del `ARSession` que ya corre para la seguridad, sin
/// abrir otra cámara. Nunca frena ni consume frames del loop de seguridad.
protocol NarrationFrameCapturing: AnyObject {
    func captureNarrationFrame() async -> NarrationCapture
}

/// Lo que la narración necesita del consentimiento (SCRUM-324).
@MainActor
protocol NarrationConsentGating: NarrationConsentChecking {
    /// true si ya se puede narrar; si no, lo explica o recuerda dónde activarlo.
    @discardableResult func requireConsentBeforeNarration() -> Bool
}

extension NarrationConsentService: NarrationConsentGating {}

/// SCRUM-39: pedir una descripción a pedido (botón, comando de voz o acción de VoiceOver).
/// El resultado llega por audio.
@MainActor
protocol NarrationRequesting: AnyObject {
    func requestDescription()
}

extension EnvironmentNarrationService: NarrationRequesting {}

/// Cuándo se pidió la narración (ADR-308 §6). Solo para métricas del backend.
enum NarrationTrigger: String {
    case gesture
    case auto
}

/// SCRUM-262/263/264: envía la foto a `POST /vision/analyze` y devuelve la descripción.
protocol EnvironmentDescribing {
    func describe(
        _ frame: NarrationFrame, trigger: NarrationTrigger, consentVersion: String
    ) async throws -> String
}

/// Lo que se encola o se informa al terminar una solicitud. Se prueba sin audio.
enum EnvironmentNarrationOutcome: Equatable {
    /// La descripción entró al árbitro como P3.
    case described(String)
    /// SCRUM-39: se pidió otra vez enseguida o la escena no cambió: se repitió la última
    /// descripción sin enviar otra foto.
    case repeated(String)
    /// Sin consentimiento: lo explica el servicio de consentimiento (SCRUM-324).
    case consentRequired
    /// Ya había una solicitud en curso: no se envía otra.
    case alreadyDescribing
    /// Se canceló en vuelo (por ejemplo, al retirar el consentimiento): no suena nada.
    case cancelled
    /// La narración no está disponible; se informa por audio.
    case unavailable(EnvironmentNarrationUnavailable)
}

/// SCRUM-266/267: por qué no hay narración. Ninguno de estos casos toca la seguridad.
enum EnvironmentNarrationUnavailable: Equatable {
    case offline
    case cameraInactive
    case noUsableFrame
    case sessionRequired
    case notConfigured
    case rateLimited
    case serviceUnavailable
    case timedOut
    case stale
}

/// SCRUM-39: cuándo una solicitud repetida no merece otra foto ni otra llamada al backend.
struct NarrationRepeatPolicy: Equatable {
    /// Pedir otra vez dentro de este tiempo repite la última descripción sin tomar foto
    /// (el backend admite una solicitud cada 3 s, ADR-308).
    var replayWindow: TimeInterval = 3
    /// Dentro de este tiempo se toma la foto, pero si la escena no cambió se repite la
    /// última descripción en lugar de enviarla.
    var sameSceneWindow: TimeInterval = 10
    /// Distancia mínima entre huellas para considerar que la escena cambió (la misma que
    /// usa la narración automática, SCRUM-40).
    var changeThreshold: Float = AutoNarrationConfiguration().changeThreshold

    func replaysWithoutPhoto(lastCapturedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastCapturedAt) < replayWindow
    }

    func replaysSameScene(
        last: SceneSignature?, lastCapturedAt: Date, current: SceneSignature?, now: Date
    ) -> Bool {
        guard now.timeIntervalSince(lastCapturedAt) < sameSceneWindow,
              let last, let current, let distance = last.distance(to: current) else { return false }
        return distance < changeThreshold
    }
}

enum EnvironmentNarrationMessages {
    static let describing = "Describiendo el entorno…"
    /// SCRUM-39: una solicitud mientras otra está en curso.
    static let alreadyDescribing = "Ya estoy describiendo el entorno."

    /// SCRUM-39: la última descripción, repetida porque no hay nada nuevo que describir.
    static func repeated(_ text: String) -> String {
        "Sigue igual que hace un momento. \(text)"
    }

    static func message(for reason: EnvironmentNarrationUnavailable) -> String {
        switch reason {
        case .offline:
            return "Narración no disponible sin conexión. La detección de obstáculos sigue activa."
        case .cameraInactive:
            return "La narración necesita la cámara activa. Inicia un trayecto y vuelve a intentarlo."
        case .noUsableFrame:
            return "No pude tomar una foto clara. Sostén el teléfono quieto, mirando al frente, y vuelve a intentarlo."
        case .sessionRequired:
            return "La narración del entorno necesita que inicies sesión."
        case .notConfigured:
            return "La narración del entorno no está disponible en esta versión."
        case .rateLimited:
            return "Espera unos segundos antes de pedir otra descripción."
        case .serviceUnavailable:
            return "La narración del entorno no está disponible ahora. La detección de obstáculos sigue activa."
        case .timedOut, .stale:
            return "La descripción tardó demasiado y ya no corresponde a lo que tienes delante. Vuelve a intentarlo."
        }
    }
}
