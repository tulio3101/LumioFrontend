/// Punto de composición: construir aquí implementaciones y compartirlas por sesión.
/// Sustituir el servicio pendiente por MapKitNavigationService cuando exista.
@MainActor
struct AppDependencies {
    let navigationService: any NavigationPlanning
    #if canImport(AVFoundation)
    let audioArbiter: AudioArbiterService
    #endif
    #if os(iOS)
    /// nil si el modelo YOLO no está en el bundle (añadir yolo26n_640_int8.mlpackage a Copy Bundle Resources).
    let safetyService: SafetyService?
    #endif

    init(navigationService: any NavigationPlanning = UnavailableNavigationService()) {
        self.navigationService = navigationService
        #if canImport(AVFoundation)
        self.audioArbiter = AudioArbiterService(player: SpeechAudioPlayer())
        #endif
        #if os(iOS)
        if let runner = try? YOLORunner() {
            let pipeline = DetectionPipeline(
                frameSource: ARKitFrameSource(),
                runner: runner,
                lowLightDetector: LowLightDetector(audioArbiter: audioArbiter)
            )
            self.safetyService = SafetyService(pipeline: pipeline, audioArbiter: audioArbiter)
        } else {
            self.safetyService = nil
        }
        #endif
    }
}
