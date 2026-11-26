#if os(iOS)
import Foundation
import MapKit

private extension GeoCoordinate {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

/// Convierte el destino confirmado (dirección o nombre de lugar) en una ubicación,
/// priorizando resultados cercanos al usuario.
struct MapKitDestinationGeocoder: DestinationGeocoding {
    var searchRadiusMeters: CLLocationDistance = 20_000

    func place(for query: String, near origin: GeoCoordinate) async throws -> RoutePlace {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        request.region = MKCoordinateRegion(
            center: origin.clCoordinate,
            latitudinalMeters: searchRadiusMeters,
            longitudinalMeters: searchRadiusMeters
        )
        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch let error as MKError where error.code == .placemarkNotFound {
            throw RouteCreationError.destinationNotFound
        } catch {
            throw RouteCreationError.serviceUnavailable
        }
        guard let item = response.mapItems.first,
              CLLocationCoordinate2DIsValid(item.placemark.coordinate) else {
            throw RouteCreationError.destinationNotFound
        }
        let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RoutePlace(
            name: (name?.isEmpty == false ? name : nil) ?? query,
            coordinate: GeoCoordinate(item.placemark.coordinate)
        )
    }
}

/// Calcula la ruta a pie con MKDirections (SCRUM-107). Las instrucciones llegan en el
/// idioma de la app (desarrollo en español).
struct MapKitWalkingRouteCalculator: WalkingRouteCalculating {
    func walkingRoute(from origin: RoutePlace, to destination: RoutePlace) async throws
        -> CalculatedRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate.clCoordinate))
        request.destination = MKMapItem(
            placemark: MKPlacemark(coordinate: destination.coordinate.clCoordinate)
        )
        request.transportType = .walking
        request.requestsAlternateRoutes = false

        let response: MKDirections.Response
        do {
            response = try await MKDirections(request: request).calculate()
        } catch let error as MKError where error.code == .directionsNotFound {
            throw RouteCreationError.noRouteAvailable
        } catch {
            throw RouteCreationError.serviceUnavailable
        }
        guard let route = response.routes.first else {
            throw RouteCreationError.noRouteAvailable
        }
        return CalculatedRoute(
            distanceMeters: route.distance,
            expectedTravelTimeSeconds: route.expectedTravelTime,
            steps: route.steps.map { step in
                CalculatedRouteStep(
                    instruction: step.instructions,
                    distanceMeters: step.distance,
                    maneuverCoordinate: step.polyline.firstCoordinate.map(GeoCoordinate.init)
                )
            }
        )
    }
}

private extension MKPolyline {
    var firstCoordinate: CLLocationCoordinate2D? {
        guard pointCount > 0 else { return nil }
        var coordinate = kCLLocationCoordinate2DInvalid
        getCoordinates(&coordinate, range: NSRange(location: 0, length: 1))
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }
}
/// SCRUM-313: lugares para el destino dictado, cerca del usuario y con su dirección para
/// leerlos en voz alta. Sin ubicación o sin red devuelve `.unavailable`: el dictado sigue con
/// el texto y Crear Ruta informa el fallo.
@MainActor
final class MapKitDestinationLookup: DestinationLookingUp {
    private let location: any CurrentLocationProviding
    var searchRadiusMeters: CLLocationDistance = 20_000

    init(location: any CurrentLocationProviding) {
        self.location = location
    }

    func lookUp(_ query: String) async -> DestinationLookup {
        let origin: GeoCoordinate
        do {
            origin = try await location.currentLocation()
        } catch {
            return .unavailable
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        request.region = MKCoordinateRegion(
            center: origin.clCoordinate,
            latitudinalMeters: searchRadiusMeters,
            longitudinalMeters: searchRadiusMeters
        )
        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch let error as MKError where error.code == .placemarkNotFound {
            return .notFound
        } catch {
            return .unavailable
        }
        let places = response.mapItems.compactMap { item -> SpokenPlace? in
            guard CLLocationCoordinate2DIsValid(item.placemark.coordinate) else { return nil }
            let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let placemark = item.placemark
            let street = [placemark.thoroughfare, placemark.subThoroughfare]
                .compactMap { $0 }.joined(separator: " ")
            let detail = [street.isEmpty ? nil : street, placemark.locality]
                .compactMap { $0 }
                .filter { $0 != name }
                .joined(separator: ", ")
            return SpokenPlace(
                place: RoutePlace(
                    name: (name?.isEmpty == false ? name : nil) ?? query,
                    coordinate: GeoCoordinate(placemark.coordinate)
                ),
                detail: detail.isEmpty ? nil : detail
            )
        }
        let options = DestinationDictationPolicy.options(places)
        return options.isEmpty ? .notFound : .found(options)
    }
}
#endif
