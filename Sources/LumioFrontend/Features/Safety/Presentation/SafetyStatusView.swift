#if os(iOS)
import SwiftUI

/// SCRUM-37: estado de la detección de obstáculos, visible en Debug y Release mientras hay una
/// ruta activa. Si la detección quedó no disponible, ofrece «Reintentar detección».
struct SafetyStatusView: View {
    @ObservedObject var service: SafetyService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LumioStatusBanner(bannerStatus, title: "Detección de obstáculos", message: service.status.message)
            if case .unavailable = service.status {
                Button("Reintentar detección") {
                    Task { await service.retry() }
                }
                .buttonStyle(LumioSecondaryButtonStyle())
                .accessibilityHint("Intenta preparar de nuevo la cámara y el modelo de detección.")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var bannerStatus: LumioStatus {
        switch service.status {
        case .running: return .success
        case .unavailable: return .error
        case .stopped, .starting, .recovering: return .warning
        }
    }
}
#endif
