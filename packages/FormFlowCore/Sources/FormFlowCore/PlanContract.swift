import Foundation

public enum PlanContract {
    public static let schemaVersion = 2
    public static var schemaJSON: String { resource("plan-v2.schema") }
    public static var exampleJSON: String { resource("plan-v2.example") }

    private static func resource(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            // Resource presence and validity are release-blocking contract tests.
            return "The bundled plan contract is unavailable. Reinstall the app before generating a plan prompt."
        }
        return content
    }
}
