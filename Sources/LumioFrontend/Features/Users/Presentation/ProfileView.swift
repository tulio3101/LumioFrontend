#if canImport(SwiftUI)
import SwiftUI

/// Personalizar Cuenta (SCRUM-6), en Preferencias > Mi cuenta. Muestra el correo (no
/// editable), el nombre y el celular, y permite cambiar la contraseña.
///
/// Los resultados y errores los locuta ProfileService por el AudioArbiter y además se
/// muestran en un aviso. Cada campo lleva su error en la pista de VoiceOver; no se mueve
/// el foco para no superponer la voz de VoiceOver con la del árbitro.
struct ProfileView: View {
    @StateObject private var model: ProfileViewModel
    @FocusState private var focusedField: Field?
    @State private var showsPasswords = false

    private enum Field: Hashable {
        case displayName, phone, current, new, confirmation
    }

    init(service: any ProfileManaging, onSessionExpired: @escaping () -> Void) {
        _model = StateObject(wrappedValue: ProfileViewModel(service: service, onSessionExpired: onSessionExpired))
    }

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(LumioColor.background.ignoresSafeArea())
        .navigationTitle("Mi cuenta")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .loading:
            ProgressView("Consultando tu cuenta…")
                .frame(maxWidth: .infinity, minHeight: 200)
        case .failed(let failure):
            VStack(spacing: 16) {
                LumioStatusBanner(
                    .error, title: "No se pudo consultar tu cuenta", message: ProfileAnnouncements.loadFailed(failure)
                )
                Button("Intentar de nuevo") { Task { await model.load() } }
                    .buttonStyle(LumioPrimaryButtonStyle())
            }
        case .loaded:
            VStack(alignment: .leading, spacing: 32) {
                profileSection
                passwordSection
            }
            .disabled(model.isBusy)
        }
    }

    // MARK: Perfil

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Tus datos", subtitle: "Tu nombre y tu celular son opcionales.")

            VStack(alignment: .leading, spacing: 6) {
                Text("Correo electrónico")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumioColor.textPrimary)
                Text(model.email)
                    .font(.body)
                    .foregroundStyle(LumioColor.textPrimary)
                Text("Con él inicias sesión. No se puede cambiar.")
                    .font(.footnote)
                    .foregroundStyle(LumioColor.textSecondary)
            }
            .accessibilityElement(children: .combine)

            ProfileInput(
                label: "Nombre",
                error: model.profileValidation.displayName.map(ProfileAnnouncements.message(for:)),
                hint: "Hasta \(ProfilePolicy.displayNameMaxLength) caracteres.",
                isFocused: focusedField == .displayName
            ) {
                TextField("Nombre", text: $model.displayName, prompt: Text("Cómo quieres que te llamemos"))
                    .nameInput()
                    .focused($focusedField, equals: .displayName)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .phone }
            }

            ProfileInput(
                label: "Celular",
                error: model.profileValidation.phone.map(ProfileAnnouncements.message(for:)),
                hint: "10 dígitos, empieza por 3. Ejemplo: 300 123 4567.",
                isFocused: focusedField == .phone
            ) {
                TextField("Celular", text: $model.phone, prompt: Text("300 123 4567"))
                    .phoneInput()
                    .focused($focusedField, equals: .phone)
            }

            if let banner = model.profileBanner {
                LumioStatusBanner(banner.status, title: banner.title, message: banner.message)
            }

            Button {
                focusedField = nil
                Task { await model.save() }
            } label: {
                HStack(spacing: 10) {
                    if model.isSaving { ProgressView().tint(LumioColor.onActionPrimary) }
                    Text(model.isSaving ? "Guardando…" : "Guardar cambios")
                }
            }
            .buttonStyle(LumioPrimaryButtonStyle())
            .accessibilityHint("Valida tu nombre y tu celular y los guarda.")
        }
    }

    // MARK: Contraseña

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(
                "Cambiar contraseña",
                subtitle: "Se cerrará tu sesión en los demás dispositivos. En este sigues conectado."
            )

            ProfileInput(
                label: "Contraseña actual",
                error: model.passwordValidation.currentMissing ? ProfileAnnouncements.currentPasswordMissing : nil,
                hint: nil,
                isFocused: focusedField == .current
            ) {
                passwordField("Contraseña actual", text: $model.currentPassword, isNew: false, field: .current)
            }

            ProfileInput(
                label: "Nueva contraseña",
                error: model.passwordValidation.new.map(ProfileAnnouncements.message(for:)),
                hint: "Mínimo \(CredentialsPolicy.passwordLength.lowerBound) caracteres.",
                isFocused: focusedField == .new
            ) {
                passwordField("Nueva contraseña", text: $model.newPassword, isNew: true, field: .new)
            }

            ProfileInput(
                label: "Repite la nueva contraseña",
                error: model.passwordValidation.confirmationMismatch ? ProfileAnnouncements.confirmationMismatch : nil,
                hint: nil,
                isFocused: focusedField == .confirmation
            ) {
                passwordField("Repite la nueva contraseña", text: $model.confirmation, isNew: true, field: .confirmation)
            }

            Toggle("Mostrar contraseñas", isOn: $showsPasswords)
                .tint(LumioColor.actionPrimary)

            if let banner = model.passwordBanner {
                LumioStatusBanner(banner.status, title: banner.title, message: banner.message)
            }

            Button {
                focusedField = nil
                Task { await model.changePassword() }
            } label: {
                HStack(spacing: 10) {
                    if model.isChangingPassword { ProgressView().tint(LumioColor.actionPrimary) }
                    Text(model.isChangingPassword ? "Cambiando contraseña…" : "Cambiar contraseña")
                }
            }
            .buttonStyle(LumioSecondaryButtonStyle())
            .accessibilityHint("Comprueba tu contraseña actual y la reemplaza por la nueva.")
        }
    }

    @ViewBuilder
    private func passwordField(_ title: String, text: Binding<String>, isNew: Bool, field: Field) -> some View {
        Group {
            if showsPasswords {
                TextField(title, text: text)
            } else {
                SecureField(title, text: text)
            }
        }
        .secretInput(isNew: isNew)
        .focused($focusedField, equals: field)
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(LumioColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(LumioColor.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Componentes

/// Etiqueta visible encima del campo y, debajo, el error o la ayuda. VoiceOver lee la
/// etiqueta como nombre del campo y el error (o la ayuda) como pista.
private struct ProfileInput<Field: View>: View {
    let label: String
    let error: String?
    let hint: String?
    let isFocused: Bool
    @ViewBuilder let field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LumioColor.textPrimary)
                .accessibilityHidden(true)
            field
                .font(.body)
                .foregroundStyle(LumioColor.textPrimary)
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .background(LumioColor.surface, in: shape)
                .overlay(shape.strokeBorder(borderColor, lineWidth: isFocused || error != nil ? 2 : 1))
                .accessibilityLabel(label)
                .accessibilityHint(error.map { "Error: \($0)" } ?? hint ?? "")
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(LumioColor.errorText)
                    .accessibilityHidden(true)
            } else if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(LumioColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var borderColor: Color {
        if error != nil { return LumioColor.errorText }
        return isFocused ? LumioColor.actionPrimary : LumioColor.controlBorder
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }
}

private extension View {
    func nameInput() -> some View {
        #if os(iOS)
        textContentType(.name)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }

    func phoneInput() -> some View {
        #if os(iOS)
        keyboardType(.phonePad)
            .textContentType(.telephoneNumber)
        #else
        self
        #endif
    }

    func secretInput(isNew: Bool) -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(isNew ? .newPassword : .password)
        #else
        autocorrectionDisabled()
        #endif
    }
}
#endif
