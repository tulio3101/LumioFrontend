#if canImport(SwiftUI)
import SwiftUI

/// Registro e inicio de sesión. Los errores de campo aparecen tras el primer envío
/// y desde entonces se actualizan mientras se escribe.
@MainActor
final class AccountFormViewModel: ObservableObject {
    enum Operation {
        case credentials
        case google
    }

    struct Failure: Equatable {
        let title: String
        let message: String
        let isServiceUnavailable: Bool
    }

    @Published private(set) var access: AccountAccess
    @Published var email = "" { didSet { refreshValidation() } }
    @Published var password = "" { didSet { refreshValidation() } }
    @Published private(set) var validation = CredentialsValidation()
    @Published private(set) var operation: Operation?
    @Published private(set) var failure: Failure?

    private var hasAttemptedSubmit = false
    private let service: any Authenticating
    private let onAuthenticated: () -> Void

    init(access: AccountAccess, service: any Authenticating, onAuthenticated: @escaping () -> Void) {
        self.access = access
        self.service = service
        self.onAuthenticated = onAuthenticated
    }

    var isBusy: Bool { operation != nil }

    /// Cambia entre crear cuenta e iniciar sesión sin salir de la pantalla. Conserva el
    /// correo para no pedirlo de nuevo; la contraseña se borra porque su propósito cambia.
    func switchAccess() {
        guard !isBusy else { return }
        hasAttemptedSubmit = false
        access = access == .signUp ? .signIn : .signUp
        password = ""
        validation = CredentialsValidation()
        failure = nil
    }

    /// Devuelve el primer campo con error para llevar el foco a él; nil si se puede enviar.
    func validateForSubmit() -> CredentialsField? {
        hasAttemptedSubmit = true
        validation = CredentialsPolicy.validate(email: email, password: password, for: access)
        return validation.firstInvalidField
    }

    /// Al registrarse también inicia sesión, porque POST /users no devuelve tokens.
    func submitCredentials() async {
        guard !isBusy, validation.firstInvalidField == nil else { return }
        let credentials = AccountCredentials(
            email: CredentialsPolicy.normalizedEmail(email),
            password: password
        )
        operation = .credentials
        failure = nil
        defer { operation = nil }

        if access == .signUp {
            do {
                try await service.register(credentials)
            } catch {
                failure = describe(error, title: "No se pudo crear la cuenta", feature: "El registro")
                return
            }
        }
        do {
            try await service.signIn(credentials)
            onAuthenticated()
        } catch {
            failure = access == .signUp
                ? Failure(
                    title: "Tu cuenta se creó",
                    message: "Pero no pudimos iniciar sesión. Intenta nuevamente desde «Iniciar sesión».",
                    isServiceUnavailable: false
                )
                : describe(error, title: "No se pudo iniciar sesión", feature: "El inicio de sesión")
        }
    }

    func signInWithGoogle() async {
        guard !isBusy else { return }
        operation = .google
        failure = nil
        defer { operation = nil }
        do {
            try await service.signInWithGoogle()
            onAuthenticated()
        } catch {
            failure = describe(
                error,
                title: "No se pudo continuar con Google",
                feature: "El inicio de sesión con Google"
            )
        }
    }

    private func refreshValidation() {
        guard hasAttemptedSubmit else { return }
        validation = CredentialsPolicy.validate(email: email, password: password, for: access)
    }

    private func describe(_ error: Error, title: String, feature: String) -> Failure {
        switch error {
        case FeatureUnavailable.authentication:
            return Failure(
                title: title,
                message: "\(feature) todavía no está conectado con el servidor de Lumio.",
                isServiceUnavailable: true
            )
        case AuthenticationError.invalidCredentials:
            return Failure(
                title: title,
                message: "El correo o la contraseña no son correctos.",
                isServiceUnavailable: false
            )
        case AuthenticationError.emailAlreadyRegistered:
            return Failure(
                title: title,
                message: "Ya existe una cuenta con ese correo. Usa «Iniciar sesión».",
                isServiceUnavailable: false
            )
        case is URLError:
            return Failure(
                title: title,
                message: "No pudimos conectar con el servidor de Lumio. Revisa tu conexión e intenta de nuevo.",
                isServiceUnavailable: true
            )
        default:
            return Failure(title: title, message: "Intenta nuevamente en unos momentos.", isServiceUnavailable: false)
        }
    }
}
#endif
