#if canImport(SwiftUI)
import SwiftUI

/// Primera pantalla sin sesión activa: la marca de Lumio y las dos acciones de acceso.
/// La luz del símbolo irradia en bucle; con «Reducir movimiento» todo queda estático.
struct WelcomeView: View {
    let authenticationService: any Authenticating
    let onAuthenticated: () -> Void
    /// Solo en DEBUG: permite al equipo entrar a la app mientras no exista autenticación.
    let continueWithoutSession: (() -> Void)?
    /// Recuperar Contraseña desde «Iniciar sesión». nil sin backend configurado.
    var passwordRecovery: (any PasswordRecovering)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    @State private var isRadiating = false

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let markSize = min(proxy.size.width * 0.58, proxy.size.height * 0.3, 320)
                ViewThatFits(in: .vertical) {
                    layout(markSize: markSize)
                    ScrollView { layout(markSize: markSize) }
                }
            }
            .background(LumioColor.background.ignoresSafeArea())
            .navigationDestination(for: AccountAccess.self) { access in
                AccountFormView(
                    access: access,
                    service: authenticationService,
                    onAuthenticated: onAuthenticated,
                    continueWithoutSession: continueWithoutSession,
                    passwordRecovery: passwordRecovery
                )
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .tint(LumioColor.actionPrimary)
        .onAppear(perform: startAnimations)
    }

    private func layout(markSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)
            hero(markSize: markSize)
            Spacer(minLength: 40)
            actionPanel
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    // MARK: Marca

    private func hero(markSize: CGFloat) -> some View {
        VStack(spacing: 28) {
            LumioMark()
                .frame(width: markSize, height: markSize)
                .background { halo(size: markSize) }
                .entrance(hasAppeared, delay: 0, reduceMotion: reduceMotion)

            VStack(spacing: 8) {
                Text("Lumio")
                    .font(LumioFont.brand(size: 42, relativeTo: .largeTitle))
                    .tracking(5)
                    .foregroundStyle(LumioColor.brand)
                Text("Generando independencia")
                    .font(LumioFont.brand(size: 20, relativeTo: .title3))
                    .tracking(1.5)
                    .foregroundStyle(LumioColor.textSecondary)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .entrance(hasAppeared, delay: 0.12, reduceMotion: reduceMotion)

            // Explica en una frase qué hace la app: una bienvenida más cálida y clara para quien
            // la abre por primera vez (lectores de pantalla la leen tras el encabezado).
            Text("Te guío a pie con indicaciones por voz, paso a paso.")
                .font(.body)
                .foregroundStyle(LumioColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .entrance(hasAppeared, delay: 0.18, reduceMotion: reduceMotion)
        }
    }

    /// Luz suave detrás del símbolo y dos ondas que se expanden desde la esfera.
    private func halo(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [LumioColor.brand.opacity(0.26), LumioColor.brand.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.7
                ))
                .frame(width: size * 1.4, height: size * 1.4)
                .scaleEffect(isRadiating ? 1.08 : 0.94)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 3).repeatForever(autoreverses: true),
                    value: isRadiating
                )

            if !reduceMotion {
                ForEach(0..<2) { ring in
                    Circle()
                        .stroke(LumioColor.brand.opacity(0.35), lineWidth: 1.5)
                        .frame(width: size * 0.5, height: size * 0.5)
                        .scaleEffect(isRadiating ? 2.4 : 1)
                        .opacity(isRadiating ? 0 : 1)
                        .animation(
                            .easeOut(duration: 4)
                                .repeatForever(autoreverses: false)
                                .delay(Double(ring) * 2),
                            value: isRadiating
                        )
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Acciones

    private var actionPanel: some View {
        VStack(spacing: 12) {
            NavigationLink("Crear cuenta", value: AccountAccess.signUp)
                .buttonStyle(LumioPrimaryButtonStyle())
            NavigationLink("Iniciar sesión", value: AccountAccess.signIn)
                .buttonStyle(LumioSecondaryButtonStyle())
        }
        .padding(20)
        .frame(maxWidth: 440)
        .background {
            panelShape
                .fill(LumioColor.surface)
                .shadow(color: .black.opacity(0.1), radius: 24, y: 8)
        }
        .overlay(panelShape.strokeBorder(LumioColor.controlBorder.opacity(0.3), lineWidth: 1))
        .entrance(hasAppeared, delay: 0.24, reduceMotion: reduceMotion)
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LumioRadius.card, style: .continuous)
    }

    private func startAnimations() {
        guard !hasAppeared else { return }
        hasAppeared = true
        if !reduceMotion {
            isRadiating = true
        }
    }
}

private extension View {
    /// Aparición escalonada: sube y se desvanece hacia su lugar en menos de medio segundo.
    func entrance(_ isVisible: Bool, delay: Double, reduceMotion: Bool) -> some View {
        opacity(isVisible || reduceMotion ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 16)
            .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85).delay(delay), value: isVisible)
    }
}

#if DEBUG
struct WelcomeView_Previews: PreviewProvider {
    static var previews: some View {
        welcome
            .previewDisplayName("Móvil")
        welcome
            .preferredColorScheme(.dark)
            .previewDisplayName("Móvil, oscuro")
        welcome
            .previewLayout(.fixed(width: 1180, height: 820))
            .previewDisplayName("Pantalla ancha")
    }

    private static var welcome: WelcomeView {
        WelcomeView(
            authenticationService: UnavailableAuthenticationService(),
            onAuthenticated: {},
            continueWithoutSession: nil
        )
    }
}
#endif
#endif
