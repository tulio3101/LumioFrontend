#if canImport(SwiftUI)
import SwiftUI

/// Panel de superficie de la bienvenida: agrupa contenido relacionado (región común).
struct LumioCardModifier: ViewModifier {
    var padding: CGFloat = 20
    var cornerRadius: CGFloat = 24

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape
                    .fill(LumioColor.surface)
                    .shadow(color: .black.opacity(0.08), radius: 20, y: 6)
            }
            .overlay(shape.strokeBorder(LumioColor.controlBorder.opacity(0.3), lineWidth: 1))
    }
}

extension View {
    func lumioCard(padding: CGFloat = 20, cornerRadius: CGFloat = 24) -> some View {
        modifier(LumioCardModifier(padding: padding, cornerRadius: cornerRadius))
    }

    /// Aparición escalonada como en la bienvenida; estática con «Reducir movimiento».
    func lumioEntrance(_ isVisible: Bool, delay: Double, reduceMotion: Bool) -> some View {
        opacity(isVisible || reduceMotion ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 16)
            .animation(
                reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85).delay(delay),
                value: isVisible
            )
    }
}

/// Estados del sistema de diseño: cada uno combina color, icono y texto.
enum LumioStatus {
    case success
    case warning
    case error

    var foreground: Color {
        switch self {
        case .success: return LumioColor.successText
        case .warning: return LumioColor.warningText
        case .error: return LumioColor.errorText
        }
    }

    var background: Color {
        switch self {
        case .success: return LumioColor.successBackground
        case .warning: return LumioColor.warningBackground
        case .error: return LumioColor.errorBackground
        }
    }

    var systemImage: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

/// Mensaje de estado con título opcional; VoiceOver lo lee como un solo elemento.
struct LumioStatusBanner: View {
    let status: LumioStatus
    let title: String?
    let message: String

    init(_ status: LumioStatus, title: String? = nil, message: String) {
        self.status = status
        self.title = title
        self.message = message
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                if let title {
                    Text(title).font(.headline)
                }
                Text(message).font(.subheadline)
            }
        } icon: {
            Image(systemName: status.systemImage)
        }
        .foregroundStyle(status.foreground)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(status.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// Icono dentro de un círculo tenue de marca, para encabezar tarjetas. Decorativo.
struct LumioIconBadge: View {
    let systemName: String
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(LumioColor.actionPrimary)
            .frame(width: size, height: size)
            .background(LumioColor.brand.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Símbolo con el halo que irradia de la bienvenida. Sin animación con «Reducir movimiento».
struct LumioRadiantMark: View {
    let size: CGFloat
    /// Ondas que se expanden mientras dura una operación.
    var isWorking = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRadiating = false

    var body: some View {
        LumioMark()
            .frame(width: size, height: size)
            .background { halo }
            .onAppear {
                if !reduceMotion { isRadiating = true }
            }
    }

    private var halo: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [LumioColor.brand.opacity(0.24), LumioColor.brand.opacity(0)],
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
                        .stroke(LumioColor.brand.opacity(isWorking ? 0.5 : 0.3), lineWidth: 1.5)
                        .frame(width: size * 0.5, height: size * 0.5)
                        .scaleEffect(isRadiating ? 2.4 : 1)
                        .opacity(isRadiating ? 0 : 1)
                        .animation(
                            .easeOut(duration: isWorking ? 2 : 4)
                                .repeatForever(autoreverses: false)
                                .delay(Double(ring) * (isWorking ? 1 : 2)),
                            value: isRadiating
                        )
                }
            }
        }
        .accessibilityHidden(true)
    }
}
#endif
