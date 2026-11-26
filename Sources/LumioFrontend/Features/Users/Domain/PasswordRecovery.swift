import Foundation

/// Recuperar Contraseña (solo cuentas con contraseña propia; Google no usa contraseña de
/// Lumio). Dos pasos: pedir un código de 6 dígitos que llega por correo y restablecer la
/// contraseña con él. El backend responde igual exista o no la cuenta, y la app también.
protocol PasswordRecoveryRemoting {
    /// POST /users/password-reset (202 siempre que se procese).
    func requestCode(email: String) async throws
    /// POST /users/password-reset/confirm (204). 400 si el código no sirve.
    func resetPassword(email: String, code: String, newPassword: String) async throws
}

/// Por qué no se pudo completar. Ninguno cambia la contraseña.
enum PasswordRecoveryFailure: Error, Equatable {
    case offline
    /// Código incorrecto, vencido, ya usado o agotado (el backend no distingue).
    case invalidCode
    /// El backend rechazó los datos (422) aunque pasaron la validación local.
    case rejected
    case server
    /// Sin LumioAPIBaseURL configurada.
    case unavailable
}

enum ResetCodeIssue: Equatable {
    case missing
    case invalid
}

struct PasswordResetValidation: Equatable {
    var code: ResetCodeIssue?
    var newPassword: NewPasswordIssue?
    var confirmationMismatch = false

    var isValid: Bool { code == nil && newPassword == nil && !confirmationMismatch }
}

enum PasswordCodeRequestOutcome: Equatable {
    /// Procesada: si la cuenta existe, el código va en camino. No se sabe ni se dice si existe.
    case requested
    case invalid(EmailIssue)
    case failed(PasswordRecoveryFailure)
}

enum PasswordResetOutcome: Equatable {
    case reset
    case invalid(PasswordResetValidation)
    case failed(PasswordRecoveryFailure)
}

@MainActor
protocol PasswordRecovering: AnyObject {
    func requestCode(email: String) async -> PasswordCodeRequestOutcome
    func resetPassword(email: String, code: String, newPassword: String, confirmation: String) async
        -> PasswordResetOutcome
}

/// Reglas locales: las mismas que el backend (código de 6 dígitos, contraseña de 8 a 128).
enum PasswordResetPolicy {
    static let codeLength = 6

    /// El usuario puede escribirlo o pegarlo con espacios («4 8 2 9 1 5»).
    static func normalizedCode(_ code: String) -> String {
        String(code.filter { $0.isASCII && $0.isNumber })
    }

    static func validate(code: String, newPassword: String, confirmation: String) -> PasswordResetValidation {
        let digits = normalizedCode(code)
        let codeIssue: ResetCodeIssue?
        if code.trimmingCharacters(in: .whitespaces).isEmpty {
            codeIssue = .missing
        } else if digits.count != codeLength || code.contains(where: { !$0.isWhitespace && !($0.isASCII && $0.isNumber) }) {
            codeIssue = .invalid
        } else {
            codeIssue = nil
        }
        return PasswordResetValidation(
            code: codeIssue,
            newPassword: passwordIssue(newPassword),
            confirmationMismatch: !newPassword.isEmpty && newPassword != confirmation
        )
    }

    private static func passwordIssue(_ password: String) -> NewPasswordIssue? {
        // Como el backend: longitud en puntos de código.
        let length = password.unicodeScalars.count
        let range = CredentialsPolicy.passwordLength
        if length == 0 { return .missing }
        if length < range.lowerBound { return .tooShort(minimum: range.lowerBound) }
        if length > range.upperBound { return .tooLong(maximum: range.upperBound) }
        return nil
    }
}

/// Lo que se muestra es lo mismo que se locuta.
enum PasswordRecoveryAnnouncements {
    static let requested = "Si el correo corresponde a una cuenta con contraseña, te enviamos un código "
        + "de 6 dígitos. Revisa tu correo y escríbelo aquí junto con tu nueva contraseña. "
        + "Vence en 15 minutos."
    static let reset = "Contraseña restablecida. Se cerró la sesión en todos tus dispositivos. "
        + "Ya puedes iniciar sesión con tu nueva contraseña."
    static let googleNote = "Si entras con Google, no necesitas recuperar una contraseña de Lumio."

    static func message(for failure: PasswordRecoveryFailure) -> String {
        switch failure {
        case .offline:
            "Sin conexión. No se pudo completar la solicitud. Intenta de nuevo cuando tengas conexión."
        case .invalidCode:
            "El código no es válido o ya venció. Revisa el último correo o pide uno nuevo."
        case .rejected:
            "El servidor rechazó los datos. Revísalos e intenta de nuevo."
        case .server:
            "No se pudo completar la recuperación. Tu contraseña sigue igual; intenta de nuevo más tarde."
        case .unavailable:
            "La recuperación de contraseña todavía no está conectada con el servidor de Lumio."
        }
    }

    static func message(for issue: ResetCodeIssue) -> String {
        switch issue {
        case .missing: "Escribe el código que llegó a tu correo."
        case .invalid: "El código tiene 6 dígitos."
        }
    }

    static func message(for issue: EmailIssue) -> String {
        switch issue {
        case .missing: "Escribe tu correo electrónico."
        case .invalidFormat: "Escribe un correo válido, por ejemplo nombre@correo.com."
        }
    }

    static func messages(for validation: PasswordResetValidation) -> [String] {
        [
            validation.code.map(message(for:)),
            validation.newPassword.map(ProfileAnnouncements.message(for:)),
            validation.confirmationMismatch ? "Las contraseñas nuevas no coinciden." : nil,
        ].compactMap { $0 }
    }
}
