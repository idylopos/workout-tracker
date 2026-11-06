import Foundation

enum LegacyBackupMigration {
    struct Result { let records: [BackupRecord]; let warnings: [String]; let pendingDrafts: Int }

    static func records(_ root: [String: BackupJSONValue], timeZoneID: String) throws -> Result {
        guard TimeZone(identifier: timeZoneID) != nil else { throw TrackingError.invalidTimeZone }
        guard let logs = root["workoutLogs"]?.object,
              let bodies = root["bodyLogs"]?.array, let weeklySleep = root["sleepLogs"]?.array else {
            throw BackupError.invalid("Legacy workout, body, or sleep records are missing or malformed.")
        }
        let drafts = try optionalObject(root["workoutDrafts"], label: "workout drafts")
        let nightlySleep = try optionalArray(root["dailySleepLogs"], label: "nightly sleep")
        let activities = try optionalArray(root["savedActivities"], label: "saved activities")
        let checkIns = try optionalObject(root["dailyCheckIns"], label: "daily check-ins")
        let settings = try optionalObject(root["settings"], label: "settings")
        let exerciseConfigs = try optionalObject(root["exerciseConfigs"], label: "exercise configurations")
        guard logs.count + drafts.count + bodies.count + weeklySleep.count + nightlySleep.count + activities.count + checkIns.count <= BackupImporter.maximumRecords else {
            throw BackupError.tooManyRecords
        }
        let oldCarry = (settings["builtInPlanRevision"]?.number ?? 1) < 2
        var records: [BackupRecord] = []
        var pendingCount = 0
        // Source definitions, when present, are retained. The current web exporter usually omits them.
        let definitions = try optionalObject(root["plans"], label: "plan definitions")
        for (id, plan) in definitions.sorted(by: { $0.key < $1.key }) {
            records.append(BackupRecord(id: id, category: .plans, payload: plan))
        }
        for (key, log) in logs.sorted(by: { $0.key < $1.key }) {
            var payload: [String: BackupJSONValue] = ["legacyKey": .string(key), "log": try normalizeWorkout(log, oldCarry: oldCarry)]
            if let draft = drafts[key] {
                let normalized = try normalizeWorkout(draft, oldCarry: oldCarry)
                // Even older edits are retained; only reliably newer/undated drafts are marked pending.
                let saved = instant(log["savedAt"]?.string)
                let edited = instant(draft["savedAt"]?.string)
                if let saved, let edited, edited <= saved { payload["archivedDraft"] = normalized }
                else { payload["pendingDraft"] = normalized; pendingCount += 1 }
            }
            addProvenance(&payload, timeZoneID: timeZoneID)
            let planID = log["planId"]?.string ?? "form-flow"
            records.append(BackupRecord(id: key, category: .workouts, payload: .object(payload),
                                        references: [BackupReference(category: .plans, id: planID, allowsMissing: true)]))
        }
        for (key, draft) in drafts.sorted(by: { $0.key < $1.key }) where logs[key] == nil {
            var payload: [String: BackupJSONValue] = ["legacyKey": .string(key), "log": try normalizeWorkout(draft, oldCarry: oldCarry)]
            addProvenance(&payload, timeZoneID: timeZoneID)
            records.append(BackupRecord(id: key, category: .drafts, payload: .object(payload), references: [
                BackupReference(category: .plans, id: draft["planId"]?.string ?? "form-flow", allowsMissing: true)
            ]))
        }
        var bodyOccurrences: [String: Int] = [:]
        for value in bodies {
            guard var body = value.object, validDate(body["date"]) else { throw invalid("body measurement date") }
            let weight = try optionalNonnegative(body["weight"], label: "body weight")
            let waist = try optionalNonnegative(body["waist"], label: "waist")
            guard weight != nil || waist != nil else { throw invalid("empty body measurement") }
            body["nativeWeightUnit"] = .string("kg"); body["nativeWaistUnit"] = .string("cm")
            addProvenance(&body, timeZoneID: timeZoneID)
            let date = body["date"]?.string ?? ""
            let occurrence = bodyOccurrences[date, default: 0]; bodyOccurrences[date] = occurrence + 1
            records.append(BackupRecord(id: "body:\(date):\(occurrence)", category: .body, payload: .object(body)))
        }
        for (kind, values) in [("weekly", weeklySleep), ("nightly", nightlySleep)] {
            var occurrences: [String: Int] = [:]
            for value in values {
                guard var sleep = value.object, validDate(sleep[kind == "weekly" ? "week" : "date"]),
                      let hours = sleep["hours"]?.number, hours.isFinite, (0...24).contains(hours) else {
                    throw invalid("sleep date or hours")
                }
                sleep["legacyFrequency"] = .string(kind)
                addProvenance(&sleep, timeZoneID: timeZoneID)
                let date = sleep[kind == "weekly" ? "week" : "date"]?.string ?? ""
                let occurrence = occurrences[date, default: 0]; occurrences[date] = occurrence + 1
                records.append(BackupRecord(id: "\(kind):\(date):\(occurrence)", category: .sleep, payload: .object(sleep)))
            }
        }
        for (index, value) in activities.enumerated() {
            try validateActivity(value, withSets: false)
            records.append(BackupRecord(id: value["id"]?.string ?? "activity:\(index)", category: .activities, payload: value))
        }
        for (date, value) in checkIns.sorted(by: { $0.key < $1.key }) {
            guard LocalTrainingDay.isValidDate(date), let entry = value.object,
                  ["open", "deferred", "skipped", "completed"].contains(entry["status"]?.string ?? "open") else { throw invalid("daily check-in") }
            if let unknown = entry["sleepUnknown"], case .bool = unknown {} else if entry["sleepUnknown"] != nil { throw invalid("sleep unknown answer") }
            for field in ["recoveryUnknown", "laterUnknown"] {
                if let list = entry[field], list.array == nil { throw invalid("unknown recovery answers") }
            }
            records.append(BackupRecord(id: date, category: .legacyCheckIns, payload: value))
        }
        // Normalize the web's built-in controls while retaining all additional settings.
        var normalizedSettings = settings
        normalizedSettings["block"] = .number(settings["block"]?.number == 2 ? 2 : 1)
        normalizedSettings["longRunWeek"] = .number(clampSetting(settings["longRunWeek"]?.number, maximum: 52))
        normalizedSettings["pullupStep"] = .number(clampSetting(settings["pullupStep"]?.number, maximum: 6))
        normalizedSettings["builtInPlanRevision"] = .number(2)
        var normalizedConfigs = exerciseConfigs
        if oldCarry, normalizedConfigs["suitcase-carry"]?.string == "weight_reps" { normalizedConfigs.removeValue(forKey: "suitcase-carry") }
        records.append(BackupRecord(id: "legacy-web-settings", category: .settings,
                                    payload: .object(["settings": .object(normalizedSettings), "exerciseConfigs": .object(normalizedConfigs)])))
        let knownKeys: Set<String> = ["version", "settings", "exerciseConfigs", "workoutLogs", "workoutDrafts", "bodyLogs", "sleepLogs", "dailySleepLogs", "dailyCheckIns", "savedActivities", "plans"]
        var warnings = ["Legacy dates did not record a time zone. \(timeZoneID) is retained as an import assumption.",
                        "Imported history will not be written to Apple Health automatically."]
        if !Set(root.keys).subtracting(knownKeys).isEmpty {
            warnings.append("Additional source fields are preserved in the original staged file; the restore UI must retain that provenance file.")
        }
        if oldCarry { warnings.append("Old suitcase-carry repetitions were interpreted as meters, matching the web migration.") }
        return Result(records: records, warnings: warnings, pendingDrafts: pendingCount)
    }

    private static func normalizeWorkout(_ value: BackupJSONValue, oldCarry: Bool) throws -> BackupJSONValue {
        guard var log = value.object, validDate(log["date"]), let sourceExercises = log["exercises"]?.object else {
            throw invalid("workout date or exercises")
        }
        if let planID = log["planId"], planID.string?.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) == nil {
            throw invalid("workout plan identity")
        }
        var exercises: [String: BackupJSONValue] = [:]
        for (id, exercise) in sourceExercises {
            exercises[id] = try normalizeExercise(exercise, oldCarry: oldCarry && id == "suitcase-carry")
        }
        log["exercises"] = .object(exercises)
        if let activities = log["extraActivities"] {
            guard let array = activities.array else { throw invalid("extra activities") }
            log["extraActivities"] = .array(try array.map { value in
                try validateActivity(value, withSets: true)
                return try normalizeExercise(value, oldCarry: false)
            })
        }
        if let value = log["response"] {
            guard var response = value.object else { throw invalid("workout recovery response") }
            let version = (response["scaleVersion"]?.number ?? 1) >= 2 ? 2 : 1
            for key in ["painDuring", "painLater", "painNext"] {
                if let normalized = LegacyRecovery.rating(response[key]?.number, scaleVersion: version) {
                    response[key] = .number(Double(normalized))
                }
            }
            response["scaleVersion"] = .number(2)
            log["response"] = .object(response)
        }
        log["nativeNormalizationVersion"] = .number(1)
        return .object(log)
    }

    private static func normalizeExercise(_ value: BackupJSONValue, oldCarry: Bool) throws -> BackupJSONValue {
        guard var exercise = value.object, let type = exercise["measurement"]?.string,
              MeasurementKind(rawValue: type) != nil, let sets = exercise["sets"]?.array else { throw invalid("exercise measurement or sets") }
        let migrateCarry = oldCarry && type == "weight_reps"
        let effectiveType = migrateCarry ? "weight_distance" : type
        if migrateCarry { exercise["measurement"] = .string(effectiveType) }
        exercise["sets"] = .array(try sets.map { value in
            guard var set = value.object else { throw invalid("exercise set") }
            if migrateCarry {
                if let reps = set["reps"], reps != .string("") { set["distance"] = reps }
                set.removeValue(forKey: "reps")
            }
            if let distance = set["distance"]?.number, distance.isFinite {
                let meters = effectiveType == "weight_distance" ? distance : distance * 1_000
                guard meters.isFinite else { throw invalid("distance") }
                set["nativeDistanceMeters"] = .number(meters)
                set["legacyDistanceUnit"] = .string(effectiveType == "weight_distance" ? "m" : "km")
            }
            if set["weight"]?.number != nil { set["nativeWeightUnit"] = .string("kg") }
            return .object(set)
        })
        return .object(exercise)
    }
    private static func validateActivity(_ value: BackupJSONValue, withSets: Bool) throws {
        guard let activity = value.object, let id = activity["id"]?.string,
              id.range(of: #"^[a-z0-9][a-z0-9-]{0,95}$"#, options: .regularExpression) != nil,
              let name = activity["name"]?.string, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              let type = activity["type"]?.string, ["walking", "cycling", "elliptical", "swimming", "running", "hiit", "custom"].contains(type),
              let measurement = activity["measurement"]?.string, ["duration", "duration_calories", "distance_time", "distance"].contains(measurement) else {
            throw invalid("saved activity")
        }
        if withSets { guard activity["sets"]?.array != nil else { throw invalid("activity sets") } }
        else if activity["sets"] != nil { throw invalid("saved activity contains workout sets") }
    }
    private static func addProvenance(_ value: inout [String: BackupJSONValue], timeZoneID: String) {
        value["legacyTimeZoneAssumption"] = .string(timeZoneID)
    }
    private static func optionalObject(_ value: BackupJSONValue?, label: String) throws -> [String: BackupJSONValue] {
        guard let value else { return [:] }; guard let object = value.object else { throw invalid(label) }; return object
    }
    private static func optionalArray(_ value: BackupJSONValue?, label: String) throws -> [BackupJSONValue] {
        guard let value else { return [] }; guard let array = value.array else { throw invalid(label) }; return array
    }
    private static func optionalNonnegative(_ value: BackupJSONValue?, label: String) throws -> Double? {
        guard let value, value != .null else { return nil }
        if let text = value.string, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        guard let number = value.number, number.isFinite, number >= 0 else { throw invalid(label) }
        return number
    }
    private static func validDate(_ value: BackupJSONValue?) -> Bool { value?.string.map(LocalTrainingDay.isValidDate) ?? false }
    private static func invalid(_ field: String) -> BackupError { .invalid("The legacy backup contains an invalid \(field). No data was restored.") }
    private static func instant(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
    private static func clampSetting(_ value: Double?, maximum: Double) -> Double {
        guard let value, value.isFinite, value != 0 else { return 1 }
        return min(maximum, max(1, value))
    }
}
