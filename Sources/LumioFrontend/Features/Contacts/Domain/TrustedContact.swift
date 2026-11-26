import Foundation

/// Persona que recibe por correo la alerta del botón de emergencia (Configurar Contactos de
/// Confianza, SCRUM-319). El backend guarda el correo en minúsculas.
struct TrustedContact: Identifiable, Equatable {
    let id: UUID
    var name: String
    var email: String
}

/// Nombre y correo ya normalizados: lo que se envía en POST y PUT /contacts.
struct ContactDraft: Equatable {
    let name: String
    let email: String
}

/// /contacts con la sesión actual.
protocol TrustedContactsRemoting {
    func listContacts() async throws -> [TrustedContact]
    func addContact(_ draft: ContactDraft) async throws -> TrustedContact
    func updateContact(id: UUID, _ draft: ContactDraft) async throws -> TrustedContact
    func deleteContact(id: UUID) async throws
}

// MARK: - Validación

enum ContactField: Hashable {
    case name
    case email
}

enum ContactNameIssue: Equatable {
    case missing
    case tooLong(maximum: Int)
    case invalidCharacters
}

enum ContactEmailIssue: Equatable {
    case missing
    case invalidFormat
    /// Otro contacto de la lista ya tiene ese correo.
    case duplicate(ofName: String)
}

struct ContactValidation: Equatable {
    var name: ContactNameIssue?
    var email: ContactEmailIssue?

    /// En orden visual, para llevar el foco al primer campo que hay que corregir.
    var firstInvalidField: ContactField? {
        if name != nil { return .name }
        if email != nil { return .email }
        return nil
    }
}

/// Reglas locales previas al envío. Reflejan TrustedContactWrite y el servicio de contactos
/// del backend, que sigue siendo la autoridad: solo evitan envíos que rechazaría con
/// seguridad. Lo que la app no puede saber (que el correo sea el de la propia cuenta) lo
/// decide el servidor.
enum ContactsPolicy {
    /// Igual que MAX_CONTACTS_PER_USER del backend.
    static let maximumContacts = 5

    /// Nombre compuesto (NFC), con espacios recortados y unidos; nil si queda vacío.
    static func normalizedName(_ name: String) -> String? {
        ProfilePolicy.normalizedDisplayName(name)
    }

    /// Sin espacios laterales y en minúsculas, como lo guarda el backend.
    static func normalizedEmail(_ email: String) -> String {
        CredentialsPolicy.normalizedEmail(email).lowercased()
    }

    static func draft(name: String, email: String) -> ContactDraft {
        ContactDraft(name: normalizedName(name) ?? "", email: normalizedEmail(email))
    }

    /// `editing` es el contacto que se está editando: su propio correo no cuenta como repetido.
    static func validate(
        name: String, email: String, existing: [TrustedContact], editing: TrustedContact? = nil
    ) -> ContactValidation {
        let draft = draft(name: name, email: email)
        return ContactValidation(
            name: nameIssue(draft.name),
            email: emailIssue(draft.email, existing: existing, editing: editing)
        )
    }

    /// Agregar uno más pasaría del máximo.
    static func isFull(_ existing: [TrustedContact]) -> Bool {
        existing.count >= maximumContacts
    }

    private static func nameIssue(_ name: String) -> ContactNameIssue? {
        if name.isEmpty { return .missing }
        switch ProfilePolicy.displayNameIssue(name) {
        case .tooLong(let maximum): return .tooLong(maximum: maximum)
        case .invalidCharacters: return .invalidCharacters
        case nil: return nil
        }
    }

    private static func emailIssue(
        _ email: String, existing: [TrustedContact], editing: TrustedContact?
    ) -> ContactEmailIssue? {
        switch CredentialsPolicy.emailIssue(email) {
        case .missing: return .missing
        case .invalidFormat: return .invalidFormat
        case nil: break
        }
        let other = existing.first { $0.id != editing?.id && $0.email.lowercased() == email }
        return other.map { .duplicate(ofName: $0.name) }
    }
}

// MARK: - Resultados

/// Por qué no se pudo consultar, guardar o eliminar. Ninguno cambia los contactos guardados.
enum ContactFailure: Error, Equatable {
    case offline
    /// La sesión ya no vale: hay que volver a iniciar sesión.
    case sessionExpired
    /// 409: el correo ya está en la lista o ya hay el máximo (otro dispositivo pudo cambiarla).
    case conflict
    /// 422: el servidor rechazó los datos aunque pasaron la validación local, por ejemplo
    /// porque el correo es el de la propia cuenta.
    case rejected
    /// 404: el contacto ya no existe (se eliminó desde otro dispositivo).
    case notFound
    /// Error del servidor o backend no configurado.
    case server
}

enum ContactSaveOutcome: Equatable {
    case saved(TrustedContact)
    /// Editar sin cambiar nada: no se llama al backend.
    case unchanged
    case invalid(ContactValidation)
    /// Ya hay el máximo de contactos: no se llama al backend.
    case limitReached
    case failed(ContactFailure)
}

enum ContactDeleteOutcome: Equatable {
    case deleted
    case failed(ContactFailure)
}

/// Configurar Contactos de Confianza (SCRUM-319): consulta, agrega, edita y elimina contactos.
/// Valida antes de enviar y anuncia por audio (AudioArbiter) cada resultado o error.
@MainActor
protocol TrustedContactsManaging: AnyObject {
    /// Los contactos guardados en el backend, en el orden en que se agregaron.
    func loadContacts() async -> Result<[TrustedContact], ContactFailure>
    func addContact(name: String, email: String) async -> ContactSaveOutcome
    func updateContact(_ contact: TrustedContact, name: String, email: String) async -> ContactSaveOutcome
    func deleteContact(_ contact: TrustedContact) async -> ContactDeleteOutcome
    /// Los contactos tal como están guardados ahora, sin consultar el backend.
    var contacts: [TrustedContact] { get }
}

// MARK: - Textos

/// Lo que se muestra es lo mismo que se locuta.
enum ContactAnnouncements {
    static let sessionExpired = "Tu sesión expiró. Inicia sesión de nuevo."
    static let unchanged = "No hay cambios para guardar."
    static let noContacts = "Aún no tienes contactos de confianza."

    static func saved(_ contact: TrustedContact) -> String {
        "Contacto guardado: \(contact.name), \(contact.email)."
    }

    static func updated(_ contact: TrustedContact) -> String {
        "Contacto actualizado: \(contact.name), \(contact.email)."
    }

    static func deleted(_ contact: TrustedContact) -> String {
        "Contacto eliminado: \(contact.name)."
    }

    static let limitReached =
        "Ya tienes \(ContactsPolicy.maximumContacts) contactos de confianza, que es el máximo. "
        + "Elimina uno para agregar otro."

    static func message(for issue: ContactNameIssue) -> String {
        switch issue {
        case .missing: "Escribe el nombre del contacto."
        case .tooLong(let maximum): "El nombre puede tener como máximo \(maximum) caracteres."
        case .invalidCharacters: "El nombre solo puede tener letras, espacios, apóstrofos, puntos y guiones."
        }
    }

    static func message(for issue: ContactEmailIssue) -> String {
        switch issue {
        case .missing: "Escribe el correo del contacto."
        case .invalidFormat: "El correo no es válido. Revisa que tenga el formato nombre@dominio.com."
        case .duplicate(let name): "Ese correo ya es de tu contacto \(name)."
        }
    }

    /// Todos los errores del contacto, en orden visual.
    static func messages(for validation: ContactValidation) -> [String] {
        [validation.name.map(message(for:)), validation.email.map(message(for:))].compactMap { $0 }
    }

    static func invalid(_ validation: ContactValidation) -> String {
        "No se guardó el contacto. " + messages(for: validation).joined(separator: " ")
    }

    /// `doing` es la acción en infinitivo: «guardar el contacto», «eliminar el contacto».
    static func message(for failure: ContactFailure, doing: String) -> String {
        switch failure {
        case .offline: "Sin conexión. No se pudo \(doing). Intenta de nuevo cuando tengas conexión."
        case .sessionExpired: sessionExpired
        case .conflict:
            "No se pudo \(doing): ese correo ya está en tu lista o ya tienes "
                + "\(ContactsPolicy.maximumContacts) contactos."
        case .rejected:
            "No se pudo \(doing): el servidor no aceptó los datos. Revisa el nombre y el correo, "
                + "y que no sea tu propio correo."
        case .notFound: "No se pudo \(doing): ese contacto ya no existe."
        case .server: "No se pudo \(doing). Intenta de nuevo más tarde."
        }
    }

    static func loadFailed(_ failure: ContactFailure) -> String {
        message(for: failure, doing: "consultar tus contactos")
    }

    static func saveFailed(_ failure: ContactFailure) -> String {
        message(for: failure, doing: "guardar el contacto") + (failure == .sessionExpired ? "" : " Tus contactos siguen como estaban.")
    }

    static func deleteFailed(_ failure: ContactFailure) -> String {
        message(for: failure, doing: "eliminar el contacto") + (failure == .sessionExpired ? "" : " Sigue en tu lista.")
    }

    /// Lo que VoiceOver dice de cada fila de la lista.
    static func summary(of contact: TrustedContact) -> String {
        "\(contact.name), \(contact.email)"
    }
}
