#if canImport(SwiftUI)
import SwiftUI

struct SettingsView: View {
    let signOut: any SigningOut
    /// Personalizar Cuenta (SCRUM-6).
    let profile: any ProfileManaging
    /// Eliminar Cuenta (SCRUM-7).
    let accountDeleter: any AccountDeleting
    /// Se llama después de cerrar la sesión o eliminar la cuenta para volver a la bienvenida.
    let onSignedOut: () -> Void
    #if os(iOS)
    let permissions: PermissionsViewModel
    #endif

    @State private var confirmsSignOut = false
    @State private var isSigningOut = false

    var body: some View {
        Form {
            #if os(iOS)
            NavigationLink("Permisos y accesibilidad") { PermissionsView(model: permissions) }
            #endif
            FeatureStatusView(
                title: "Preferencias de voz",
                message: "Aquí se integrarán idioma, velocidad y configuración de voz."
            )
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
