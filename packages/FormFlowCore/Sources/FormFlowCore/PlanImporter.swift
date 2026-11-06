import Foundation

public enum PlanImporter {
    public static let maximumBytes = 1_048_576

    public static func importText(_ text: String) -> PlanImportResult {
        guard text.utf8.count <= maximumBytes else {
            return failure("file", "This plan is larger than the 1 MiB import limit. The original text has not been changed.")
        }
        do {
            let candidate = try extractObject(text)
            let data = Data(candidate.utf8)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return failure("file", "Paste a single weekly-plan JSON object.")
            }
            var keyScanner = DuplicateKeyScanner(candidate)
            if let duplicate = keyScanner.findDuplicate() {
                return failure("file", "The JSON repeats the key '\(duplicate)'. Remove the duplicate rather than relying on one value overwriting another.")
            }
            if object["workoutLogs"] != nil || object["bodyLogs"] != nil {
                return failure("file", "This is a workout backup, not a weekly plan. Keep the original file for the data-restore flow.")
            }
            let version = try JSONDecoder().decode(VersionHeader.self, from: data).schemaVersion
            switch version {
            case 2:
                let unknown = unknownFieldIssues(object, legacy: false)
                guard unknown.isEmpty else { return PlanImportResult(plan: nil, issues: unknown) }
                let plan = try JSONDecoder().decode(WeeklyPlan.self, from: data)
                return PlanImportResult(plan: plan, issues: PlanValidator.validate(plan), sourceVersion: 2)
            case 1:
                let unknown = unknownFieldIssues(object, legacy: true)
                guard unknown.isEmpty else { return PlanImportResult(plan: nil, issues: unknown) }
                let legacy = try JSONDecoder().decode(LegacyPlan.self, from: data)
                return legacy.convert()
            default:
                return failure("schemaVersion", "Plan version \(version) is not supported. Ask for version 2, or import an existing version-1 plan.")
            }
        } catch let error as ImportFailure {
            return failure("file", error.message)
        } catch let error as DecodingError {
            return decodingFailure(error)
        } catch {
            return failure("file", "The response is not valid JSON. Keep the original response and ask your AI to return one complete JSON object.")
        }
    }

    private static func failure(_ path: String, _ message: String) -> PlanImportResult {
        PlanImportResult(plan: nil, issues: [PlanIssue(path: path, message: message)])
    }

    private struct VersionHeader: Decodable { let schemaVersion: Int }
    private struct ImportFailure: Error { let message: String }

    private static func decodingFailure(_ error: DecodingError) -> PlanImportResult {
        let context: DecodingError.Context
        let message: String
        var missingKey: String?
        switch error {
        case .keyNotFound(let key, let value):
            context = value; missingKey = key.stringValue; message = "This required field is missing."
        case .typeMismatch(_, let value):
            context = value; message = "This field has the wrong JSON type. Check the contract and use a number, text, object, or list as specified."
        case .valueNotFound(_, let value):
            context = value; message = "This required field cannot be null."
        case .dataCorrupted(let value):
            context = value; message = "This value is not supported. Check the permitted measurement, unit, weekday, and effort values."
        @unknown default:
            return failure("file", "The plan could not be decoded. Check it against the supplied contract.")
        }
        var path = context.codingPath.reduce("") { result, key in
            if let index = key.intValue { return result + "[\(index)]" }
            return result.isEmpty ? key.stringValue : result + "." + key.stringValue
        }
        if let missingKey { path += path.isEmpty ? missingKey : "." + missingKey }
        return failure(path.isEmpty ? "file" : path, message)
    }

    /// Allows explanatory text around one object, but never chooses between multiple candidates.
    private static func extractObject(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportFailure(message: "Paste your AI response or choose a plan file.") }
        guard !trimmed.hasPrefix("[") else { throw ImportFailure(message: "The response must be one plan object, not an array of plans.") }
        // A raw object is parsed in full, including trailing content. Its quoted text may
        // legitimately contain braces or Markdown fences and must not be reinterpreted.
        if trimmed.hasPrefix("{") { return trimmed }
        let fences = trimmed.components(separatedBy: "```")
        if fences.count != 1 && fences.count != 3 {
            throw ImportFailure(message: "Paste one complete JSON object or one JSON code block. Multiple or incomplete code blocks are ambiguous.")
        }
        if fences.count == 3 {
            let block = fences[1]
            let firstLine = block.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
            if !firstLine.isEmpty && firstLine.lowercased() != "json" && !firstLine.hasPrefix("{") {
                throw ImportFailure(message: "Use a JSON code block, not a different code language.")
            }
        }
        var depth = 0
        var inString = false
        var escaped = false
        var start: String.Index?
        var candidates: [String] = []
        for index in trimmed.indices {
            let character = trimmed[index]
            if depth > 0 && inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if depth > 0 && character == "\"" { inString = true; continue }
            if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}" && depth == 0 {
                throw ImportFailure(message: "The response contains an unmatched closing brace. Paste one complete JSON object.")
            } else if character == "}" && depth > 0 {
                depth -= 1
                if depth == 0, let start { candidates.append(String(trimmed[start...index])) }
            }
        }
        guard depth == 0, !inString else { throw ImportFailure(message: "The JSON object is incomplete. Paste the full response, including its closing braces.") }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw ImportFailure(message: candidates.isEmpty ? "No weekly-plan JSON object was found." : "More than one JSON object was found. Paste only the plan you want to review.")
        }
        if trimmed.hasPrefix("{"), candidate != trimmed {
            throw ImportFailure(message: "There is extra content after the JSON object. Paste only the complete plan object.")
        }
        if fences.count == 3 {
            var body = fences[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if body.lowercased().hasPrefix("json"), let newline = body.firstIndex(where: \.isNewline) {
                body = String(body[body.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard body == candidate else {
                throw ImportFailure(message: "The JSON code block must contain only one complete plan object.")
            }
        }
        return candidate
    }

    private static func unknownFieldIssues(_ root: [String: Any], legacy: Bool) -> [PlanIssue] {
        var issues: [PlanIssue] = []
        func check(_ object: [String: Any], allowed: Set<String>, path: String) {
            for key in object.keys.sorted() where !allowed.contains(key) {
                issues.append(PlanIssue(path: path.isEmpty ? key : "\(path).\(key)", message: "This field is not supported in this plan version. Ask for a compatible prescription; it will not be silently discarded."))
            }
        }
        func checkTarget(_ target: [String: Any], path: String) {
            check(target, allowed: ["sets", "restSeconds", "reps", "load", "assistance", "duration", "distance", "calories", "effort"], path: path)
            let fields: [(String, Set<String>)] = [("reps", ["min", "max"]), ("load", ["value", "unit"]), ("assistance", ["value", "unit"]), ("duration", ["min", "max", "unit"]), ("distance", ["min", "max", "unit"]), ("calories", ["min", "max", "unit"]), ("effort", ["kind", "min", "max"])]
            for (field, allowed) in fields {
                if let value = target[field] as? [String: Any] { check(value, allowed: allowed, path: "\(path).\(field)") }
            }
        }
        func checkIntervals(_ blocks: Any?, path: String) {
            for (bi, block) in (blocks as? [[String: Any]] ?? []).enumerated() {
                let bp = "\(path)[\(bi)]"
                check(block, allowed: ["id", "repeatCount", "steps"], path: bp)
                for (si, step) in (block["steps"] as? [[String: Any]] ?? []).enumerated() {
                    let sp = "\(bp).steps[\(si)]"
                    check(step, allowed: ["id", "kind", "measurement", "target", "instructions"], path: sp)
                    if let target = step["target"] as? [String: Any] { checkTarget(target, path: "\(sp).target") }
                }
            }
        }
        if legacy {
            check(root, allowed: ["schemaVersion", "id", "name", "description", "days", "longRuns", "longRunDay"], path: "")
            if let days = root["days"] as? [String: Any] {
                for (day, value) in days {
                    guard let object = value as? [String: Any] else { continue }
                    if Weekday(rawValue: day) == nil { issues.append(PlanIssue(path: "days.\(day)", message: "Use a lowercase weekday from monday to sunday.")) }
                    check(object, allowed: ["label", "short", "focus", "kicker", "estimate", "tone", "sequenceNote", "warmup", "exercises"], path: "days.\(day)")
                    for (index, exercise) in (object["exercises"] as? [[String: Any]] ?? []).enumerated() {
                        let path = "days.\(day).exercises[\(index)]"
                        check(exercise, allowed: ["id", "name", "prescription", "sets", "rest", "measurement", "category", "section", "optional", "guidance"], path: path)
                        if let guidance = exercise["guidance"] as? [String: Any] {
                            check(guidance, allowed: ["setup", "action", "watch", "option"], path: "\(path).guidance")
                        }
                    }
                }
            }
            return issues
        }
        check(root, allowed: ["schemaVersion", "id", "name", "assumptions", "days", "instructions"], path: "")
        for (di, day) in (root["days"] as? [[String: Any]] ?? []).enumerated() {
            let dp = "days[\(di)]"
            check(day, allowed: ["weekday", "sessions"], path: dp)
            for (si, session) in (day["sessions"] as? [[String: Any]] ?? []).enumerated() {
                let sp = "\(dp).sessions[\(si)]"
                check(session, allowed: ["id", "name", "kind", "estimatedMinutes", "warmup", "exercises", "instructions"], path: sp)
                for (ei, exercise) in (session["exercises"] as? [[String: Any]] ?? []).enumerated() {
                    let ep = "\(sp).exercises[\(ei)]"
                    check(exercise, allowed: ["instanceId", "exerciseId", "name", "measurement", "equipment", "target", "optional", "instructions", "progressionPolicy", "alternatives", "intervals"], path: ep)
                    if let target = exercise["target"] as? [String: Any] {
                        checkTarget(target, path: "\(ep).target")
                    }
                    checkIntervals(exercise["intervals"], path: "\(ep).intervals")
                    for (ai, alternative) in (exercise["alternatives"] as? [[String: Any]] ?? []).enumerated() {
                        let ap = "\(ep).alternatives[\(ai)]"
                        check(alternative, allowed: ["id", "exerciseId", "name", "measurement", "equipment", "target", "instructions", "intervals"], path: ap)
                        if let target = alternative["target"] as? [String: Any] { checkTarget(target, path: "\(ap).target") }
                        checkIntervals(alternative["intervals"], path: "\(ap).intervals")
                    }
                    if let policy = exercise["progressionPolicy"] as? [String: Any] {
                        check(policy, allowed: ["id", "version", "notes"], path: "\(ep).progressionPolicy")
                    }
                }
            }
        }
        return issues
    }
}

private struct LegacyPlan: Decodable {
    var schemaVersion: Int
    var id: String
    var name: String
    var description: String?
    var days: [String: LegacyDay]
    var longRuns: [String]?
    var longRunDay: Weekday?

    func convert() -> PlanImportResult {
        var converted: [PlanDay] = []
        var sourceIssues: [PlanIssue] = []
        for weekday in Weekday.allCases {
            guard let day = days[weekday.rawValue] else { continue }
            let exercises = day.exercises.enumerated().map { index, exercise in
                if let guidance = exercise.guidance {
                    for (field, value) in [("setup", guidance.setup), ("action", guidance.action), ("watch", guidance.watch), ("option", guidance.option)] {
                        if let value, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.count > 500 {
                            sourceIssues.append(PlanIssue(path: "days.\(weekday.rawValue).exercises[\(index)].guidance.\(field)", message: "Legacy guidance must contain 1–500 characters when supplied."))
                        }
                    }
                }
                return PlanExercise(instanceId: "legacy-\(index + 1)", exerciseId: exercise.id, name: exercise.name,
                    measurement: exercise.measurement, target: ExerciseTarget(sets: exercise.sets, restSeconds: exercise.rest),
                    optional: exercise.optional ?? false, instructions: exercise.instructions)
            }
            let sessionNotes = [day.estimate.map { "Original duration estimate: \($0)" }, day.sequenceNote, day.kicker]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            let sessions = exercises.isEmpty ? [] : [PlanSession(id: "legacy-\(weekday.rawValue)",
                name: day.focus ?? day.label ?? weekday.displayName, kind: "mixed", estimatedMinutes: 0,
                warmup: day.warmup ?? [], exercises: exercises, instructions: sessionNotes.isEmpty ? nil : sessionNotes)]
            converted.append(PlanDay(weekday: weekday, sessions: sessions))
        }
        var planNotes = [description].compactMap { $0 }
        if let longRuns, !longRuns.isEmpty {
            let day = longRunDay?.displayName ?? "Saturday"
            planNotes.append("Original long-run stages (\(day)); review and manage manually:\n" + longRuns.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        }
        let plan = WeeklyPlan(id: id, name: name, assumptions: [], days: converted,
            instructions: planNotes.isEmpty ? nil : planNotes.joined(separator: "\n\n"))
        var issues = sourceIssues + PlanValidator.validate(plan, legacy: true)
        issues.append(PlanIssue(path: "schemaVersion", message: "Legacy plan imported for manual review. Original prescriptions and guidance are preserved as text; numerical targets and duration estimates have not been guessed. Progression is manual.", severity: .warning))
        return PlanImportResult(plan: plan, issues: issues, sourceVersion: 1)
    }
}

private struct LegacyDay: Decodable {
    var label: String?
    var focus: String?
    var kicker: String?
    var estimate: String?
    var sequenceNote: String?
    var warmup: [String]?
    var exercises: [LegacyExercise]
}

private struct LegacyExercise: Decodable {
    var id: String
    var name: String
    var prescription: String?
    var sets: Int
    var rest: Int
    var measurement: MeasurementKind
    var category: String?
    var section: String?
    var optional: Bool?
    var guidance: LegacyGuidance?
    var instructions: String? {
        let values = [prescription, category.map { "Category: \($0)" }, section.map { "Section: \($0)" }, guidance?.text]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: "\n")
    }
}

private struct LegacyGuidance: Decodable {
    var setup: String
    var action: String
    var watch: String
    var option: String?
    var text: String {
        (["Setup: \(setup)", "Action: \(action)", "Watch: \(watch)"] + (option.map { ["Option: \($0)"] } ?? [])).joined(separator: "\n")
    }
}

/// JSONSerialization/JSONDecoder accept duplicate keys. Detect them before either value is trusted.
private struct DuplicateKeyScanner {
    let characters: [Character]
    var index = 0
    var duplicate: String?
    init(_ text: String) { characters = Array(text) }
    mutating func findDuplicate() -> String? { parseValue(); return duplicate }
    mutating func whitespace() { while index < characters.count && characters[index].isWhitespace { index += 1 } }
    mutating func parseValue() {
        whitespace()
        guard index < characters.count else { return }
        switch characters[index] {
        case "{":
            index += 1
            var keys = Set<String>()
            whitespace()
            while index < characters.count && characters[index] != "}" {
                let key = parseString()
                if !keys.insert(key).inserted { duplicate = key }
                whitespace(); index += 1 // colon; JSON validity was already established
                parseValue(); whitespace()
                if index < characters.count && characters[index] == "," { index += 1; whitespace() }
            }
            index += 1
        case "[":
            index += 1; whitespace()
            while index < characters.count && characters[index] != "]" {
                parseValue(); whitespace()
                if index < characters.count && characters[index] == "," { index += 1 }
            }
            index += 1
        case "\"": _ = parseString()
        default:
            while index < characters.count && !characters[index].isWhitespace && ![",", "]", "}"].contains(characters[index]) { index += 1 }
        }
    }
    mutating func parseString() -> String {
        let start = index
        index += 1
        var escaped = false
        while index < characters.count {
            let character = characters[index]
            index += 1
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" { break }
        }
        let raw = String(characters[start..<min(index, characters.count)])
        return (try? JSONDecoder().decode(String.self, from: Data(raw.utf8))) ?? raw
    }
}
