import Foundation

/// Avisa, una sola vez por cooldown, que el usuario levante o baje el teléfono cuando la cámara
/// apunta demasiado al piso o al cielo, en vez de detectar ruido (SCRUM-33). Mismo patrón que
/// `LowLightDetector`: tiene su propio AudioArbiter y emite por él (nunca TTS directo).
final class PhonePitchReminder {
    private let audioArbiter: any AudioArbitrating
    private let cooldown: TimeInterval
    private var lastReminder: Date?
    private var lastState: PitchState = .ok

    init(audioArbiter: any AudioArbitrating, cooldown: TimeInterval = 6.0) {
        self.audioArbiter = audioArbiter
        self.cooldown = cooldown
    }

    /// Procesa la inclinación del frame. Devuelve `true` si está fuera de rango, para que el
    /// pipeline omita la detección de ese frame (evita avisar objetos falsos). Emite el
    /// recordatorio al entrar al estado o al vencer el cooldown.
    @discardableResult
    func analyze(_ state: PitchState, now: Date = Date()) -> Bool {
        guard state != .ok else {
            lastState = .ok
            return false
        }
        let due = lastReminder.map { now.timeIntervalSince($0) >= cooldown } ?? true
        if state != lastState || due {
            lastReminder = now
            let message = state == .tooLow ? SafetyAudio.raisePhone() : SafetyAudio.lowerPhone()
            Task { @MainActor in self.audioArbiter.receive(message) }
        }
        lastState = state
        return true
    }
}
