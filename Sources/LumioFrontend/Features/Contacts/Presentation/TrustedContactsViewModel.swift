#if canImport(SwiftUI)
import SwiftUI

/// Estado de la pantalla Contactos de confianza (lista, formulario de agregar y editar, y
/// confirmación de eliminar). La validación, el envío y el audio los hace
/// TrustedContactsService; aquí solo se reflejan en la pantalla. Como en Mi cuenta, los
/// errores de campo aparecen tras el primer intento y desde entonces se actualizan al escribir.
@MainActor
final class TrustedContactsViewModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(ContactFailure)
    }

    struct Banner: Equatable {
        let status: LumioStatus
        let title: String
        let message: String
    }

    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var contacts: [TrustedContact] = []
    /// Resultado de la última acción sobre la lista (guardar, eliminar).
    @Published private(set) var listBanner: Banner?
    @Published private(set) var isDeleting = false

    // Formulario. `editing` es nil al agregar.
    @Published private(set) var editing: TrustedContact?
    @Published var isFormPresented = false
    @Published var name = "" { didSet { refreshValidation() } }
    @Published var email = "" { didSet { refreshValidation() } }
    @Published private(set) var validation = ContactValidation()
    @Published private(set) var formBanner: Banner?
    @Published private(set) var isSaving = false

    /// Contacto que espera la confirmación de «Eliminar».
    @Published var pendingDeletion: TrustedContact?

    private var attemptedSave = false
    private let service: any TrustedContactsManaging
    private let onSessionExpired: () -> Void

    init(service: any TrustedContactsManaging, onSessionExpired: @escaping () -> Void) {
        self.service = service
        self.onSessionExpired = onSessionExpired
    }

    var isBusy: Bool { isSaving || isDeleting }
    var isEditing: Bool { editing != nil }
    var isFull: Bool { ContactsPolicy.isFull(contacts) }

    // MARK: Lista

    func load() async {
        loadState = .loading
        switch await service.loadContacts() {
        case .success(let loaded):
            contacts = loaded
            loadState = .loaded
        case .failure(.sessionExpired):
            onSessionExpired()
        case .failure(let failure):
            loadState = .failed(failure)
        }
    }

    // MARK: Formulario

    func beginAdd() {
        // Antes de escribir nada: con el máximo no se abre el formulario.
        guard !isFull else {
            listBanner = Banner(
                status: .warning, title: "Máximo de contactos", message: ContactAnnouncements.limitReached
            )
            announceForAccessibility(ContactAnnouncements.limitReached)
            return
        }
        present(editing: nil, name: "", email: "")
    }

    func beginEdit(_ contact: TrustedContact) {
        present(editing: contact, name: contact.name, email: contact.email)
    }

    private func present(editing contact: TrustedContact?, name: String, email: String) {
        attemptedSave = false
        editing = contact
        self.name = name
        self.email = email
        validation = ContactValidation()
        formBanner = nil
        listBanner = nil
        isFormPresented = true
    }

    func save() async {
        guard !isBusy else { return }
        attemptedSave = true
        isSaving = true
        defer { isSaving = false }
        let outcome: ContactSaveOutcome
        if let editing {
            outcome = await service.updateContact(editing, name: name, email: email)
        } else {
            outcome = await service.addContact(name: name, email: email)
        }
        switch outcome {
        case .saved(let saved):
            contacts = service.contacts
            listBanner = Banner(
                status: .success,
                title: isEditing ? "Contacto actualizado" : "Contacto guardado",
                message: ContactAnnouncements.summary(of: saved)
            )
            isFormPresented = false
        case .unchanged:
            formBanner = Banner(
                status: .warning, title: ContactAnnouncements.unchanged, message: "Modifica el nombre o el correo."
            )
        case .invalid(let validation):
            self.validation = validation
            formBanner = Banner(
                status: .error, title: "Revisa los datos",
                message: ContactAnnouncements.messages(for: validation).joined(separator: " ")
            )
        case .limitReached:
            formBanner = Banner(
                status: .error, title: "Máximo de contactos", message: ContactAnnouncements.limitReached
            )
        case .failed(.sessionExpired):
            onSessionExpired()
        case .failed(let failure):
            // Si ya no existía (otro dispositivo lo eliminó), la lista debe dejar de mostrarlo.
            if failure == .notFound { contacts = service.contacts }
            formBanner = Banner(
                status: .error, title: "No se guardó el contacto", message: ContactAnnouncements.saveFailed(failure)
            )
        }
    }

    // MARK: Eliminar

    func requestDeletion(of contact: TrustedContact) {
        guard !isBusy else { return }
        pendingDeletion = contact
    }

    func confirmDeletion(of contact: TrustedContact) async {
        guard !isBusy else { return }
        isDeleting = true
        defer { isDeleting = false }
        switch await service.deleteContact(contact) {
        case .deleted:
            contacts = service.contacts
            listBanner = Banner(
                status: .success, title: "Contacto eliminado", message: "\(contact.name) ya no recibirá tus alertas."
            )
        case .failed(.sessionExpired):
            onSessionExpired()
        case .failed(let failure):
            contacts = service.contacts
            listBanner = Banner(
                status: .error, title: "No se eliminó el contacto", message: ContactAnnouncements.deleteFailed(failure)
            )
        }
    }

    private func refreshValidation() {
        guard attemptedSave else { return }
        validation = ContactsPolicy.validate(name: name, email: email, existing: contacts, editing: editing)
    }
}
#endif
