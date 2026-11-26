import Foundation

/// SCRUM-42: la narración del entorno siempre entra al árbitro como P3
/// (`environmentInformation`). No interrumpe alertas (P1) ni indicaciones (P2) y solo suena
/// cuando el canal está libre. El nivel que devuelva el backend nunca sube la prioridad:
/// el riesgo inmediato es una decisión local del loop de seguridad (ADR-308).
enum NarrationAudio {
    /// Un solo contexto para todas las narraciones: permite cancelarlas juntas (por ejemplo,
    /// al revocar el consentimiento) sin tocar la navegación ni la seguridad.
    static let contextID = "narration"
    /// Avisos de estado de la narración («Describiendo…», fallas y, desde SCRUM-41, caída y
    /// vuelta del servicio). Distinto de `contextID` para que una descripción nueva no los
    /// cancele ni ellos a ella.
    static let statusContextID = "narration-status"
    /// Una narración que espera turno más de este tiempo desde la captura ya no describe
    /// lo que el usuario tiene delante y se descarta antes de sonar.
    static let defaultLifetime: TimeInterval = 10

    /// `captureSequence` crece con cada frame capturado: una respuesta de una captura más
    /// vieja que la última aceptada se descarta (AudioDeduplicationPolicy).
    static func message(
        text: String,
        capturedAt: Date,
        captureSequence: UInt64,
        lifetime: TimeInterval = defaultLifetime
    ) -> AudioMessage {
        AudioMessage(
            text: text,
            priority: .environmentInformation,
            createdAt: capturedAt,
            expiresAt: capturedAt.addingTimeInterval(lifetime),
            contextID: contextID,
            deduplicationKey: "scene",
            captureSequence: captureSequence
        )
    }
}
