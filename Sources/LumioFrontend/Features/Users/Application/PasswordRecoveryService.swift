import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Recuperar Contraseña:
///
/// 1. Pedir el código: valida el correo en el teléfono y lo envía. El resultado se locuta
///    siempre igual, exista o no la cuenta.
/// 2. Restablecer: valida el código (6 dígitos) y la nueva contraseña (mismas reglas que al
///    crear la cuenta, con confirmación) y la envía. Si el código no sirve, se dice sin dar
///    detalles. Al terminar, se inicia sesión con la nueva contraseña.
///
/// Todo lo que dice pasa por el AudioArbiter como P2 (contexto `password-recovery`).
@MainActor
final class PasswordRecoveryService: PasswordRecovering {
    static let contextID = "password-recovery"

    private let remote: any PasswordRecoveryRemoting
    private let arbiter: (any AudioArbitrating)?
    private let now: () -> Date

    init(
        remote: any PasswordRecoveryRemoting,
        arbiter: (any AudioArbitrating)?,
        now: @escaping () -> Date = Date.init
    ) {
        self.remote = remote
        self.arbiter = arbiter
        self.now = now
    }

    func requestCode(email: String) async -> PasswordCodeRequestOutcome {
        let normalized = CredentialsPolicy.normalizedEmail(email)
        if let issue = CredentialsPolicy.emailIssue(normalized) {
            speak(PasswordRecoveryAnnouncements.message(for: issue), key: "invalid-email")
            return .invalid(issue)
        }
        do {
            try await remote.requestCode(email: normalized)
            speak(PasswordRecoveryAnnouncements.requested, key: "requested")
            return .requested
        } catch {
            let failure = Self.failure(for: error)
            speak(PasswordRecoveryAnnouncements.message(for: failure), key: "failed")
            return .failed(failure)
        }
    }

    func resetPassword(email: String, code: String, newPassword: String, confirmation: String) async
        -> PasswordResetOutcome {
        let validation = PasswordResetPolicy.validate(
            code: code, newPassword: newPassword, confirmation: confirmation
        )
        guard validation.isValid else {
            speak(
                "Revisa los datos. " + PasswordRecoveryAnnouncements.messages(for: validation).joined(separator: " "),
                key: "invalid"
            )
            return .invalid(validation)
        }
        do {
            try await remote.resetPassword(
                email: CredentialsPolicy.normalizedEmail(email),
                code: PasswordResetPolicy.normalizedCode(code),
                newPassword: newPassword
            )
            speak(PasswordRecoveryAnnouncements.reset, key: "reset")
            return .reset
        } catch {
            let failure = Self.failure(for: error)
            speak(PasswordRecoveryAnnouncements.message(for: failure), key: "failed")
            return .failed(failure)
        }
    }

    nonisolated static func failure(for error: Error) -> PasswordRecoveryFailure {
        switch error {
        case FeatureUnavailable.authentication:
            return .unavailable
        case HTTPClientError.statusCode(400):
            return .invalidCode
        case HTTPClientError.statusCode(422):
            return .rejected
        case let error as URLError where error.isConnectivityFailure:
            return .offline
        default:
            return .server
        }
    }

    /// Un mensaje nuevo del flujo reemplaza al anterior.
    private func speak(_ text: String, key: String) {
        guard let arbiter else { return }
        arbiter.cancel(contextIDs: [Self.contextID])
        arbiter.receive(AudioMessage(
            text: text,
            priority: .routeInformation,
            createdAt: now(),
            expiresAt: now().addingTimeInterval(60),
            contextID: Self.contextID,
            deduplicationKey: key
        ))
    }
}
