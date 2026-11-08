#if os(iOS)
import CoreLocation
import Foundation
import MapKit

/// Autocompletado con MKLocalSearchCompleter (el mismo de Mapas), sesgado a la zona del
/// usuario si ya hay una ubicación conocida. No pide permiso de ubicación por sí mismo.
@MainActor
final class MapKitDestinationSuggester: NSObject, DestinationSuggesting, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    private let locationManager = CLLocationManager()
    private let searchRadiusMeters: CLLocationDistance
    /// Consulta en espera de resultados; una nueva consulta cancela la anterior.
    private var pending: CheckedContinuation<[MKLocalSearchCompletion], Error>?
    /// Resultados de la última consulta, para resolver la sugerencia elegida.
    private var completionsByID: [String: MKLocalSearchCompletion] = [:]

    init(searchRadiusMeters: CLLocationDistance = 20_000) {
        self.searchRadiusMeters = searchRadiusMeters
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func suggestions(for query: String) async throws -> [DestinationSuggestion] {
        pending?.resume(throwing: CancellationError())
        pending = nil
        updateRegion()

        let completions: [MKLocalSearchCompletion]
        if completer.queryFragment == query, !completer.isSearching {
            // El completer no vuelve a avisar si la consulta no cambió.
            completions = completer.results
        } else {
            completions = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[MKLocalSearchCompletion], Error>) in
                pending = continuation
                completer.queryFragment = query
            }
        }

        var byID: [String: MKLocalSearchCompletion] = [:]
        let suggestions = completions.map { completion -> DestinationSuggestion in
            let suggestion = DestinationSuggestion(
                title: completion.title.trimmingCharacters(in: .whitespacesAndNewlines),
                subtitle: completion.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            if byID[suggestion.id] == nil { byID[suggestion.id] = completion }
            return suggestion
        }
        completionsByID = byID
        return suggestions
    }

    func place(for suggestion: DestinationSuggestion) async throws -> RoutePlace {
        guard let completion = completionsByID[suggestion.id] else {
            throw RouteCreationError.destinationNotFound
        }
        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        } catch let error as MKError where error.code == .placemarkNotFound {
            throw RouteCreationError.destinationNotFound
        } catch {
            throw RouteCreationError.serviceUnavailable
        }
        guard let item = response.mapItems.first,
              CLLocationCoordinate2DIsValid(item.placemark.coordinate) else {
            throw RouteCreationError.destinationNotFound
        }
        return RoutePlace(
            name: suggestion.title,
            coordinate: GeoCoordinate(
                latitude: item.placemark.coordinate.latitude,
                longitude: item.placemark.coordinate.longitude
            )
        )
    }

    /// Última ubicación conocida, solo si ya hay permiso: no interrumpe con el diálogo.
    private func updateRegion() {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            guard let location = locationManager.location else { return }
            completer.region = MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: searchRadiusMeters,
                longitudinalMeters: searchRadiusMeters
            )
        default:
            return
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in self.finish(.success(self.completer.results)) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.finish(.failure(RouteCreationError.serviceUnavailable)) }
    }

    private func finish(_ result: Result<[MKLocalSearchCompletion], Error>) {
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(with: result)
    }
}
#endif
