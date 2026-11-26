import Foundation

/// Cuenta del usuario (GET /users/me). El correo se consulta pero no se puede cambiar; el
/// nombre y el celular son el perfil configurable (Personalizar Cuenta, SCRUM-6). Las
/// preferencias de voz y háptica no van aquí: son UserPreferences, en el teléfono.
struct UserProfile: Identifiable, Equatable {
    let id: UUID
    let email: String
    var displayName: String?
    /// Celular colombiano de 10 dígitos sin prefijo.
    var phone: String?
    /// SCRUM-62: tiene una cuenta de Google asociada (puede iniciar sesión con Google).
    var googleLinked = false
}

/// Lo que se guarda con PATCH /users/me: los dos campos; nil quita el dato.
struct ProfileChanges: Equatable {
    let displayName: String?
    let phone: String?
}

/// /users/me con la sesión actual.
protocol ProfileRemoting {
    func loadProfile() async throws -> UserProfile
    func updateProfile(_ changes: ProfileChanges) async throws -> UserProfile
    /// PUT /users/me/password. El backend cierra las sesiones de los demás dispositivos.
    func changePassword(current: String, new: String) async throws
    /// POST /users/me/google (SCRUM-62): asocia la cuenta de Google del ID token.
    func linkGoogle(idToken: String) async throws -> UserProfile
}

// MARK: - Validación

enum ProfileField: Hashable {
    case displayName
    case phone
}

enum DisplayNameIssue: Equatable {
    case tooLong(maximum: Int)
    case invalidCharacters
}

enum PhoneIssue: Equatable {
    case invalid
}

struct ProfileValidation: Equatable {
    var displayName: DisplayNameIssue?
    var phone: PhoneIssue?

    var firstInvalidField: ProfileField? {
        if displayName != nil { return .displayName }
        if phone != nil { return .phone }
        return nil
    }
}

/// Reglas locales previas al envío. Reflejan UserProfileUpdate del backend, que sigue
/// siendo la autoridad. Vacío significa quitar el dato.
enum ProfilePolicy {
    static let displayNameMaxLength = 60
    private static let nameSymbols: Set<Character> = [" ", "'", "’", ".", "-"]

    /// Forma compuesta (NFC) y espacios recortados y unidos, como en el backend.
    static func normalizedDisplayName(_ name: String) -> String? {
        let composed = name.precomposedStringWithCanonicalMapping
        let words = composed.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Sin espacios ni guiones, que se aceptan al escribir.
    static func normalizedPhone(_ phone: String) -> String? {
        let digits = phone.filter { !$0.isWhitespace && $0 != "-" }
        return digits.isEmpty ? nil : digits
    }

    static func changes(displayName: String, phone: String) -> ProfileChanges {
        ProfileChanges(displayName: normalizedDisplayName(displayName), phone: normalizedPhone(phone))
    }

    static func validate(displayName: String, phone: String) -> ProfileValidation {
        let changes = changes(displayName: displayName, phone: phone)
        return ProfileValidation(
            displayName: changes.displayName.flatMap(displayNameIssue),
            phone: changes.phone.flatMap(phoneIssue)
        )
    }

    /// Reglas del nombre ya normalizado. También las usan los contactos de confianza.
    static func displayNameIssue(_ name: String) -> DisplayNameIssue? {
        // Python mide la longitud en puntos de código, no en grafemas como String.count.
        if name.unicodeScalars.count > displayNameMaxLength { return .tooLong(maximum: displayNameMaxLength) }
        let valid = name.contains(where: \.isLetter)
            && name.allSatisfy { $0.isLetter || nameSymbols.contains($0) }
        return valid ? nil : .invalidCharacters
    }

    private static func phoneIssue(_ phone: String) -> PhoneIssue? {
        let isMobile = phone.count == 10 && phone.first == "3" && phone.allSatisfy { $0.isASCII && $0.isNumber }
        return isMobile ? nil : .invalid
    }
}

enum PasswordChangeField: Hashable {
    case current
    case new
    case confirmation
}

enum NewPasswordIssue: Equatable {
    case missing
    case tooShort(minimum: Int)
    case tooLong(maximum: Int)
    case sameAsCurrent
}

struct PasswordChangeValidation: Equatable {
    var currentMissing = false
    var new: NewPasswordIssue?
    var confirmationMismatch = false

    var firstInvalidField: PasswordChangeField? {
        if currentMissing { return .current }
        if new != nil { return .new }
        if confirmationMismatch { return .confirmation }
        return nil
    }
}

/// Mismas reglas que al crear la cuenta (PasswordChange del backend) y una confirmación,
/// porque aún no existe recuperar la contraseña (SCRUM-3).
enum PasswordChangePolicy {
    static func validate(current: String, new: String, confirmation: String) -> PasswordChangeValidation {
        PasswordChangeValidation(
            currentMissing: current.isEmpty,
            new: newIssue(new, current: current),
            confirmationMismatch: !new.isEmpty && new != confirmation
        )
    }

    private static func newIssue(_ new: String, current: String) -> NewPasswordIssue? {
        let length = new.unicodeScalars.count
        let range = CredentialsPolicy.passwordLength
        if length == 0 { return .missing }
        if length < range.lowerBound { return .tooShort(minimum: range.lowerBound) }
        if length > range.upperBound { return .tooLong(maximum: range.upperBound) }
        if new == current { return .sameAsCurrent }
        return nil
    }
}

// MARK: - Resultados

/// Por qué no se pudo consultar o guardar. Ninguno cambia los datos guardados.
enum ProfileFailure: Error, Equatable {
    case offline
    /// La sesión ya no vale: hay que volver a iniciar sesión.
    case sessionExpired
    case wrongCurrentPassword
    /// Cuenta creada con Google: no tiene contraseña.
    case passwordNotSet
    /// El backend rechazó los datos (422) aunque pasaron la validación local.
    case rejected
    /// Error del servidor o backend no configurado.
    case server
}

enum ProfileSaveOutcome: Equatable {
    case saved(UserProfile)
    /// No había nada distinto que guardar; no se llama al backend.
    case unchanged
    case invalid(ProfileValidation)
    case failed(ProfileFailure)
}

enum PasswordChangeOutcome: Equatable {
    case changed
    case invalid(PasswordChangeValidation)
    case failed(ProfileFailure)
}

/// Personalizar Cuenta (SCRUM-6): consulta y guarda el perfil y cambia la contraseña.
/// Valida antes de enviar y anuncia por audio (AudioArbiter) el resultado o el error.
@MainActor
protocol ProfileManaging: AnyObject {
    func loadProfile() async -> Result<UserProfile, ProfileFailure>
    func saveProfile(displayName: String, phone: String) async -> ProfileSaveOutcome
    func changePassword(current: String, new: String, confirmation: String) async -> PasswordChangeOutcome
    /// SCRUM-62: abre Google y asocia esa cuenta a la de Lumio; lo anuncia por audio.
    func linkGoogle() async -> GoogleLinkOutcome
}

// MARK: - Textos

/// Lo que se muestra es lo mismo que se locuta.
enum ProfileAnnouncements {
    static let saved = "Cambios guardados."
    static let unchanged = "No hay cambios para guardar."
    static let passwordChanged = "Contraseña cambiada. Se cerró tu sesión en los demás dispositivos."
    static let sessionExpired = "Tu sesión expiró. Inicia sesión de nuevo."

    static func message(for issue: DisplayNameIssue) -> String {
        switch issue {
        case .tooLong(let maximum): "El nombre puede tener como máximo \(maximum) caracteres."
        case .invalidCharacters: "El nombre solo puede tener letras, espacios, apóstrofos, puntos y guiones."
        }
    }

    static func message(for issue: PhoneIssue) -> String {
        switch issue {
        case .invalid: "El celular debe tener 10 dígitos y empezar por 3."
        }
    }

    static func message(for issue: NewPasswordIssue) -> String {
        switch issue {
        case .missing: "Escribe la nueva contraseña."
        case .tooShort(let minimum): "La nueva contraseña debe tener al menos \(minimum) caracteres."
        case .tooLong(let maximum): "La nueva contraseña puede tener como máximo \(maximum) caracteres."
        case .sameAsCurrent: "La nueva contraseña debe ser distinta de la actual."
        }
    }

    static let currentPasswordMissing = "Escribe tu contraseña actual."
    static let confirmationMismatch = "Las contraseñas nuevas no coinciden."

    /// Todos los errores del perfil, en orden visual.
    static func messages(for validation: ProfileValidation) -> [String] {
        [validation.displayName.map(message(for:)), validation.phone.map(message(for:))].compactMap { $0 }
    }

    static func messages(for validation: PasswordChangeValidation) -> [String] {
        [
            validation.currentMissing ? currentPasswordMissing : nil,
            validation.new.map(message(for:)),
            validation.confirmationMismatch ? confirmationMismatch : nil,
        ].compactMap { $0 }
    }

    static func message(for failure: ProfileFailure, saving: String) -> String {
        switch failure {
        case .offline: "Sin conexión. No se pudo \(saving). Intenta de nuevo cuando tengas conexión."
        case .sessionExpired: sessionExpired
        case .wrongCurrentPassword: "La contraseña actual no es correcta. No se cambió la contraseña."
        case .passwordNotSet: "Tu cuenta no tiene contraseña porque usas Google para iniciar sesión."
        case .rejected: "No se pudo \(saving): el servidor rechazó los datos. Revísalos e intenta de nuevo."
        case .server: "No se pudo \(saving). Intenta de nuevo más tarde."
        }
    }

    static func loadFailed(_ failure: ProfileFailure) -> String { message(for: failure, saving: "consultar tu cuenta") }
    static func saveFailed(_ failure: ProfileFailure) -> String {
        message(for: failure, saving: "guardar los cambios") + (failure == .sessionExpired ? "" : " Tus datos siguen como estaban.")
    }
    static func passwordFailed(_ failure: ProfileFailure) -> String {
        message(for: failure, saving: "cambiar la contraseña")
    }

    static func invalidProfile(_ validation: ProfileValidation) -> String {
        "Revisa los datos. " + messages(for: validation).joined(separator: " ")
    }

    static func invalidPassword(_ validation: PasswordChangeValidation) -> String {
        "Revisa la contraseña. " + messages(for: validation).joined(separator: " ")
    }
}
