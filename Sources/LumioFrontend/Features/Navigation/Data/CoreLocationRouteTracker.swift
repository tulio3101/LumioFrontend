#if os(iOS)
import CoreLocation

/// Sigue la ubicación durante el trayecto, también con el teléfono bloqueado en el bolsillo
/// (SCRUM-127). Usa el permiso «mientras se usa» y el modo de fondo `location`: iOS muestra
/// el indicador azul mientras sigue.
@MainActor
final class CoreLocationRouteTracker: NSObject, LocationTracking, CLLocationManagerDelegate {
    var onFix: ((LocationFix) -> Void)?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        // Sin filtro de distancia: quien se detiene en el destino también recibe lecturas.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        default:
            // El permiso se pide al crear la ruta; sin él no se sigue.
            return
        }
        if Self.canUpdateInBackground {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        if Self.canUpdateInBackground {
            manager.allowsBackgroundLocationUpdates = false
        }
    }

    /// Activar el seguimiento en segundo plano sin `UIBackgroundModes = location` en el
    /// Info.plist cierra la app; sin esa clave solo se sigue con la app abierta.
    private static let canUpdateInBackground: Bool = {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("location") == true
    }()

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map {
            LocationFix(
                coordinate: GeoCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude),
                horizontalAccuracy: $0.horizontalAccuracy,
                // Negativa si CoreLocation no la conoce.
                speedMetersPerSecond: $0.speed >= 0 ? $0.speed : nil
            )
        }
        Task { @MainActor in
            for fix in fixes { self.onFix?(fix) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Una lectura fallida no detiene el seguimiento; CoreLocation sigue intentando.
    }
}
#endif
