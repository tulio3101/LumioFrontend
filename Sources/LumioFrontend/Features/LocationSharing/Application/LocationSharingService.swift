import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// SCRUM-25: Compartir Ubicación.
///
/// 1. `start` solo se llama después de que el usuario confirmó (la pantalla lo pide). Sin red
///    no se intenta. Pide la ubicación con el flujo de la ruta (CoreLocation solicita el
///    permiso si falta) y la envía a `POST /location-shares`, que avisa por correo a los
///    contactos de confianza.
/// 2. Mientras se comparte, cada 30 s envía la posición actual. Sin conexión lo dice una vez y
///    sigue intentando; al volver la red, lo dice y retoma.
/// 3. Termina al detenerlo (`DELETE`), al vencer el tiempo (410 o reloj) o al cerrar sesión.
/// 4. Todo se dice por el AudioArbiter como P2: una alerta P1 lo interrumpe.
@MainActor
final class LocationSharingService: ObservableObject, LocationSharingStopping {
    static let contextID = "location-sharing"

    @Published private(set) var state: LocationSharingState = .idle

    private let remote: any LocationSharingRemoting
    private let location: any CurrentLocationProviding
    private let connectivity: any ConnectivityObserving
    private let arbiter: (any AudioArbitrating)?
    private let tokens: (any TokenStoring)?
    private let sleep: (TimeInterval) async throws -> Void
    private let now: () -> Date
    /// false en pruebas: el ciclo lo maneja la prueba con `keepSharing`.
    private let runsUpdateLoop: Bool
    private var loop: Task<Void, Never>?

    init(
        remote: any LocationSharingRemoting,
        location: any CurrentLocationProviding,
        connectivity: any ConnectivityObserving,
        arbiter: (any AudioArbitrating)?,
        tokens: (any TokenStoring)? = nil,
        sleep: @escaping (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        },
        now: @escaping () -> Date = Date.init,
        runsUpdateLoop: Bool = true
    ) {
        self.runsUpdateLoop = runsUpdateLoop
        self.remote = remote
        self.location = location
        self.connectivity = connectivity
        self.arbiter = arbiter
        self.tokens = tokens
        self.sleep = sleep
        self.now = now
    }

    var isSharing: Bool {
        if case .sharing = state { return true }
        return false
    }

    // MARK: Empezar

    /// Devuelve la falla, ya dicha por audio, o nil si empezó a compartir.
    @discardableResult
    func start(durationMinutes: Int = LocationSharingPolicy.defaultDuration) async -> LocationSharingFailure? {
        guard state == .idle else { return nil }
        state = .starting
        guard connectivity.isConnected else { return fail(.offline) }
        let position: SharedPosition
        do {
            position = try await currentPosition()
        } catch {
            return fail(Self.locationFailure(error))
        }
        let share: LocationShare
        do {
            share = try await remote.start(at: position, durationMinutes: durationMinutes)
        } catch {
            return fail(Self.failure(for: error))
        }
        guard state == .starting else {
            // Se cerró sesión mientras empezaba: no dejar el enlace abierto.
            try? await remote.stop(share.id)
            return nil
        }
        state = .sharing(share, isOffline: false)
        say(LocationSharingAnnouncements.started(share, now: now()), key: "started")
        if runsUpdateLoop {
            loop = Task { [weak self] in await self?.keepSharing(share) }
        }
        return nil
    }

    // MARK: Mientras se comparte

    /// Una vuelta del ciclo de actualización. Pública para probar sin esperar el reloj.
    func keepSharing(_ share: LocationShare) async {
        while !Task.isCancelled {
            // Una espera cancelada (se detuvo o se cerró sesión) termina el ciclo.
            do { try await sleep(LocationSharingPolicy.updateInterval) } catch { return }
            guard !Task.isCancelled, case .sharing(let current, let wasOffline) = state,
                  current.id == share.id else { return }
            if now() >= share.expiresAt {
                end(saying: LocationSharingAnnouncements.expired)
                return
            }
            guard connectivity.isConnected else {
                markOffline(share, wasOffline: wasOffline)
                continue
            }
            // Una lectura de GPS que falla un momento no corta el uso compartido.
            guard let position = try? await currentPosition() else { continue }
            do {
                try await remote.update(share.id, to: position)
                guard case .sharing(let latest, _) = state, latest.id == share.id else { return }
                if wasOffline {
                    state = .sharing(share, isOffline: false)
                    say(LocationSharingAnnouncements.reconnected, key: "reconnected")
                }
            } catch HTTPClientError.statusCode(410) {
                end(saying: LocationSharingAnnouncements.expired)
                return
            } catch HTTPClientError.statusCode(404) {
                end(saying: LocationSharingAnnouncements.expired)
                return
            } catch {
                switch Self.failure(for: error) {
                case .offline:
                    markOffline(share, wasOffline: wasOffline)
                case .sessionRequired:
                    tokens?.clear()
                    end(saying: LocationSharingAnnouncements.failure(.sessionRequired))
                    return
                default:
                    // 5xx u otra falla pasajera: se reintenta en la siguiente vuelta.
                    continue
                }
            }
        }
    }

    // MARK: Detener

    func stop() async {
        guard case .sharing(let share, _) = state else { return }
        loop?.cancel()
        loop = nil
        state = .stopping
        do {
            try await remote.stop(share.id)
            state = .idle
            say(LocationSharingAnnouncements.stopped, key: "stopped")
        } catch HTTPClientError.statusCode(404) {
            state = .idle
            say(LocationSharingAnnouncements.stopped, key: "stopped")
        } catch {
            // Se deja de enviar igual; el enlace vence solo.
            state = .idle
            say(LocationSharingAnnouncements.stoppedOffline, key: "stopped")
        }
    }

    /// Cierre de sesión o eliminación de cuenta.
    func stopSharing() async {
        if state == .starting { state = .idle }
        await stop()
    }

    // MARK: Ayudas

    private func currentPosition() async throws -> SharedPosition {
        let coordinate = try await location.currentLocation()
        return SharedPosition(latitude: coordinate.latitude, longitude: coordinate.longitude, accuracyMeters: nil)
    }

    private func markOffline(_ share: LocationShare, wasOffline: Bool) {
        guard !wasOffline else { return }
        state = .sharing(share, isOffline: true)
        say(LocationSharingAnnouncements.offline, key: "offline")
    }

    private func end(saying text: String) {
        loop = nil
        state = .idle
        say(text, key: "ended")
    }

    private func fail(_ failure: LocationSharingFailure) -> LocationSharingFailure {
        if failure == .sessionRequired { tokens?.clear() }
        state = .idle
        say(LocationSharingAnnouncements.failure(failure), key: "failure")
        return failure
    }

    nonisolated static func locationFailure(_ error: Error) -> LocationSharingFailure {
        switch error {
        case RouteCreationError.locationPermissionDenied: return .locationPermissionDenied
        default: return .locationUnavailable
        }
    }

    nonisolated static func failure(for error: Error) -> LocationSharingFailure {
        switch error {
        case let urlError as URLError where urlError.isConnectivityFailure:
            return .offline
        case AuthenticationError.notSignedIn, AuthenticationError.sessionExpired,
             HTTPClientError.statusCode(401):
            return .sessionRequired
        case FeatureUnavailable.authentication, FeatureUnavailable.navigation:
            return .notConfigured
        case HTTPClientError.statusCode(409):
            return .noTrustedContacts
        case HTTPClientError.statusCode(502):
            return .deliveryFailed
        default:
            return .serviceUnavailable
        }
    }

    private func say(_ text: String, key: String) {
        guard let arbiter else { return }
        arbiter.cancel(contextIDs: [Self.contextID])
        arbiter.receive(AudioMessage(
            text: text,
            priority: .routeInformation,
            createdAt: now(),
            expiresAt: now().addingTimeInterval(30),
            contextID: Self.contextID,
            deduplicationKey: key
        ))
    }
}
