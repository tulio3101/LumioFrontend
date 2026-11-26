import Foundation
import Testing

// xtool (xtool.yml → infoPath) usa Resources/Info-xtool.plist tal cual, sin reemplazar las
// variables de Xcode. Sin estos valores fijos, el aprovisionamiento falla con
// "The attribute 'name' is invalid: 'XTool $(PRODUCT_BUNDLE_IDENTIFIER)'". El resto del archivo
// debe coincidir con Resources/Info.plist (la fuente de verdad de Xcode) para que los permisos y
// la configuración no se desincronicen entre los dos builds.

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // LumioFrontendTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent()

private let xcodeOnlyKeys: Set<String> = ["CFBundleExecutable", "CFBundleIdentifier", "CFBundleName"]

private func plist(_ relativePath: String) throws -> [String: Any] {
    let data = try Data(contentsOf: repoRoot.appendingPathComponent(relativePath))
    let object = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try #require(object as? [String: Any])
}

private func containsXcodeVariable(_ value: Any) -> Bool {
    switch value {
    case let text as String: return text.contains("$(")
    case let array as [Any]: return array.contains(where: containsXcodeVariable)
    case let dict as [String: Any]: return dict.values.contains(where: containsXcodeVariable)
    default: return false
    }
}

@Test func xtoolUsesItsOwnInfoPlist() throws {
    let config = try String(contentsOf: repoRoot.appendingPathComponent("xtool.yml"), encoding: .utf8)
    #expect(config.contains("infoPath: Resources/Info-xtool.plist"))
}

@Test func xtoolInfoPlistHasNoXcodeVariables() throws {
    let xtool = try plist("Resources/Info-xtool.plist")
    #expect(!containsXcodeVariable(xtool))
    #expect(xtool["CFBundleIdentifier"] as? String == "com.lumio.app")
    #expect(xtool["CFBundleExecutable"] as? String == "LumioFrontend")
}

@Test func xtoolInfoPlistMatchesTheXcodeInfoPlist() throws {
    let xcode = try plist("Resources/Info.plist")
    let xtool = try plist("Resources/Info-xtool.plist")
    #expect(Set(xcode.keys) == Set(xtool.keys))
    for key in Set(xcode.keys).subtracting(xcodeOnlyKeys) {
        let same = NSDictionary(dictionary: [key: xcode[key] as Any])
            .isEqual(to: [key: xtool[key] as Any])
        #expect(same, "\(key) difiere entre Info.plist e Info-xtool.plist")
    }
}
