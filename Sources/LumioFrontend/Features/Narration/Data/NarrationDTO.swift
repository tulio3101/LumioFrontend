import Foundation

// Refleja el contrato actual de POST /narration del backend.
// Estos niveles NO se convierten automáticamente en prioridades P1/P2/P3.
enum NarrationPriorityDTO: String, Codable {
    case low, normal, urgent
}

struct NarrationRequestDTO: Encodable {
    let context: String
    let language: String
    let priority: NarrationPriorityDTO
}

struct NarrationResponseDTO: Decodable {
    let text: String
    let language: String
    let priority: NarrationPriorityDTO
}
