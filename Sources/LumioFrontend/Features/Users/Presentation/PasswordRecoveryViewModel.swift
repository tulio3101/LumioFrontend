import Foundation
#if canImport(Combine)
import Combine

/// Estado de Recuperar Contraseña. Validar, enviar y locutar lo hace PasswordRecoveryService;
/// aquí solo se refleja en la pantalla. Los errores de campo aparecen tras el primer intento.
@MainActor
final class PasswordRecoveryViewModel: ObservableObject {
    enum Step: Equatable {
        /// Pedir el código con el correo.
        case email
        /// Escribir el código y la nueva contraseña.
        case code
        /// Contraseña restablecida: volver a iniciar sesión.
        case done
    }

    struct Banner: Equatable {
        enum Kind: Equatable { case success, info, error }
        let kind: Kind
        let title: String
        let message: String
    }

    @Published var email: String
    @Published var code = "" { didSet { refreshValidation() } }
    @Published var newPassword = "" { didSet { refreshValidation() } }
    @Published var confirmation = "" { didSet { refreshValidation() } }
    @Published private(set) var step = Step.email
    @Published private(set) var emailIssue: EmailIssue?
    @Published private(set) var validation = PasswordResetValidation()
    @Published private(set) var banner: Banner?
    @Published private(set) var isBusy = false

    private var attemptedReset = false
    private let service: any PasswordRecovering

    init(service: any PasswordRecovering, email: String = "") {
        self.service = service
        self.email = email
    }

    func requestCode() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        switch await service.requestCode(email: email) {
        case .requested:
            emailIssue = nil
            code = ""
            step = .code
            banner = Banner(kind: .info, title: "Revisa tu correo", message: PasswordRecoveryAnnouncements.requested)
        case .invalid(let issue):
            emailIssue = issue
            banner = nil
        case .failed(let failure):
            banner = Banner(
                kind: .error,
                title: "No se pudo enviar el código",
                message: PasswordRecoveryAnnouncements.message(for: failure)
            )
        }
    }

    func resetPassword() async {
        guard !isBusy else { return }
        attemptedReset = true
        isBusy = true
        defer { isBusy = false }
        switch await service.resetPassword(
            email: email, code: code, newPassword: newPassword, confirmation: confirmation
        ) {
        case .reset:
            attemptedReset = false
            newPassword = ""
            confirmation = ""
            validation = PasswordResetValidation()
            step = .done
            banner = Banner(kind: .success, title: "Contraseña restablecida", message: PasswordRecoveryAnnouncements.reset)
        case .invalid(let invalid):
            validation = invalid
            banner = Banner(
                kind: .error,
                title: "Revisa los datos",
                message: PasswordRecoveryAnnouncements.messages(for: invalid).joined(separator: " ")
            )
        case .failed(let failure):
            banner = Banner(
                kind: .error,
                title: "No se restableció la contraseña",
                message: PasswordRecoveryAnnouncements.message(for: failure)
            )
        }
    }

    /// «Usar otro correo»: vuelve al primer paso conservando lo escrito.
    func changeEmail() {
        guard !isBusy else { return }
        step = .email
        banner = nil
    }

    private func refreshValidation() {
        guard attemptedReset else { return }
        validation = PasswordResetPolicy.validate(code: code, newPassword: newPassword, confirmation: confirmation)
    }
}
#endif
