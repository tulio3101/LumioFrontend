import Foundation

/// SCRUM-324: decisión del usuario sobre enviar fotos de la cámara para narrar el entorno.
/// Se guarda en el teléfono (`{granted, version, date}`, ADR-308). Si cambia el texto del
/// aviso, cambia `NarrationConsentPolicy.currentVersion` y se vuelve a pedir.
struct NarrationConsent: Codable, Equatable {
    let granted: Bool
    let version: String
    let decidedAt: Date
}

enum NarrationConsentStatus: Equatable {
    /// Nunca se pidió.
    case notAsked
    /// Aceptó el aviso vigente: la narración puede enviar imágenes.
    case granted
    /// No aceptó o lo retiró: no se envía ninguna imagen.
    case declined
    /// Aceptó un aviso anterior: hay que explicarlo y pedirlo de nuevo.
    case outdated
}

enum NarrationConsentPolicy {
    /// Versión del aviso. Cambiarla cuando cambie `explanation`.
    static let currentVersion = "2026-11-1"

    /// Lo que se explica por audio y en pantalla antes de activar la narración (ADR-308).
    static let explanation = """
    Para describir lo que tienes delante, Lumio envía fotos de la cámara a un servicio en la \
    nube de Amazon Web Services. Lumio no guarda las fotos ni las descripciones, y el servicio \
    no describe a las personas. Amazon puede conservarlas por un tiempo para prevenir abusos. \
    Sin tu consentimiento la narración del entorno no se activa, y la detección de obstáculos \
    y la navegación funcionan igual. Puedes retirarlo cuando quieras en Preferencias, \
    Narración del entorno.
    """

    static let question = "¿Aceptas que Lumio envíe fotos de la cámara para narrar el entorno?"

    static func status(of consent: NarrationConsent?) -> NarrationConsentStatus {
        guard let consent else { return .notAsked }
        guard consent.granted else { return .declined }
        return consent.version == currentVersion ? .granted : .outdated
    }

    static let accepted = "Consentimiento guardado. La narración del entorno puede enviar fotos de la cámara."
    static let declined = "No se enviarán fotos. La narración del entorno queda desactivada; lo demás funciona igual."
    static let revoked = "Consentimiento retirado. Ya no se envían fotos y la narración del entorno queda desactivada."
    static let saveFailed = "No se pudo guardar tu decisión. Inténtalo de nuevo."
    static let required = "La narración del entorno necesita tu consentimiento para enviar fotos. Ve a Preferencias, Narración del entorno."
}

protocol NarrationConsentStoring {
    func load() throws -> NarrationConsent?
    func save(_ consent: NarrationConsent) throws
}

/// SCRUM-38/39: antes de cada envío. Sin consentimiento vigente devuelve nil y el cliente no
/// llama a `POST /vision/analyze`; con él, la versión va en `consent_version`.
@MainActor
protocol NarrationConsentChecking: AnyObject {
    var consentVersionForUpload: String? { get }
}

/// Pantalla Preferencias > Narración del entorno.
@MainActor
protocol NarrationConsentManaging: AnyObject {
    var status: NarrationConsentStatus { get }
    /// Lee el aviso en voz alta (por el AudioArbiter).
    func explain()
    @discardableResult func accept() -> Bool
    @discardableResult func decline() -> Bool
    @discardableResult func revoke() -> Bool
}
