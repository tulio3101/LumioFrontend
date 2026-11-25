#if os(iOS)
import CoreLocation

/// Ubicación para la alerta de emergencia con CLLocationManager. A diferencia de crear una
/// ruta, **nunca pide permiso**: un diálogo del sistema en plena emergencia estorba. Sin permiso
/// devuelve nil y la alerta sale sin ubicación. Acepta cualquier precisión (la informa) y, si no
/// llega una lectura a tiempo, usa la última posición conocida.
@MainActor
final class CoreLocationEmergencyLocator: NSObject, EmergencyLocating, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    /// Menos que el margen de 10 s para cancelar: la lectura llega antes de enviar.
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    init(timeout: TimeInterval = 8) {
        self.timeout = timeout
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func currentLocation() async -> EmergencyLocation? {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        default:
            return nil
        }
        // Una sola lectura a la vez: CLLocationManager entrega un único resultado.
        guard continuation == nil else { return nil }
        let fresh: CLLocation? = await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
            self.continuation = continuation
            manager.requestLocation()
            let seconds = timeout
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                self?.finish(nil)
            }
        }
        guard let location = fresh ?? manager.location,
              location.horizontalAccuracy >= 0,
              CLLocationCoordinate2DIsValid(location.coordinate) else {
            return nil
        }
        return EmergencyLocation(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracyMeters: location.horizontalAccuracy
        )
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        let last = locations.last
        Task { @MainActor in self.finish(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    /// Solo la primera respuesta cuenta: la lectura o el tiempo límite, lo que llegue antes.
    private func finish(_ location: CLLocation?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: location)
    }
}
#endif
