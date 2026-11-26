import Foundation

/// Configurar Contactos de Confianza (SCRUM-319):
///
/// 1. Consulta los contactos del backend; siguen ahí al volver a iniciar sesión. Si falla,
///    lo anuncia.
/// 2. Agregar y editar validan primero en el teléfono (nombre, formato del correo, correo
///    repetido y máximo de 5); con errores no se envía nada y se locutan. Editar sin cambiar
///    nada tampoco envía.
/// 3. POST, PUT y DELETE /contacts; cada resultado, bueno o malo, se anuncia por audio y un
///    fallo deja la lista como estaba.
///
/// Todo se anuncia por el AudioArbiter (contexto `trusted-contacts`).
@MainActor
final class TrustedContactsService: TrustedContactsManaging {
    static let contextID = "trusted-contacts"

    private let remote: any TrustedContactsRemoting
    /// Se borran si la sesión ya no vale, para que la app vuelva a pedir iniciar sesión.
    private let tokens: (any TokenStoring)?
    private let arbiter: (any AudioArbitrating)?
    private let now: () -> Date
    /// Lo último que se sabe guardado en el backend, para validar repetidos y el máximo.
    private(set) var contacts: [TrustedContact] = []

    init(
        remote: any TrustedContactsRemoting,
        tokens: (any TokenStoring)? = nil,
        arbiter: (any AudioArbitrating)?,
        now: @escaping () -> Date = Date.init
    ) {
        self.remote = remote
        self.tokens = tokens
        self.arbiter = arbiter
        self.now = now
    }

    func loadContacts() async -> Result<[TrustedContact], ContactFailure> {
        do {
            contacts = try await remote.listContacts()
            return .success(contacts)
        } catch {
            let failure = handle(error)
            speak(ContactAnnouncements.loadFailed(failure), key: "load-failed")
            return .failure(failure)
        }
    }

    func addContact(name: String, email: String) async -> ContactSaveOutcome {
        let validation = ContactsPolicy.validate(name: name, email: email, existing: contacts)
        guard validation.firstInvalidField == nil else {
            speak(ContactAnnouncements.invalid(validation), key: "invalid")
            return .invalid(validation)
        }
        guard !ContactsPolicy.isFull(contacts) else {
            speak(ContactAnnouncements.limitReached, key: "limit-reached")
            return .limitReached
        }
        do {
            let saved = try await remote.addContact(ContactsPolicy.draft(name: name, email: email))
            contacts.append(saved)
            speak(ContactAnnouncements.saved(saved), key: "saved")
            return .saved(saved)
        } catch {
            let failure = handle(error)
            speak(ContactAnnouncements.saveFailed(failure), key: "save-failed")
            return .failed(failure)
        }
    }

    func updateContact(_ contact: TrustedContact, name: String, email: String) async -> ContactSaveOutcome {
        let validation = ContactsPolicy.validate(name: name, email: email, existing: contacts, editing: contact)
        guard validation.firstInvalidField == nil else {
            speak(ContactAnnouncements.invalid(validation), key: "invalid")
            return .invalid(validation)
        }
        let draft = ContactsPolicy.draft(name: name, email: email)
        if draft.name == contact.name, draft.email == contact.email.lowercased() {
            speak(ContactAnnouncements.unchanged, key: "unchanged")
            return .unchanged
        }
        do {
            let saved = try await remote.updateContact(id: contact.id, draft)
            if let index = contacts.firstIndex(where: { $0.id == saved.id }) {
                contacts[index] = saved
            }
            speak(ContactAnnouncements.updated(saved), key: "updated")
            return .saved(saved)
        } catch {
            let failure = handle(error)
            speak(ContactAnnouncements.saveFailed(failure), key: "save-failed")
            return .failed(failure)
        }
    }

    func deleteContact(_ contact: TrustedContact) async -> ContactDeleteOutcome {
        do {
            try await remote.deleteContact(id: contact.id)
            contacts.removeAll { $0.id == contact.id }
            speak(ContactAnnouncements.deleted(contact), key: "deleted")
            return .deleted
        } catch {
            let failure = handle(error)
            // Si ya no existía, la lista local debe dejar de mostrarlo.
            if failure == .notFound { contacts.removeAll { $0.id == contact.id } }
            speak(ContactAnnouncements.deleteFailed(failure), key: "delete-failed")
            return .failed(failure)
        }
    }

    private func handle(_ error: Error) -> ContactFailure {
        let failure = Self.failure(for: error)
        if failure == .sessionExpired { tokens?.clear() }
        return failure
    }

    /// Un mensaje nuevo reemplaza al anterior del mismo flujo.
    private func speak(_ text: String, key: String) {
        guard let arbiter else { return }
        arbiter.cancel(contextIDs: [Self.contextID])
        arbiter.receive(AudioMessage(
            text: text,
            priority: .routeInformation,
            createdAt: now(),
            contextID: Self.contextID,
            deduplicationKey: key
        ))
    }

    nonisolated static func failure(for error: Error) -> ContactFailure {
        switch error {
        case AuthenticationError.sessionExpired, AuthenticationError.notSignedIn,
             HTTPClientError.statusCode(401):
            return .sessionExpired
        case HTTPClientError.statusCode(404):
            return .notFound
        case HTTPClientError.statusCode(409):
            return .conflict
        case HTTPClientError.statusCode(422):
            return .rejected
        case let error as URLError where error.isConnectivityFailure:
            return .offline
        default:
            return .server
        }
    }
}
