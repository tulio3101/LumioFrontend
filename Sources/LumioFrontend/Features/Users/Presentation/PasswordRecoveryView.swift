#if canImport(SwiftUI)
import SwiftUI

/// Recuperar Contraseña, desde «¿Olvidaste tu contraseña?» al iniciar sesión.
///
/// 1. Correo → «Enviar código». El aviso es el mismo exista o no la cuenta.
/// 2. Código de 6 dígitos (iOS lo puede sugerir desde el correo), nueva contraseña y
///    confirmación → «Restablecer contraseña». «Enviar otro código» y «Usar otro correo».
/// 3. Listo → «Iniciar sesión» vuelve al formulario con el correo ya escrito.
///
/// Los resultados los locuta PasswordRecoveryService por el AudioArbiter y se muestran en un
/// aviso; cada campo lleva su error en la pista de VoiceOver. No se mueve el foco para no
/// superponer VoiceOver con la voz de Lumio.
struct PasswordRecoveryView: View {
    @StateObject private var model: PasswordRecoveryViewModel
    @FocusState private var focusedField: Field?
    @Environment(\.dismiss) private var dismiss
    @State private var showsPasswords = false
    /// Contraseña restablecida: vuelve a iniciar sesión con este correo.
    private let onFinished: (String) -> Void

    private enum Field: Hashable {
        case email, code, newPassword, confirmation
    }

    init(service: any PasswordRecovering, email: String, onFinished: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: PasswordRecoveryViewModel(service: service, email: email))
        self.onFinished = onFinished
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let banner = model.banner {
                    LumioStatusBanner(status(for: banner.kind), title: banner.title, message: banner.message)
                }
                switch model.step {
                case .email: emailStep
                case .code: codeStep
                case .done: doneStep
                }
            }
            .disabled(model.isBusy)
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(LumioColor.background.ignoresSafeArea())
        .navigationTitle("Recuperar contraseña")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancelar") { dismiss() }
                    .accessibilityHint("Vuelve a iniciar sesión sin cambiar la contraseña.")
            }
        }
    }

    // MARK: Pasos

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading)
                .font(.title.weight(.bold))
                .foregroundStyle(LumioColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(subheading)
                .font(.body)
                .foregroundStyle(LumioColor.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            RecoveryInput(
                label: "Correo electrónico",
                error: model.emailIssue.map(PasswordRecoveryAnnouncements.message(for:)),
                isFocused: focusedField == .email
            ) {
                TextField("Correo electrónico", text: $model.email, prompt: Text("nombre@correo.com"))
                    .recoveryEmailInput()
                    .focused($focusedField, equals: .email)
                    .submitLabel(.send)
                    .onSubmit(requestCode)
            }
            primaryButton(model.isBusy ? "Enviando código…" : "Enviar código", action: requestCode)
                .accessibilityHint("Te enviamos un código de 6 dígitos a ese correo.")
            Text(PasswordRecoveryAnnouncements.googleNote)
                .font(.footnote)
                .foregroundStyle(LumioColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            RecoveryInput(
                label: "Código del correo",
                error: model.validation.code.map(PasswordRecoveryAnnouncements.message(for:)),
                hint: "6 dígitos. Enviado a \(CredentialsPolicy.normalizedEmail(model.email)).",
                isFocused: focusedField == .code
            ) {
                TextField("Código del correo", text: $model.code, prompt: Text("000000"))
                    .recoveryCodeInput()
                    .focused($focusedField, equals: .code)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .newPassword }
            }
            RecoveryInput(
                label: "Nueva contraseña",
                error: model.validation.newPassword.map(ProfileAnnouncements.message(for:)),
                hint: "Mínimo \(CredentialsPolicy.passwordLength.lowerBound) caracteres.",
                isFocused: focusedField == .newPassword
            ) {
                passwordField("Nueva contraseña", text: $model.newPassword, field: .newPassword)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .confirmation }
            }
            RecoveryInput(
                label: "Confirma la nueva contraseña",
                error: model.validation.confirmationMismatch ? "Las contraseñas nuevas no coinciden." : nil,
                isFocused: focusedField == .confirmation
            ) {
                passwordField("Confirma la nueva contraseña", text: $model.confirmation, field: .confirmation)
                    .submitLabel(.go)
                    .onSubmit(resetPassword)
            }
            Toggle("Mostrar contraseñas", isOn: $showsPasswords)
                .font(.subheadline)
            primaryButton(model.isBusy ? "Restableciendo…" : "Restablecer contraseña", action: resetPassword)
                .accessibilityHint("Cambia la contraseña y cierra la sesión en todos tus dispositivos.")
            Button("Enviar otro código") {
                focusedField = nil
                Task { await model.requestCode() }
            }
            .buttonStyle(LumioSecondaryButtonStyle())
            .accessibilityHint("El código anterior deja de servir. Espera un minuto entre envíos.")
            Button("Usar otro correo") {
                focusedField = nil
                model.changeEmail()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(LumioColor.actionPrimary)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private var doneStep: some View {
        primaryButton("Iniciar sesión") {
            onFinished(CredentialsPolicy.normalizedEmail(model.email))
        }
        .accessibilityHint("Vuelve a iniciar sesión con tu correo y la nueva contraseña.")
    }

    // MARK: Piezas

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if model.isBusy { ProgressView().tint(LumioColor.onActionPrimary) }
                Text(title)
            }
        }
        .buttonStyle(LumioPrimaryButtonStyle())
    }

    @ViewBuilder
    private func passwordField(_ title: String, text: Binding<String>, field: Field) -> some View {
        Group {
            if showsPasswords {
                TextField(title, text: text)
            } else {
                SecureField(title, text: text)
            }
        }
        .recoveryNewPasswordInput()
        .focused($focusedField, equals: field)
    }

    private var heading: String {
        switch model.step {
        case .email: "Recupera tu contraseña"
        case .code: "Escribe el código"
        case .done: "Listo"
        }
    }

    private var subheading: String {
        switch model.step {
        case .email: "Escribe el correo de tu cuenta y te enviaremos un código para crear una contraseña nueva."
        case .code: "Revisa tu correo. El código vence en 15 minutos y solo sirve el último que pediste."
        case .done: "Tu contraseña cambió. Inicia sesión con ella."
        }
    }

    private func status(for kind: PasswordRecoveryViewModel.Banner.Kind) -> LumioStatus {
        switch kind {
        case .success: .success
        case .info: .warning
        case .error: .error
        }
    }

    // MARK: Acciones

    private func requestCode() {
        focusedField = nil
        Task { await model.requestCode() }
    }

    private func resetPassword() {
        focusedField = nil
        Task { await model.resetPassword() }
    }
}

/// Etiqueta encima del campo y, debajo, el error (también en la pista de VoiceOver) o una ayuda.
private struct RecoveryInput<Field: View>: View {
    let label: String
    let error: String?
    var hint: String?
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
                .accessibilityHint(error ?? hint ?? "")
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
    func recoveryEmailInput() -> some View {
        #if os(iOS)
        keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.username)
        #else
        autocorrectionDisabled()
        #endif
    }

    /// oneTimeCode: iOS puede sugerir el código que llegó al correo.
    func recoveryCodeInput() -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
        #else
        autocorrectionDisabled()
        #endif
    }

    func recoveryNewPasswordInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.newPassword)
        #else
        autocorrectionDisabled()
        #endif
    }
}
#endif
