#if canImport(SwiftUI)
import SwiftUI

/// Eliminar Cuenta (SCRUM-7). Prevención de errores en dos pasos, ambos explicados por audio:
///
/// 1. Al abrir la pantalla se explican las consecuencias. Sin VoiceOver las locuta el
///    AudioArbiter; con VoiceOver el foco va a la explicación para no hablar a la vez.
/// 2. «Eliminar mi cuenta» abre la última confirmación («Eliminar definitivamente»).
///
/// El resultado (y cualquier error) lo locuta el servicio; aquí además se muestra. No se
/// mueve el foco de VoiceOver al error para no superponer su voz con la del árbitro.
struct DeleteAccountView: View {
    let deleter: any AccountDeleting
    /// La cuenta ya no está (o la sesión expiró): volver a la bienvenida.
    let onAccountClosed: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @AccessibilityFocusState private var focus: Focus?
    @State private var confirmsDeletion = false
    @State private var isDeleting = false
    @State private var failure: AccountDeletionOutcome?
    /// La pantalla se cierra por el resultado: no cortar su anuncio al desaparecer.
    @State private var closedByOutcome = false

    private enum Focus: Hashable {
        case explanation
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let failure {
                    LumioStatusBanner(
                        .error,
                        title: AccountDeletionAnnouncements.title(for: failure),
                        message: AccountDeletionAnnouncements.message(for: failure)
                    )
                }
                consequences
                actions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(LumioColor.background.ignoresSafeArea())
        .navigationTitle(AccountDeletionAnnouncements.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationBarBackButtonHidden(isDeleting)
        .interactiveDismissDisabled(isDeleting)
        .onAppear(perform: explain)
        .onDisappear { if !closedByOutcome { deleter.cancel() } }
        .confirmationDialog(
            AccountDeletionAnnouncements.finalQuestion,
            isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button("Eliminar definitivamente", role: .destructive, action: delete)
            Button("Cancelar", role: .cancel) { deleter.cancel() }
        } message: {
            Text(AccountDeletionAnnouncements.finalMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            LumioIconBadge(systemName: "person.crop.circle.badge.xmark")
            VStack(alignment: .leading, spacing: 6) {
                Text("Eliminar tu cuenta")
                    .font(.title2.bold())
                    .foregroundStyle(LumioColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Antes de continuar, revisa lo que se borra.")
                    .font(.subheadline)
                    .foregroundStyle(LumioColor.textSecondary)
            }
        }
    }

    /// Un solo elemento para VoiceOver: se lee completo al llegar a la pantalla.
    private var consequences: some View {
        VStack(alignment: .leading, spacing: 14) {
            LumioStatusBanner(.warning, title: "No se puede deshacer", message: "Esto es lo que pasa al eliminarla:")
            ForEach(AccountDeletionAnnouncements.consequences, id: \.self) { item in
                Label {
                    Text(item).foregroundStyle(LumioColor.textPrimary)
                } icon: {
                    Image(systemName: "minus.circle").foregroundStyle(LumioColor.errorText)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .lumioCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AccountDeletionAnnouncements.explanation)
        .accessibilityFocused($focus, equals: .explanation)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                failure = nil
                confirmsDeletion = true
                // Con VoiceOver, el propio diálogo se lee en voz alta.
                if !voiceOverEnabled { deleter.askForFinalConfirmation() }
            } label: {
                if isDeleting {
                    ProgressView().tint(LumioColor.errorText)
                } else {
                    Label("Eliminar mi cuenta", systemImage: "trash")
                }
            }
            .buttonStyle(LumioDestructiveButtonStyle())
            .disabled(isDeleting)
            .accessibilityLabel(isDeleting ? AccountDeletionAnnouncements.deleting : "Eliminar mi cuenta")
            .accessibilityHint("Pide una última confirmación antes de borrar la cuenta para siempre.")

            Button {
                deleter.explainConsequences()
            } label: {
                Label("Escuchar de nuevo", systemImage: "speaker.wave.2")
            }
            .buttonStyle(LumioSecondaryButtonStyle())
            .disabled(isDeleting)
            .accessibilityHint("Repite por audio qué se borra al eliminar la cuenta.")

            Button("Cancelar") {
                deleter.cancel()
                dismiss()
            }
            .buttonStyle(LumioSecondaryButtonStyle())
            .disabled(isDeleting)
            .accessibilityHint("Vuelve a Preferencias sin eliminar la cuenta.")
        }
    }

    private func explain() {
        if voiceOverEnabled {
            // Tras la transición de entrada, para que el foco no se quede en el botón Atrás.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { focus = .explanation }
        } else {
            deleter.explainConsequences()
        }
    }

    private func delete() {
        guard !isDeleting else { return }
        isDeleting = true
        Task {
            let outcome = await deleter.deleteAccount()
            isDeleting = false
            guard let outcome else { return }
            if outcome.leavesTheApp {
                closedByOutcome = true
                onAccountClosed()
            } else {
                failure = outcome
            }
        }
    }
}
#endif
