#if canImport(SwiftUI)
import SwiftUI

/// SCRUM-25, Preferencias > Emergencia > Compartir ubicación. Explica qué se comparte, deja
/// elegir la duración y pide confirmación explícita antes de empezar. Mientras se comparte,
/// muestra el estado y «Dejar de compartir». Cada resultado lo locuta el servicio.
struct LocationSharingView: View {
    @ObservedObject var service: LocationSharingService
    @State private var minutes = LocationSharingPolicy.defaultDuration
    @State private var confirmsStart = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 14) {
                    LumioIconBadge(systemName: "location.fill.viewfinder")
                    Text("Compartir tu ubicación")
                        .font(.title2.bold())
                        .foregroundStyle(LumioColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                if case .sharing(let share, let isOffline) = service.state {
                    LumioStatusBanner(
                        isOffline ? .warning : .success,
                        title: isOffline ? "Sin conexión" : "Compartiendo tu ubicación",
                        message: isOffline
                            ? LocationSharingAnnouncements.offline
                            : LocationSharingAnnouncements.started(share)
                    )
                    .accessibilityAddTraits(.updatesFrequently)
                }
                Text(LocationSharingAnnouncements.explanation)
                    .foregroundStyle(LumioColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lumioCard()
                actions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(LumioColor.background.ignoresSafeArea())
        .navigationTitle("Compartir ubicación")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(
            LocationSharingAnnouncements.confirmation(minutes: minutes),
            isPresented: $confirmsStart,
            titleVisibility: .visible
        ) {
            Button("Compartir mi ubicación") {
                Task { await service.start(durationMinutes: minutes) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Tus contactos de confianza recibirán un correo con el enlace.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch service.state {
        case .idle:
            VStack(alignment: .leading, spacing: 12) {
                Picker("Durante", selection: $minutes) {
                    ForEach(LocationSharingPolicy.durations, id: \.self) { value in
                        Text(LocationSharingAnnouncements.duration(value)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Durante cuánto tiempo")
                Button {
                    confirmsStart = true
                } label: {
                    Label("Compartir mi ubicación", systemImage: "location.fill")
                }
                .buttonStyle(LumioPrimaryButtonStyle())
                .accessibilityHint("Pide confirmación y luego avisa por correo a tus contactos de confianza.")
            }
        case .starting:
            busy("Empezando a compartir…")
        case .stopping:
            busy("Dejando de compartir…")
        case .sharing:
            Button {
                Task { await service.stop() }
            } label: {
                Label("Dejar de compartir", systemImage: "location.slash")
            }
            .buttonStyle(LumioDestructiveButtonStyle())
            .accessibilityHint("Tus contactos dejan de ver tu ubicación.")
        }
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 12) {
            ProgressView().tint(LumioColor.actionPrimary)
            Text(text).foregroundStyle(LumioColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// SCRUM-25: mientras se comparte, un aviso fijo arriba de Trayecto lo recuerda y deja
/// detenerlo sin ir a Preferencias. VoiceOver lo encuentra al principio de la pantalla.
extension View {
    @ViewBuilder
    func locationSharingBanner(_ service: LocationSharingService?) -> some View {
        if let service {
            modifier(LocationSharingBannerModifier(service: service))
        } else {
            self
        }
    }
}

private struct LocationSharingBannerModifier: ViewModifier {
    @ObservedObject var service: LocationSharingService

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if case .sharing(_, let isOffline) = service.state {
                HStack(spacing: 12) {
                    Label(
                        isOffline ? "Compartiendo ubicación, sin conexión" : "Compartiendo tu ubicación",
                        systemImage: isOffline ? "location.slash" : "location.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isOffline ? LumioColor.warningText : LumioColor.successText)
                    Spacer()
                    Button("Detener") { Task { await service.stop() } }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                        .accessibilityLabel("Dejar de compartir la ubicación")
                }
                .padding(.horizontal, 16)
                .background(isOffline ? LumioColor.warningBackground : LumioColor.successBackground)
            }
        }
    }
}
#endif
