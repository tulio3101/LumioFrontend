#if os(iOS)
import CoreLocation

/// Obtiene una única posición con CLLocationManager (SCRUM-105).
/// Pide permiso "mientras se usa la app" la primera vez y rechaza lecturas imprecisas.
@MainActor
final class CoreLocationCurrentLocationProvider: NSObject, CurrentLocationProviding,
    CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    /// Valor inicial a validar en pruebas de campo.
    private let maximumAccuracyMeters: CLLocationAccuracy
    private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?

    init(maximumAccuracyMeters: CLLocationAccuracy = 100) {
        self.maximumAccuracyMeters = maximumAccuracyMeters
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
    }

    func currentLocation() async throws -> GeoCoordinate {
        switch await authorization() {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        case .denied, .restricted:
            throw RouteCreationError.locationPermissionDenied
        default:
            throw RouteCreationError.locationUnavailable
        }
        // Una sola petición a la vez: CLLocationManager entrega un único resultado.
        guard locationContinuation == nil else { throw RouteCreationError.locationUnavailable }
        let location: CLLocation = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<CLLocation, Error>) in
            locationContinuation = continuation
            manager.requestLocation()
        }
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= maximumAccuracyMeters,
              CLLocationCoordinate2DIsValid(location.coordinate) else {
            throw RouteCreationError.locationUnavailable
        }
        return GeoCoordinate(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude
        )
    }

    private func authorization() async -> CLAuthorizationStatus {
        let status = manager.authorizationStatus
        guard status == .notDetermined, authorizationContinuation == nil else { return status }
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<CLAuthorizationStatus, Never>) in
            authorizationContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined, let continuation = self.authorizationContinuation else {
                return
            }
            self.authorizationContinuation = nil
            continuation.resume(returning: status)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        Task { @MainActor in self.finish(.success(location)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        Task { @MainActor in
            self.finish(.failure(
                denied ? RouteCreationError.locationPermissionDenied : .locationUnavailable
            ))
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        continuation.resume(with: result)
    }
}
#endif
