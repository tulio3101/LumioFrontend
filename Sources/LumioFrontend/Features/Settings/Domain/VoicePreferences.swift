import Foundation

/// Configurar Preferencias de Voz Descriptiva: idioma, voz y velocidad con que Lumio habla.
/// Se aplican en el reproductor del AudioArbiter, así que valen para todas las locuciones
/// (seguridad, navegación, narración y comandos de voz), no solo para la narración.
/// Se guardan en el teléfono; no dependen del backend.
struct VoicePreferences: Codable, Equatable {
    /// Variante de español en formato BCP-47, por ejemplo "es-MX".
    var language: String
    /// Identificador de la voz del sistema (AVSpeechSynthesisVoice). nil: la predeterminada
    /// del idioma.
    var voiceIdentifier: String?
    /// Veces la velocidad normal: 1 es normal, 0,5 la mitad y 2 el doble.
    var speechRate: Double

    /// es-MX: iOS pronuncia "0,3" como "cero coma tres" (separador decimal español).
    static let standard = VoicePreferences(language: "es-MX", voiceIdentifier: nil, speechRate: 1)
}

/// Un idioma que el teléfono puede usar para hablar.
struct VoiceLanguageOption: Identifiable, Equatable {
    let code: String
    let name: String
    var id: String { code }
}

/// Una voz instalada en el teléfono.
struct VoiceOption: Identifiable, Equatable {
    let id: String
    let name: String
    let language: String
    /// Calidad mejorada o premium: suena más natural, pero hay que descargarla.
    let isEnhanced: Bool

    var displayName: String { isEnhanced ? "\(name) (mejorada)" : name }
}

/// Las voces que el teléfono tiene instaladas. Solo variantes de español: todos los textos de
/// Lumio están en español y una voz de otro idioma los leería mal.
protocol VoiceCatalogProviding {
    func availableLanguages() -> [VoiceLanguageOption]
    func availableVoices(language: String) -> [VoiceOption]
}

/// Sin voces del sistema (Linux o plataformas sin AVFoundation).
struct NoVoiceCatalog: VoiceCatalogProviding {
    func availableLanguages() -> [VoiceLanguageOption] { [] }
    func availableVoices(language: String) -> [VoiceOption] { [] }
}

/// Copia de las preferencias en el teléfono. Es la única fuente al abrir la app.
protocol VoicePreferencesStoring {
    func load() throws -> VoicePreferences?
    func save(_ preferences: VoicePreferences) throws
    func clear() throws
}

/// Quien reproduce las locuciones (SpeechAudioPlayer). Aplicar es inmediato y en memoria:
/// la siguiente locución ya sale con la configuración nueva y nunca se espera al disco ni a
/// la red.
@MainActor
protocol VoiceOutputConfiguring: AnyObject {
    func apply(_ preferences: VoicePreferences)
}

// MARK: - Velocidad

enum SpeechRatePolicy {
    static let range: ClosedRange<Double> = 0.5...2
    static let step: Double = 0.25

    static func isValid(_ rate: Double) -> Bool {
        rate.isFinite && range.contains(rate)
    }

    /// Velocidad de AVSpeechUtterance para el multiplicador: la normal del sistema por el
    /// multiplicador, sin salirse de los límites del sistema (0,5 veces es la mitad de la
    /// normal y 2 veces es la máxima).
    static func utteranceRate(for rate: Double, normal: Float, minimum: Float, maximum: Float) -> Float {
        let multiplier = isValid(rate) ? rate : 1
        return min(max(normal * Float(multiplier), minimum), maximum)
    }

    /// "normal", "1,25 veces", "2 veces": así se muestra y se locuta.
    static func spokenName(for rate: Double) -> String {
        if rate == 1 { return "normal" }
        return "\(decimal(rate)) veces"
    }

    /// Coma decimal y sin ceros sobrantes, como lo lee el TTS en español.
    static func decimal(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text.replacingOccurrences(of: ".", with: ",")
    }
}

// MARK: - Validación

/// Por qué una configuración no se puede aplicar.
enum VoicePreferenceIssue: Equatable {
    case invalidRate
    case languageUnavailable(String)
    case voiceUnavailable
    /// El archivo guardado no se pudo leer; se usan las predeterminadas.
    case storedUnreadable
}

enum VoicePreferencesPolicy {
    /// El primer problema que impide aplicar la configuración, o nil si se puede aplicar.
    /// Sin catálogo (no se pudo consultar las voces del sistema) no se rechaza el idioma ni la
    /// voz: el reproductor cae en la voz más cercana disponible.
    static func issue(
        with preferences: VoicePreferences, catalog: any VoiceCatalogProviding
    ) -> VoicePreferenceIssue? {
        guard SpeechRatePolicy.isValid(preferences.speechRate) else { return .invalidRate }
        let languages = catalog.availableLanguages()
        guard !languages.isEmpty else { return nil }
        guard languages.contains(where: { $0.code == preferences.language }) else {
            return .languageUnavailable(preferences.language)
        }
        if let voice = preferences.voiceIdentifier,
           !catalog.availableVoices(language: preferences.language).contains(where: { $0.id == voice }) {
            return .voiceUnavailable
        }
        return nil
    }

    /// Lo que se puede aplicar de una configuración guardada, y lo que hubo que cambiar.
    /// Conserva todo lo válido: una voz desinstalada no hace perder la velocidad.
    static func usable(
        _ stored: VoicePreferences, catalog: any VoiceCatalogProviding
    ) -> (preferences: VoicePreferences, issues: [VoicePreferenceIssue]) {
        var preferences = stored
        var issues: [VoicePreferenceIssue] = []
        if !SpeechRatePolicy.isValid(preferences.speechRate) {
            preferences.speechRate = VoicePreferences.standard.speechRate
            issues.append(.invalidRate)
        }
        if case .languageUnavailable(let code)? = issue(with: preferences, catalog: catalog) {
            let languages = catalog.availableLanguages()
            preferences.language = languages.contains(where: { $0.code == VoicePreferences.standard.language })
                ? VoicePreferences.standard.language
                : languages.first?.code ?? VoicePreferences.standard.language
            preferences.voiceIdentifier = nil
            issues.append(.languageUnavailable(code))
        }
        if issue(with: preferences, catalog: catalog) == .voiceUnavailable {
            preferences.voiceIdentifier = nil
            issues.append(.voiceUnavailable)
        }
        return (preferences, issues)
    }
}

/// Nombre del idioma para mostrar y locutar: "Español (México)".
enum VoiceLanguageNames {
    private static let regions: [String: String] = [
        "MX": "México", "ES": "España", "US": "Estados Unidos", "CO": "Colombia",
        "AR": "Argentina", "CL": "Chile", "PE": "Perú", "419": "Latinoamérica",
    ]

    static func name(for code: String) -> String {
        let parts = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard parts.first?.lowercased() == "es" else { return code }
        guard parts.count > 1, let region = parts.last?.uppercased() else { return "Español" }
        let regionName = regions[region]
            ?? Locale(identifier: "es").localizedString(forRegionCode: region)
            ?? region
        return "Español (\(regionName))"
    }
}

// MARK: - Resultados

enum VoicePreferencesOutcome: Equatable {
    /// Aplicadas y guardadas en el teléfono.
    case saved
    /// Ya eran las actuales: no se guarda ni se locuta nada.
    case unchanged
    /// Aplicadas, pero no se pudieron guardar: al cerrar la app vuelven las anteriores.
    case appliedNotSaved
    /// No se aplicó nada; siguen las anteriores.
    case rejected(VoicePreferenceIssue)
}

/// Consultar y cambiar las preferencias de voz. Lo usa la pantalla de Preferencias.
@MainActor
protocol VoicePreferencesManaging: AnyObject {
    /// Las que se están usando ahora.
    var preferences: VoicePreferences { get }
    /// Lo que no se pudo aplicar de lo guardado al abrir la app.
    var launchIssues: [VoicePreferenceIssue] { get }
    func availableLanguages() -> [VoiceLanguageOption]
    func availableVoices(language: String) -> [VoiceOption]
    func update(_ preferences: VoicePreferences) -> VoicePreferencesOutcome
    /// Locuta una frase de ejemplo con la configuración actual.
    func preview()
}

/// Eliminar Cuenta (SCRUM-7) borra las preferencias del teléfono.
@MainActor
protocol VoicePreferencesResetting: AnyObject {
    func resetToStandard()
}

// MARK: - Textos

/// Lo que se muestra es lo mismo que se locuta.
enum VoicePreferencesAnnouncements {
    static let sample = "Hola, soy Lumio. Así sonarán tus indicaciones y alertas."
    static let notSaved = "Se aplicó el cambio, pero no se pudo guardar en el teléfono. "
        + "Al cerrar la app volverá la configuración anterior."
    static let appliesToEverything = "Se aplica a todo lo que dice Lumio: alertas de seguridad, "
        + "indicaciones de la ruta, narración y comandos de voz."

    static func languageName(_ code: String, catalog: [VoiceLanguageOption]) -> String {
        catalog.first(where: { $0.code == code })?.name ?? VoiceLanguageNames.name(for: code)
    }

    static func voiceName(_ identifier: String?, voices: [VoiceOption]) -> String {
        guard let identifier else { return "predeterminada" }
        return voices.first(where: { $0.id == identifier })?.displayName ?? "predeterminada"
    }

    /// Resumen para consultar las preferencias actuales.
    static func summary(language: String, voice: String, rate: Double) -> String {
        "Idioma: \(language). Voz: \(voice). Velocidad: \(SpeechRatePolicy.spokenName(for: rate))."
    }

    /// Confirmación de lo que cambió; se locuta ya con la voz nueva.
    static func confirmation(
        from old: VoicePreferences, to new: VoicePreferences, language: String, voice: String
    ) -> String {
        var parts: [String] = []
        if old.language != new.language { parts.append("Idioma: \(language).") }
        if old.voiceIdentifier != new.voiceIdentifier || old.language != new.language {
            parts.append("Voz: \(voice).")
        }
        if old.speechRate != new.speechRate {
            parts.append("Velocidad: \(SpeechRatePolicy.spokenName(for: new.speechRate)).")
        }
        return (parts + ["Así sonará Lumio."]).joined(separator: " ")
    }

    static func message(for issue: VoicePreferenceIssue, languageName: String? = nil) -> String {
        switch issue {
        case .invalidRate:
            return "Esa velocidad no está disponible. Elige entre "
                + "\(SpeechRatePolicy.decimal(SpeechRatePolicy.range.lowerBound)) y "
                + "\(SpeechRatePolicy.decimal(SpeechRatePolicy.range.upperBound)) veces la normal. "
                + "No se cambió nada."
        case .languageUnavailable(let code):
            return "El idioma \(languageName ?? VoiceLanguageNames.name(for: code)) no está disponible "
                + "en este teléfono. No se cambió nada."
        case .voiceUnavailable:
            return "Esa voz no está instalada en este teléfono. Puedes descargarla en Ajustes, "
                + "Accesibilidad, Contenido leído, Voces. No se cambió nada."
        case .storedUnreadable:
            return "No se pudieron leer tus preferencias de voz guardadas. Se usan las predeterminadas."
        }
    }

    /// Lo que se ajustó al abrir la app porque lo guardado ya no se podía usar.
    static func launchMessage(for issue: VoicePreferenceIssue, current language: String) -> String {
        switch issue {
        case .invalidRate:
            return "La velocidad guardada no era válida. Se usa la velocidad normal."
        case .languageUnavailable(let code):
            return "El idioma \(VoiceLanguageNames.name(for: code)) ya no está en este teléfono. "
                + "Se usa \(language)."
        case .voiceUnavailable:
            return "La voz que elegiste ya no está en este teléfono. Se usa la voz predeterminada de \(language)."
        case .storedUnreadable:
            return message(for: .storedUnreadable)
        }
    }
}
