import Foundation

/// Repite la indicación actual con el mismo mensaje que la anunció: mismo contexto de la
/// revisión vigente y misma clave del paso. Así, si la indicación todavía espera turno o
/// está sonando, el árbitro no la duplica; si ya terminó, vuelve a sonar.
@MainActor
final class RouteInstructionRepeater: InstructionRepeating {
    private let arbiter: any AudioArbitrating
    private let instructions: NavigationInstructionBuilder
    private let now: () -> Date

    init(
        arbiter: any AudioArbitrating,
        instructions: NavigationInstructionBuilder = NavigationInstructionBuilder(),
        now: @escaping () -> Date = Date.init
    ) {
        self.arbiter = arbiter
        self.instructions = instructions
        self.now = now
    }

    @discardableResult
    func repeatCurrentInstruction(of route: ActiveRoute) -> Bool {
        guard let step = route.currentInstruction else { return false }
        arbiter.receive(instructions.message(for: step, in: route, now: now()))
        return true
    }
}
