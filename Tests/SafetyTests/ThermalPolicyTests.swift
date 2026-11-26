import Testing
@testable import LumioFrontend

// SCRUM-321: política de rendimiento térmico. Núcleo puro y portable (sin ARKit/UIKit).
// Regla: nominal 15 fps, fair 10, serious 5, critical en pausa; Bajo Consumo baja un escalón;
// malla a 2-3 Hz encendida y apagada en serious/critical o con Bajo Consumo.

private let policy = ThermalPolicy()

@Test func nominalRunsAtFifteenFPSWithMesh() {
    let load = policy.load(for: .nominal, lowPowerMode: false)
    #expect(load.targetFPS == 15)
    #expect(load.isPaused == false)
    #expect(load.meshHz >= 2 && load.meshHz <= 3)   // malla a 2-3 Hz
}

@Test func fairReducesToTenFPS() {
    let load = policy.load(for: .fair, lowPowerMode: false)
    #expect(load.targetFPS == 10)
    #expect(load.isPaused == false)
}

@Test func seriousReducesToFiveFPSAndDropsMesh() {
    let load = policy.load(for: .serious, lowPowerMode: false)
    #expect(load.targetFPS == 5)
    #expect(load.isPaused == false)
    #expect(load.meshHz == 0)   // malla apagada
}

@Test func criticalPausesDetection() {
    let load = policy.load(for: .critical, lowPowerMode: false)
    #expect(load.isPaused == true)
    #expect(load.meshHz == 0)
}

// Bajo Consumo baja un escalón de carga respecto al estado térmico.
@Test func lowPowerModeStepsDownFromNominal() {
    let load = policy.load(for: .nominal, lowPowerMode: true)
    #expect(load.targetFPS == 10)   // como "fair"
    #expect(load.meshHz == 0)       // y sin malla, para gastar menos
}

@Test func lowPowerModeStepsDownFromFair() {
    let load = policy.load(for: .fair, lowPowerMode: true)
    #expect(load.targetFPS == 5)    // como "serious"
    #expect(load.meshHz == 0)
}

@Test func lowPowerModeDoesNotRaiseLoadAtSerious() {
    let normal = policy.load(for: .serious, lowPowerMode: false)
    let lowPower = policy.load(for: .serious, lowPowerMode: true)
    #expect(lowPower.targetFPS == normal.targetFPS)   // ya está en el mínimo
    #expect(lowPower.targetFPS == 5)
}

@Test func lowPowerModeStillPausesAtCritical() {
    #expect(policy.load(for: .critical, lowPowerMode: true).isPaused == true)
}

// La carga nunca sube al empeorar el estado térmico (monotonía).
@Test func loadNeverIncreasesAsThermalWorsens() {
    let levels: [ThermalLevel] = [.nominal, .fair, .serious, .critical]
    var previousFPS = Int.max
    for level in levels {
        let load = policy.load(for: level, lowPowerMode: false)
        let effectiveFPS = load.isPaused ? 0 : load.targetFPS
        #expect(effectiveFPS <= previousFPS, "los fps no deben subir al calentarse (\(level))")
        previousFPS = effectiveFPS
    }
}
