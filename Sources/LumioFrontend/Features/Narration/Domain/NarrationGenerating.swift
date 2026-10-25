protocol NarrationGenerating {
    func generate(context: String, language: String) async throws -> String
}
