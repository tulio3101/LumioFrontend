#if canImport(SwiftUI)
import SwiftUI

struct SettingsView: View {
    let signOut: any SigningOut
    /// Personalizar Cuenta (SCRUM-6).
    let profile: any ProfileManaging
    /// Configurar Contactos de Confianza (SCRUM-319).
    let contacts: any TrustedContactsManaging
    /// Eliminar Cuenta (SCRUM-7).
    let accountDeleter: any AccountDeleting
    /// Configurar Preferencias de Voz Descriptiva.
    let voicePreferences: any VoicePreferencesManaging
    /// Configurar Retroalimentación Háptica.
    let hapticPreferences: any HapticPreferencesManaging
    /// Se llama después de cerrar la sesión o eliminar la cuenta para volver a la bienvenida.
    let onSignedOut: () -> Void
    #if os(iOS)
    let permissions: PermissionsViewModel
    /// SCRUM-324: consentimiento para enviar fotos a la narración. nil: no se muestra.
    var narrationConsent: NarrationConsentService? = nil
    /// SCRUM-32: narración automática y avisos. nil: no se muestra.
    var accessibilityPreferences: AccessibilityPreferencesService? = nil
    #endif

    @State private var confirmsSignOut = false
    @State private var isSigningOut = false

    var body: some View {
        Form {
            #if os(iOS)
            NavigationLink("Permisos y accesibilidad") { PermissionsView(model: permissions) }
            #endif
            NavigationLink {
                VoicePreferencesView(service: voicePreferences)
            } label: {
                Label("Preferencias de voz", systemImage: "speaker.wave.2")
            }
            .disabled(isSigningOut)
            .accessibilityHint("Consulta y cambia el idioma, la voz y la velocidad con que habla Lumio.")
            NavigationLink {
                HapticPreferencesView(service: hapticPreferences)
            } label: {
                Label("Vibración", systemImage: "iphone.radiowaves.left.and.right")
            }
            .disabled(isSigningOut)
            .accessibilityHint("Activa o desactiva la vibración, elige qué eventos vibran y con qué intensidad.")
            #if os(iOS)
            if let narrationConsent {
                NavigationLink {
                    NarrationConsentView(service: narrationConsent)
                } label: {
                    Label("Narración del entorno", systemImage: "camera.viewfinder")
                }
                .disabled(isSigningOut)
                .accessibilityHint("Decide si Lumio puede enviar fotos de la cámara para describir lo que tienes delante.")
            }
            if let accessibilityPreferences {
                NavigationLink {
                    AccessibilityPreferencesView(service: accessibilityPreferences)
                } label: {
                    Label("Preferencias de accesibilidad", systemImage: "accessibility")
                }
                .disabled(isSigningOut)
                .accessibilityHint("Activa o desactiva la narración automática y elige cuánto explican los avisos.")
            }
            #endif
            Section("Emergencia") {
                NavigationLink {
                    TrustedContactsView(service: contacts, onSessionExpired: onSignedOut)
                } label: {
                    Label("Contactos de confianza", systemImage: "person.2.fill")
                }
                .disabled(isSigningOut)
                .accessibilityHint("Agrega, edita o elimina a quienes recibirán tu alerta de emergencia por correo.")
            }
            Section("Cuenta") {
                NavigationLink {
                    ProfileView(service: profile, onSessionExpired: onSignedOut)
                } label: {
                    Label("Mi cuenta", systemImage: "person.crop.circle")
                }
                .disabled(isSigningOut)
                .accessibilityHint("Consulta tu correo y cambia tu nombre, tu celular o tu contraseña.")

                Button(role: .destructive) {
                    confirmsSignOut = true
                } label: {
                    HStack {
                        Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                        if isSigningOut {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isSigningOut)
                .accessibilityHint("Pide confirmación antes de cerrar la sesión.")

                NavigationLink {
                    DeleteAccountView(deleter: accountDeleter, onAccountClosed: onSignedOut)
                } label: {
                    Label("Eliminar cuenta", systemImage: "person.crop.circle.badge.xmark")
                        .foregroundStyle(LumioColor.errorText)
                }
                .disabled(isSigningOut)
                .accessibilityHint("Explica qué se borra y pide dos confirmaciones antes de eliminarla.")
            }
        }
        .navigationTitle("Preferencias")
        // Prevención de errores: la acción borra la ruta guardada en el teléfono.
        .confirmationDialog(
            "¿Cerrar sesión?",
            isPresented: $confirmsSignOut,
            titleVisibility: .visible
        ) {
            Button("Cerrar sesión", role: .destructive) {
                Task {
                    isSigningOut = true
                    await signOut.signOut()
                    isSigningOut = false
                    onSignedOut()
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se borrará la ruta guardada en este teléfono. Podrás volver a entrar con tu correo.")
        }
    }
}
#endif
