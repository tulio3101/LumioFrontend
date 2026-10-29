import Foundation

/// Propósito del formulario de cuenta; también es el destino de navegación desde la bienvenida.
enum AccountAccess: Hashable {
    case signUp
    case signIn
}

struct AccountCredentials: Equatable {
    let email: String
    let password: String
}

enum CredentialsField: Hashable {
    case email
    case password
}

enum EmailIssue: Equatable {
    case missing
    case invalidFormat
}

enum PasswordIssue: Equatable {
    case missing
    case tooShort(minimum: Int)
    case tooLong(maximum: Int)
}

struct CredentialsValidation: Equatable {
    var email: EmailIssue?
    var password: PasswordIssue?

    /// En orden visual, para llevar el foco al primer campo que hay que corregir.
    var firstInvalidField: CredentialsField? {
        if email != nil { return .email }
        if password != nil { return .password }
        return nil
    }
}

/// Reglas locales previas al envío. Reflejan UserCreate/UserLogin del backend, que sigue
/// siendo la autoridad: solo evitan envíos que el servidor rechazaría con seguridad.
enum CredentialsPolicy {
    /// Igual que UserCreate.password (min_length 8, max_length 128).
    static let passwordLength = 8...128

    static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validate(email: String, password: String, for access: AccountAccess) -> CredentialsValidation {
        CredentialsValidation(
            email: emailIssue(normalizedEmail(email)),
            password: passwordIssue(password, for: access)
        )
    }

    private static func emailIssue(_ email: String) -> EmailIssue? {
        if email.isEmpty { return .missing }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !email.contains(where: \.isWhitespace) else {
            return .invalidFormat
        }
        let domainLabels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard domainLabels.count >= 2, domainLabels.allSatisfy({ !$0.isEmpty }) else {
            return .invalidFormat
        }
        return nil
    }

    private static func passwordIssue(_ password: String, for access: AccountAccess) -> PasswordIssue? {
        // Python mide la longitud en puntos de código, no en grafemas como String.count.
        let length = password.unicodeScalars.count
        if length == 0 { return .missing }
        if length > passwordLength.upperBound { return .tooLong(maximum: passwordLength.upperBound) }
        // Al iniciar sesión no se exige el mínimo: la contraseña ya existe y el servidor decide.
        if access == .signUp, length < passwordLength.lowerBound {
            return .tooShort(minimum: passwordLength.lowerBound)
        }
        return nil
    }
}
