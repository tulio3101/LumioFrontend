#if canImport(SwiftUI)
import CoreText
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Tokens de color de docs/DESIGN_SYSTEM.md. Cada uno cambia con la apariencia del sistema.
enum LumioColor {
    static let background = Color(light: 0xF5F8FA, dark: 0x10212B)
    static let surface = Color(light: 0xFFFFFF, dark: 0x192F3B)
    static let textPrimary = Color(light: 0x172B36, dark: 0xF3F7FA)
    static let textSecondary = Color(light: 0x465D69, dark: 0xBBCBD4)
    static let actionPrimary = Color(light: 0x00658A, dark: 0x76D4F5)
    static let onActionPrimary = Color(light: 0xFFFFFF, dark: 0x10212B)
    static let controlBorder = Color(light: 0x70838D, dark: 0x829BAA)
    static let errorText = Color(light: 0xB42318, dark: 0xFFB4AB)
    static let errorBackground = Color(light: 0xFDECE9, dark: 0x452522)
    static let successText = Color(light: 0x18734A, dark: 0x83DFAC)
    static let successBackground = Color(light: 0xEAF6EF, dark: 0x16392B)
    static let warningText = Color(light: 0x875400, dark: 0xFFD581)
    static let warningBackground = Color(light: 0xFFF4D6, dark: 0x40321B)
    /// Solo para el símbolo y el nombre de marca, nunca para acciones.
    /// En oscuro usa el azul claro porque #087FAE no contrasta con el fondo.
    static let brand = Color(light: 0x087FAE, dark: 0x76D4F5)
}

extension Color {
    /// Para tokens y colores de marcas externas; no usar valores sueltos en las vistas.
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
        #endif
    }
}

private extension UInt32 {
    var red: CGFloat { CGFloat((self >> 16) & 0xFF) / 255 }
    var green: CGFloat { CGFloat((self >> 8) & 0xFF) / 255 }
    var blue: CGFloat { CGFloat(self & 0xFF) / 255 }
}

#if SWIFT_PACKAGE
private let resourceBundle = Bundle.module
#else
private let resourceBundle = Bundle.main
#endif

/// Tipografía de marca: Quicksand Medium (OFL, ver Resources/Quicksand-OFL.txt).
/// Solo para el nombre y el lema; el resto de la interfaz usa la tipografía del sistema.
enum LumioFont {
    static func brand(size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        _ = registration
        return .custom("Quicksand-Medium", size: size, relativeTo: style)
    }

    /// Se registra desde el bundle de recursos porque, con SwiftPM, UIAppFonts no lo alcanza.
    private static let registration: Void = {
        guard let url = resourceBundle.url(forResource: "Quicksand-Medium", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()
}

/// Símbolo de Lumio sin textos: manos que sostienen una luz. Decorativo para VoiceOver.
struct LumioMark: View {
    var body: some View {
        markImage
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(LumioColor.brand)
            .accessibilityHidden(true)
    }

    private var markImage: Image {
        Image(bundled: "LumioMark") ?? Image(systemName: "sun.max")
    }
}

extension Image {
    /// Imagen suelta de Resources/, que vive en Bundle.module (SwiftPM) o Bundle.main (Xcode).
    init?(bundled name: String) {
        #if canImport(UIKit)
        guard let image = UIImage(named: name, in: resourceBundle, with: nil) else { return nil }
        self.init(uiImage: image)
        #else
        guard let image = resourceBundle.image(forResource: name) else { return nil }
        self.init(nsImage: image)
        #endif
    }
}

/// Acción principal de la pantalla: relleno de acción y contenido sobre la acción.
struct LumioPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(LumioColor.onActionPrimary)
            .background {
                buttonShape
                    .fill(LumioColor.actionPrimary)
                    .shadow(
                        color: LumioColor.actionPrimary.opacity(configuration.isPressed ? 0.15 : 0.35),
                        radius: configuration.isPressed ? 4 : 12,
                        y: configuration.isPressed ? 2 : 6
                    )
            }
            .contentShape(buttonShape)
            .modifier(PressFeedback(isPressed: configuration.isPressed))
    }
}

/// Acción secundaria: superficie neutra, texto de acción y borde funcional.
struct LumioSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(LumioColor.actionPrimary)
            .background(configuration.isPressed ? LumioColor.background : LumioColor.surface, in: buttonShape)
            .overlay(buttonShape.strokeBorder(LumioColor.controlBorder, lineWidth: 1))
            .contentShape(buttonShape)
            .modifier(PressFeedback(isPressed: configuration.isPressed))
    }
}

/// Acción irreversible (p. ej. eliminar la cuenta): colores de error con borde, siempre
/// acompañada de un icono y un texto explícito para no depender del color.
struct LumioDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(LumioColor.errorText)
            .background(LumioColor.errorBackground, in: buttonShape)
            .overlay(buttonShape.strokeBorder(LumioColor.errorText, lineWidth: configuration.isPressed ? 2 : 1))
            .contentShape(buttonShape)
            .modifier(PressFeedback(isPressed: configuration.isPressed))
    }
}

/// Respuesta inmediata al pulsar; sin animación con «Reducir movimiento».
private struct PressFeedback: ViewModifier {
    let isPressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isPressed)
    }
}

private let buttonShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
#endif
