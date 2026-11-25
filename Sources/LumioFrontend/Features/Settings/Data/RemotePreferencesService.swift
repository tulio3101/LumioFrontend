import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// GET y PUT /users/me/preferences con el access token (AuthorizedHTTPClient renueva la sesión
/// si hace falta). Sin LumioAPIBaseURL configurada: FeatureUnavailable.
struct RemotePreferencesService: PreferencesRemoting {
    let client: any HTTPClient
    let baseURL: URL?
    var timeout: TimeInterval = 15

    func load() async throws -> RemotePreferences {
        let data = try await client.send(request(method: "GET"))
        return try JSONDecoder().decode(PreferencesDTO.self, from: data).remote
    }

    func save(_ preferences: SyncedPreferences) async throws -> Date? {
        var put = try request(method: "PUT")
        put.setValue("application/json", forHTTPHeaderField: "Content-Type")
        put.httpBody = try JSONEncoder().encode(PreferencesDTO(preferences))
        let data = try await client.send(put)
        return try JSONDecoder().decode(PreferencesDTO.self, from: data).remote.updatedAt
    }

    private func request(method: String) throws -> URLRequest {
        guard let baseURL else { throw FeatureUnavailable.authentication }
        var request = URLRequest(
            url: baseURL.appendingPathComponent("users/me/preferences"), timeoutInterval: timeout
        )
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

/// Refleja PreferencesRead y PreferencesUpdate del backend. Al enviar no se incluye
/// `updated_at`: el backend rechaza campos de más.
struct PreferencesDTO: Codable, Equatable {
    let voiceLanguage: String
    let voiceIdentifier: String?
    let speechRate: Double
    let hapticsEnabled: Bool
    let hapticIntensity: String
    let hapticDisabledEvents: [String]
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case voiceLanguage = "voice_language"
        case voiceIdentifier = "voice_identifier"
        case speechRate = "speech_rate"
        case hapticsEnabled = "haptics_enabled"
        case hapticIntensity = "haptic_intensity"
        case hapticDisabledEvents = "haptic_disabled_events"
        case updatedAt = "updated_at"
    }

    init(_ preferences: SyncedPreferences) {
        voiceLanguage = preferences.voice.language
        voiceIdentifier = preferences.voice.voiceIdentifier
        speechRate = preferences.voice.speechRate
        hapticsEnabled = preferences.haptics.isEnabled
        hapticIntensity = preferences.haptics.intensity.rawValue
        // Solo los eventos configurables: las alertas de seguridad no se pueden apagar.
        hapticDisabledEvents = preferences.haptics.disabledCues
            .filter(\.isConfigurable)
            .map(\.rawValue)
            .sorted()
        updatedAt = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(voiceLanguage, forKey: .voiceLanguage)
        try container.encode(voiceIdentifier, forKey: .voiceIdentifier)
        try container.encode(speechRate, forKey: .speechRate)
        try container.encode(hapticsEnabled, forKey: .hapticsEnabled)
        try container.encode(hapticIntensity, forKey: .hapticIntensity)
        try container.encode(hapticDisabledEvents, forKey: .hapticDisabledEvents)
    }

    var remote: RemotePreferences {
        RemotePreferences(
            preferences: SyncedPreferences(
                voice: VoicePreferences(
                    language: voiceLanguage, voiceIdentifier: voiceIdentifier, speechRate: speechRate
                ),
                haptics: HapticPreferences(
                    isEnabled: hapticsEnabled,
                    intensity: HapticIntensity(rawValue: hapticIntensity) ?? .medium,
                    disabledCues: Set(
                        hapticDisabledEvents.compactMap(HapticCue.init(rawValue:)).filter(\.isConfigurable)
                    )
                )
            ),
            updatedAt: updatedAt.flatMap(BackendDate.parse)
        )
    }
}
