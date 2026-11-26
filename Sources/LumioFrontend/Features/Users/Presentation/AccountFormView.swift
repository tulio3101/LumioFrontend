#if canImport(SwiftUI)
import SwiftUI

/// Crear cuenta o iniciar sesión, con Google o con correo y contraseña. El enlace inferior
/// cambia de modo en la misma pantalla: solo se animan los textos que cambian.
struct AccountFormView: View {
    @StateObject private var model: AccountFormViewModel
    @FocusState private var focusedField: CredentialsField?
    @AccessibilityFocusState private var headingHasVoiceOverFocus: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsPassword = false
    /// Solo en DEBUG: permite al equipo entrar a la app mientras no exista autenticación.
    private let continueWithoutSession: (() -> Void)?
    /// Recuperar Contraseña: solo al iniciar sesión con correo (Google no usa contraseña de Lumio).
    private let passwordRecovery: (any PasswordRecovering)?
    @State private var showsRecovery = false

    private static let topID = "top"

    init(
        access: AccountAccess,
        service: any Authenticating,
        onAuthenticated: @escaping () -> Void,
        continueWithoutSession: (() -> Void)?,
        passwordRecovery: (any PasswordRecovering)? = nil
    ) {
        self.passwordRecovery = passwordRecovery
        _model = StateObject(wrappedValue: AccountFormViewModel(
            access: access,
            service: service,
            onAuthenticated: onAuthenticated
        ))
        self.continueWithoutSession = continueWithoutSession
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                form(scroll: scroll)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(LumioColor.background.ignoresSafeArea())
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        #endif
        .onChange(of: model.failure) { failure in
            if let failure, !failure.isAnnouncedByAudio {
                announceForAccessibility("\(failure.title). \(failure.message)")
            }
        }
        .sheet(isPresented: $showsRecovery) {
            if let passwordRecovery {
                NavigationStack {
                    PasswordRecoveryView(service: passwordRecovery, email: model.email) { email in
                        // Vuelve a iniciar sesión con el correo ya escrito y la contraseña nueva.
                        model.email = email
                        model.password = ""
                        showsRecovery = false
                        focusedField = .password
                    }
                }
            }
        }
    }

    private func form(scroll: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            header.id(Self.topID)
            VStack(spacing: 20) {
                GoogleSignInButton(isLoading: model.operation == .google) {
                    focusedField = nil
                    Task { await model.signInWithGoogle() }
                }
                emailDivider
            }
            VStack(spacing: 20) {
                emailField
                passwordField
                if model.access == .signIn, passwordRecovery != nil {
                    Button("¿Olvidaste tu contraseña?") {
                        focusedField = nil
                        showsRecovery = true
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumioColor.actionPrimary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
                    .accessibilityHint("Te enviamos un código a tu correo para crear una contraseña nueva.")
                }
            }
            if let failure = model.failure {
                FailureBanner(
                    failure: failure,
                    continueWithoutSession: failure.isServiceUnavailable ? continueWithoutSession : nil
                )
                .transition(.opacity)
            }
            submitButton
            switchPrompt(scroll: scroll)
        }
        .disabled(model.isBusy)
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    // MARK: Contenido

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            LumioMark().frame(width: 56, height: 56)
            swapping(copy.heading) { heading in
                Text(heading)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(LumioColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headingHasVoiceOverFocus)
            }
            swapping(copy.subheading) { subheading in
                Text(subheading)
                    .font(.body)
                    .foregroundStyle(LumioColor.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Relevo de un texto que cambia con el modo: el anterior sube y se desvanece mientras
    /// el nuevo entra desde abajo, superpuestos para que el resto del formulario no salte.
    private func swapping<Content: View>(
        _ value: String,
        alignment: Alignment = .leading,
        @ViewBuilder content: (String) -> Content
    ) -> some View {
        ZStack(alignment: alignment) {
            content(value)
                .id(value)
                .transition(textSwap)
        }
    }

    private var textSwap: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(y: 12).combined(with: .opacity),
            removal: .offset(y: -12).combined(with: .opacity)
        )
    }

    private var modeAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.88)
    }

    private var emailDivider: some View {
        HStack(spacing: 12) {
            dividerLine
            Text("o con tu correo")
                .font(.subheadline)
                .foregroundStyle(LumioColor.textSecondary)
                .layoutPriority(1)
            dividerLine
        }
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(LumioColor.controlBorder.opacity(0.4))
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private var emailField: some View {
        LabeledInput(
            label: "Correo electrónico",
            error: emailError,
            hint: nil,
            isFocused: focusedField == .email
        ) {
            TextField("Correo electrónico", text: $model.email, prompt: Text("nombre@correo.com"))
                .emailInput()
                .focused($focusedField, equals: .email)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }
        }
    }

    private var passwordField: some View {
        LabeledInput(
            label: "Contraseña",
            error: passwordError,
            hint: model.access == .signUp
                ? "Mínimo \(CredentialsPolicy.passwordLength.lowerBound) caracteres."
                : nil,
            isFocused: focusedField == .password
        ) {
            HStack(spacing: 4) {
                Group {
                    if showsPassword {
                        TextField("Contraseña", text: $model.password)
                    } else {
                        SecureField("Contraseña", text: $model.password)
                    }
                }
                .passwordInput(isNew: model.access == .signUp)
                .focused($focusedField, equals: .password)
                .submitLabel(.go)
                .onSubmit(submit)

                Button {
                    showsPassword.toggle()
                } label: {
                    Image(systemName: showsPassword ? "eye.slash" : "eye")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(LumioColor.actionPrimary)
                .accessibilityLabel(showsPassword ? "Ocultar contraseña" : "Mostrar contraseña")
            }
        }
    }

    private var submitButton: some View {
        Button(action: submit) {
            HStack(spacing: 10) {
                if model.operation == .credentials {
                    ProgressView().tint(LumioColor.onActionPrimary)
                }
                swapping(
                    model.operation == .credentials ? copy.submittingLabel : copy.submitLabel,
                    alignment: .center
                ) { label in
                    Text(label)
                }
            }
        }
        .buttonStyle(LumioPrimaryButtonStyle())
    }

    private func switchPrompt(scroll: ScrollViewProxy) -> some View {
        swapping(copy.switchAction, alignment: .center) { _ in
            ViewThatFits {
                HStack(spacing: 4) { switchPromptContent(scroll: scroll) }
                VStack(spacing: 0) { switchPromptContent(scroll: scroll) }
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func switchPromptContent(scroll: ScrollViewProxy) -> some View {
        Text(copy.switchQuestion)
            .foregroundStyle(LumioColor.textSecondary)
        Button(copy.switchAction) {
            switchMode(scroll: scroll)
        }
        .fontWeight(.semibold)
        .foregroundStyle(LumioColor.actionPrimary)
        .frame(minHeight: 44)
    }

    // MARK: Acciones y textos

    /// Sube al título para que el cambio se vea y lleva VoiceOver al nuevo encabezado.
    private func switchMode(scroll: ScrollViewProxy) {
        focusedField = nil
        showsPassword = false
        withAnimation(modeAnimation) {
            model.switchAccess()
            scroll.scrollTo(Self.topID, anchor: .top)
        }
        // Tras el relevo, para que el foco caiga en el título nuevo y no en el saliente.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            headingHasVoiceOverFocus = true
        }
    }

    private func submit() {
        if let invalidField = model.validateForSubmit() {
            focusedField = invalidField
            if let message = invalidField == .email ? emailError : passwordError {
                announceForAccessibility(message)
            }
            return
        }
        focusedField = nil
        Task { await model.submitCredentials() }
    }

    private var emailError: String? {
        switch model.validation.email {
        case .missing: return "Escribe tu correo electrónico."
        case .invalidFormat: return "Escribe un correo válido, por ejemplo nombre@correo.com."
        case nil: return nil
        }
    }

    private var passwordError: String? {
        switch model.validation.password {
        case .missing: return "Escribe tu contraseña."
        case .tooShort(let minimum): return "La contraseña debe tener al menos \(minimum) caracteres."
        case .tooLong(let maximum): return "La contraseña puede tener como máximo \(maximum) caracteres."
        case nil: return nil
        }
    }

    private var copy: Copy {
        model.access == .signUp ? .signUp : .signIn
    }

    private struct Copy {
        let heading: String
        let subheading: String
        let submitLabel: String
        let submittingLabel: String
        let switchQuestion: String
        let switchAction: String

        static let signUp = Copy(
            heading: "Crea tu cuenta",
            subheading: "Usa tu cuenta de Google o regístrate con tu correo.",
            submitLabel: "Crear cuenta",
            submittingLabel: "Creando cuenta…",
            switchQuestion: "¿Ya tienes cuenta?",
            switchAction: "Iniciar sesión"
        )

        static let signIn = Copy(
            heading: "Inicia sesión",
            subheading: "Usa tu cuenta de Google o tu correo electrónico.",
            submitLabel: "Iniciar sesión",
            submittingLabel: "Iniciando sesión…",
            switchQuestion: "¿No tienes cuenta?",
            switchAction: "Crear cuenta"
        )
    }
}

// MARK: Componentes

/// Etiqueta visible encima del campo y, debajo, el error o una ayuda (también en la pista de
/// VoiceOver del campo).
private struct LabeledInput<Field: View>: View {
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
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .frame(minHeight: 52)
                .background(LumioColor.surface, in: shape)
                .overlay(shape.strokeBorder(borderColor, lineWidth: isFocused || error != nil ? 2 : 1))
                // SCRUM-29: el error se oye en el propio campo, como en Mi cuenta y Contactos.
                .accessibilityHint(error.map { "Error: \($0)" } ?? hint ?? "")
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(LumioColor.errorText)
                    .transition(.opacity)
            } else if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(LumioColor.textSecondary)
                    .transition(.opacity.combined(with: .offset(y: -6)))
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

/// Estado de error del design system: icono, texto y fondo de error.
private struct FailureBanner: View {
    let failure: AccountFormViewModel.Failure
    let continueWithoutSession: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.title).font(.headline)
                    Text(failure.message).font(.subheadline)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .accessibilityElement(children: .combine)
            if let continueWithoutSession {
                Button("Entrar sin sesión (solo desarrollo)", action: continueWithoutSession)
                    .font(.subheadline.weight(.semibold))
                    .underline()
                    .frame(minHeight: 44)
            }
        }
        .foregroundStyle(LumioColor.errorText)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LumioColor.errorBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Botón con los colores y el logo oficiales de Google (developers.google.com/identity/branding-guidelines).
private struct GoogleSignInButton: View {
    let isLoading: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if isLoading {
                    ProgressView().tint(GoogleColor.text)
                } else if let logo = Image(bundled: colorScheme == .dark ? "GoogleG-Dark" : "GoogleG-Light") {
                    logo
                        .resizable()
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                }
                Text(isLoading ? "Conectando con Google…" : "Continuar con Google")
            }
        }
        .buttonStyle(GoogleButtonStyle())
    }
}

private struct GoogleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(GoogleColor.text)
            .background(configuration.isPressed ? GoogleColor.pressed : GoogleColor.fill, in: shape)
            .overlay(shape.strokeBorder(GoogleColor.border, lineWidth: 1))
            .contentShape(shape)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }
}

/// El fondo debe coincidir con el de los PNG del logo de Google en cada tema.
private enum GoogleColor {
    static let fill = Color(light: 0xFFFFFF, dark: 0x131314)
    static let pressed = Color(light: 0xF2F2F2, dark: 0x1E1F20)
    static let border = Color(light: 0x747775, dark: 0x8E918F)
    static let text = Color(light: 0x1F1F1F, dark: 0xE3E3E3)
}

private extension View {
    func emailInput() -> some View {
        #if os(iOS)
        keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.username)
        #else
        autocorrectionDisabled()
        #endif
    }

    /// newPassword permite que iOS sugiera una contraseña segura y la guarde en el llavero.
    func passwordInput(isNew: Bool) -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(isNew ? .newPassword : .password)
        #else
        autocorrectionDisabled()
        #endif
    }
}

#if DEBUG
struct AccountFormView_Previews: PreviewProvider {
    static var previews: some View {
        ForEach([AccountAccess.signUp, .signIn], id: \.self) { access in
            NavigationStack {
                AccountFormView(
                    access: access,
                    service: UnavailableAuthenticationService(),
                    onAuthenticated: {},
                    continueWithoutSession: {}
                )
            }
        }
        NavigationStack {
            AccountFormView(
                access: .signUp,
                service: UnavailableAuthenticationService(),
                onAuthenticated: {},
                continueWithoutSession: nil
            )
        }
        .preferredColorScheme(.dark)
    }
}
#endif
#endif
