#if canImport(SwiftUI)
import SwiftUI

/// Configurar Contactos de Confianza (SCRUM-319), en Preferencias > Contactos de confianza.
/// Lista los contactos que recibirán por correo la alerta de emergencia y permite agregar,
/// editar y eliminar.
///
/// Accesibilidad con VoiceOver: cada contacto es un elemento con su nombre y correo, seguido de
/// sus botones «Editar a …» y «Eliminar a …», que nombran al contacto. Eliminar pide
/// confirmación. Los resultados y errores los locuta TrustedContactsService por el AudioArbiter
/// y además se muestran en un aviso; no se mueve el foco para no superponer la voz de
/// VoiceOver con la del árbitro.
struct TrustedContactsView: View {
    @StateObject private var model: TrustedContactsViewModel

    init(service: any TrustedContactsManaging, onSessionExpired: @escaping () -> Void) {
        _model = StateObject(wrappedValue: TrustedContactsViewModel(
            service: service, onSessionExpired: onSessionExpired
        ))
    }

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
        }
        .background(LumioColor.background.ignoresSafeArea())
        .navigationTitle("Contactos de confianza")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.load() }
        .navigationDestination(isPresented: $model.isFormPresented) {
            TrustedContactFormView(model: model)
        }
        // Prevención de errores: eliminar no se puede deshacer.
        .confirmationDialog(
            "¿Eliminar contacto?",
            isPresented: Binding(
                get: { model.pendingDeletion != nil },
                set: { if !$0 { model.pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingDeletion
        ) { contact in
            Button("Eliminar a \(contact.name)", role: .destructive) {
                Task { await model.confirmDeletion(of: contact) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { contact in
            Text("\(contact.name) dejará de recibir tus alertas de emergencia.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .loading:
            ProgressView("Consultando tus contactos…")
                .frame(maxWidth: .infinity, minHeight: 200)
        case .failed(let failure):
            VStack(spacing: 16) {
                LumioStatusBanner(
                    .error, title: "No se pudieron consultar tus contactos",
                    message: ContactAnnouncements.loadFailed(failure)
                )
                Button("Intentar de nuevo") { Task { await model.load() } }
                    .buttonStyle(LumioPrimaryButtonStyle())
            }
        case .loaded:
            VStack(alignment: .leading, spacing: 24) {
                header
                if let banner = model.listBanner {
                    LumioStatusBanner(banner.status, title: banner.title, message: banner.message)
                }
                contactList
                Button {
                    model.beginAdd()
                } label: {
                    Label("Agregar contacto", systemImage: "person.badge.plus")
                }
                .buttonStyle(LumioPrimaryButtonStyle())
                .accessibilityHint(
                    model.isFull
                        ? "Ya tienes el máximo de \(ContactsPolicy.maximumContacts) contactos."
                        : "Abre el formulario para escribir el nombre y el correo."
                )
            }
            .disabled(model.isBusy)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tus contactos")
                .font(.title3.bold())
                .foregroundStyle(LumioColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(
                "Recibirán un correo con tu alerta cuando uses el botón de emergencia. "
                    + "Puedes tener hasta \(ContactsPolicy.maximumContacts)."
            )
            .font(.subheadline)
            .foregroundStyle(LumioColor.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var contactList: some View {
        if model.contacts.isEmpty {
            Text(ContactAnnouncements.noContacts)
                .font(.body)
                .foregroundStyle(LumioColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 12) {
                ForEach(model.contacts) { contact in
                    ContactRow(
                        contact: contact,
                        onEdit: { model.beginEdit(contact) },
                        onDelete: { model.requestDeletion(of: contact) }
                    )
                }
            }
        }
    }
}

/// Un contacto: su nombre y correo se leen juntos y los botones dicen a quién afectan.
private struct ContactRow: View {
    let contact: TrustedContact
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name)
                    .font(.headline)
                    .foregroundStyle(LumioColor.textPrimary)
                Text(contact.email)
                    .font(.subheadline)
                    .foregroundStyle(LumioColor.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ContactAnnouncements.summary(of: contact))

            HStack(spacing: 12) {
                Button(action: onEdit) {
                    Label("Editar", systemImage: "pencil")
                }
                .buttonStyle(LumioSecondaryButtonStyle())
                .accessibilityLabel("Editar a \(contact.name)")

                Button(role: .destructive, action: onDelete) {
                    Label("Eliminar", systemImage: "trash")
                }
                .buttonStyle(LumioSecondaryButtonStyle())
                .accessibilityLabel("Eliminar a \(contact.name)")
                .accessibilityHint("Pide confirmación antes de eliminarlo.")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LumioColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Formulario de agregar y editar. Se abre como pantalla de la misma navegación, no como hoja,
/// para que VoiceOver tenga el botón «Atrás» y el título de la pantalla.
private struct TrustedContactFormView: View {
    @ObservedObject var model: TrustedContactsViewModel
    @FocusState private var focusedField: ContactField?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(model.isEditing ? "Editar contacto" : "Nuevo contacto")
                    .font(.title3.bold())
                    .foregroundStyle(LumioColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                ProfileInput(
                    label: "Nombre",
                    error: model.validation.name.map(ContactAnnouncements.message(for:)),
                    hint: "Hasta \(ProfilePolicy.displayNameMaxLength) caracteres.",
                    isFocused: focusedField == .name
                ) {
                    TextField("Nombre", text: $model.name, prompt: Text("Cómo se llama tu contacto"))
                        .contactNameInput()
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .email }
                }

                ProfileInput(
                    label: "Correo electrónico",
                    error: model.validation.email.map(ContactAnnouncements.message(for:)),
                    hint: "Ejemplo: maria@correo.com. Aquí le llegará tu alerta.",
                    isFocused: focusedField == .email
                ) {
                    TextField("Correo electrónico", text: $model.email, prompt: Text("nombre@correo.com"))
                        .contactEmailInput()
                        .focused($focusedField, equals: .email)
                        .submitLabel(.done)
                        .onSubmit { save() }
                }

                if let banner = model.formBanner {
                    LumioStatusBanner(banner.status, title: banner.title, message: banner.message)
                }

                Button(action: save) {
                    HStack(spacing: 10) {
                        if model.isSaving { ProgressView().tint(LumioColor.onActionPrimary) }
                        Text(model.isSaving ? "Guardando…" : "Guardar contacto")
                    }
                }
                .buttonStyle(LumioPrimaryButtonStyle())
                .accessibilityHint("Valida el nombre y el correo y guarda el contacto.")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .disabled(model.isSaving)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(LumioColor.background.ignoresSafeArea())
        .navigationTitle(model.isEditing ? "Editar contacto" : "Agregar contacto")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func save() {
        focusedField = nil
        Task { await model.save() }
    }
}

private extension View {
    func contactNameInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.words)
            .autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }

    func contactEmailInput() -> some View {
        #if os(iOS)
        keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }
}
#endif
