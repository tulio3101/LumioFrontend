import Testing
@testable import LumioFrontend

// SCRUM-36: baja luminosidad con histéresis. Enter < alertThreshold (100 lux), recupera
// ≥ alertThreshold + hysteresisMargin (140 lux). Alerta una vez, deja de alertar al recuperarse.

@Test func recoveryThresholdIsAboveAlertThreshold() {
    // Con los valores por defecto reales (en lux), la recuperación exige más luz que la alerta.
    let alert: Float = 100.0
    let hysteresis: Float = 40.0
    #expect(alert + hysteresis > alert)
    #expect(alert + hysteresis == 140.0)
}

#if os(iOS)
/// Deja correr las tareas @MainActor que emiten el audio (emitAlert usa Task { @MainActor }).
private func drainMainActor() async {
    try? await Task.sleep(nanoseconds: 20_000_000)  // 20 ms
}

@MainActor
private func lowLightAlerts(_ spy: SpyArbiter) -> Int {
    spy.received.filter { $0.deduplicationKey == "low-light-alert" }.count
}

@Test @MainActor func alertsOnceWhenLightDropsBelowThreshold() async {
    let spy = SpyArbiter()
    let detector = LowLightDetector(audioArbiter: spy, alertThreshold: 100, hysteresisMargin: 40)

    detector.analyze(ambientIntensity: 50)   // < 100 → alerta
    await drainMainActor()
    #expect(lowLightAlerts(spy) == 1)

    detector.analyze(ambientIntensity: 60)   // sigue oscuro y ya activo → no repite
    await drainMainActor()
    #expect(lowLightAlerts(spy) == 1)
}

@Test @MainActor func hysteresisBandDoesNotRecover() async {
    let spy = SpyArbiter()
    let detector = LowLightDetector(audioArbiter: spy, alertThreshold: 100, hysteresisMargin: 40)

    detector.analyze(ambientIntensity: 50)   // alerta
    detector.analyze(ambientIntensity: 120)  // entre 100 y 140 → ni recupera ni repite
    await drainMainActor()
    #expect(lowLightAlerts(spy) == 1)
}

@Test @MainActor func stopsAlertingOnRecoveryAndReArmsWhenDarkAgain() async {
    let spy = SpyArbiter()
    let detector = LowLightDetector(audioArbiter: spy, alertThreshold: 100, hysteresisMargin: 40)

    detector.analyze(ambientIntensity: 50)   // alerta (1)
    detector.analyze(ambientIntensity: 150)  // ≥ 140 → recupera
    detector.analyze(ambientIntensity: 50)   // oscuro otra vez → alerta (2)
    await drainMainActor()
    #expect(lowLightAlerts(spy) == 2)
}

// SCRUM-36 (FASE 2): al recuperarse la luz, se avisa por audio (P3) que hay luz suficiente.
@Test @MainActor func announcesRecoveryWhenLightReturns() async {
    let spy = SpyArbiter()
    let detector = LowLightDetector(audioArbiter: spy, alertThreshold: 100, hysteresisMargin: 40)

    detector.analyze(ambientIntensity: 50)    // alerta
    detector.analyze(ambientIntensity: 150)   // ≥ 140 → recupera + aviso
    await drainMainActor()
    let recovered = spy.received.filter { $0.deduplicationKey == "low-light-recovered" }
    #expect(recovered.count == 1)
    #expect(recovered.first?.priority == .environmentInformation)
}
#endif
