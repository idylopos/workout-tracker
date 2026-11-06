import SwiftUI
import Charts
import FormFlowCore

struct TrackingHomeView: View {
    @Environment(AppStore.self) private var store
    @State private var sleepEditor: SleepEditorSelection?
    @State private var bodyEditor: BodyEditorSelection?

    var body: some View {
        List {
            Section("Add an entry") {
                Button("Log sleep", systemImage: "bed.double") { sleepEditor = SleepEditorSelection(record: nil) }
                Button("Log body measurements", systemImage: "figure") { bodyEditor = BodyEditorSelection(record: nil) }
                NavigationLink { TrainingTrendsView() } label: { Label("View trends", systemImage: "chart.xyaxis.line") }
            }
            Section("Sleep history") {
                if store.sleepRecords.isEmpty {
                    Text("No sleep entries yet. A missing night is not counted as zero hours.").foregroundStyle(.secondary)
                }
                ForEach(store.sleepRecords.sorted(by: trackingNewestSleep)) { record in
                    Button { sleepEditor = SleepEditorSelection(record: record) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Night ending \(trackingDayLabel(record.day))").foregroundStyle(.primary)
                            Text(record.hours.map { "\(trackingNumber($0)) hours" } ?? "Unknown · explicitly recorded")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text(record.day.timeZoneID).font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityHint("Edit this saved sleep entry")
                }
            }
            Section("Body measurements") {
                if store.bodyRecords.isEmpty {
                    Text("No body measurements yet. Weight and waist are both optional; record only what you know.").foregroundStyle(.secondary)
                }
                ForEach(store.bodyRecords.sorted(by: trackingNewestBody)) { record in
                    Button { bodyEditor = BodyEditorSelection(record: record) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(trackingDayLabel(record.day)).foregroundStyle(.primary)
                            if let weight = record.weight { Text("Weight · \(trackingNumber(weight.value)) \(weight.unit.rawValue)").font(.subheadline).foregroundStyle(.secondary) }
                            if let waist = record.waist { Text("Waist · \(trackingNumber(waist.value)) \(waist.unit == .cm ? "cm" : "in")").font(.subheadline).foregroundStyle(.secondary) }
                            Text(record.day.timeZoneID).font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityHint("Edit this saved measurement entry")
                }
            }
            Section("Recovery responses") {
                if store.recoveryRecords.isEmpty { Text("No recovery responses recorded.").foregroundStyle(.secondary) }
                ForEach(store.recoveryRecords.sorted { $0.updatedAt > $1.updatedAt }) { record in
                    if let workout = store.workouts.first(where: { $0.id == record.sessionID }) {
                        NavigationLink {
                            RecoveryRecordForm(workout: workout, phase: record.phase, existing: record)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(workout.prescription.name).font(.headline)
                                Text("\(recoveryPhaseLabel(record.phase)) · \(trackingDayLabel(record.day))").font(.caption).foregroundStyle(.secondary)
                                Text(recoveryReadinessLabel(record.effectiveReadiness)).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Recovery for an unavailable workout")
                            Text("\(recoveryPhaseLabel(record.phase)) · \(trackingDayLabel(record.day))").font(.caption).foregroundStyle(.secondary)
                            Text(recoveryReadinessLabel(record.effectiveReadiness)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            SaveErrorSection()
        }
        .formFlowBackground()
        .navigationTitle("Sleep & recovery")
        .sheet(item: $sleepEditor) { selection in NavigationStack { SleepRecordEditor(record: selection.record) } }
        .sheet(item: $bodyEditor) { selection in NavigationStack { BodyRecordEditor(record: selection.record) } }
    }
}

private struct SleepEditorSelection: Identifiable { let id = UUID(); let record: ManualSleepRecord? }
private struct BodyEditorSelection: Identifiable { let id = UUID(); let record: BodyMeasurementRecord? }

private struct SleepRecordEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var hours: String
    @State private var unknown: Bool
    @State private var entryID: UUID
    @State private var original: ManualSleepRecord?
    @State private var localError: String?
    @State private var timeZoneID: String

    init(record: ManualSleepRecord?) {
        let zone = record?.day.timeZoneID ?? TimeZone.current.identifier
        let day = record?.day ?? LocalTrainingDay(instant: Date(), timeZone: TimeZone(identifier: zone) ?? .current)
        _timeZoneID = State(initialValue: zone)
        _date = State(initialValue: trackingDisplayDate(day.date))
        _hours = State(initialValue: record?.hours.map { String($0) } ?? "")
        _unknown = State(initialValue: record != nil && record?.hours == nil)
        _entryID = State(initialValue: record?.id ?? UUID())
        _original = State(initialValue: record)
    }

    private var parsedHours: Double? { trackingParseNumber(hours).flatMap { (0...24).contains($0) ? $0 : nil } }
    private var duplicate: ManualSleepRecord? {
        store.sleepRecords.filter { $0.id != entryID && $0.day.date == trackingDateString(date) }
            .max { $0.updatedAt < $1.updatedAt }
    }

    var body: some View {
        Form {
            Section {
                DatePicker("Night ending", selection: $date, in: ...trackingTodayDisplayDate(timeZoneID), displayedComponents: .date)
                    .environment(\.timeZone, .gmt)
                LabeledContent("Recorded time zone", value: timeZoneID)
            } footer: { Text("The date is the morning after this sleep. Editing retains the saved time zone, even when you travel.") }
            Section {
                Toggle("I don't know how long I slept", isOn: $unknown)
                if !unknown { TextField("Hours slept", text: $hours).keyboardType(.decimalPad) }
                if !unknown && !hours.isEmpty && parsedHours == nil {
                    Text("Enter hours from 0 to 24, or choose unknown.").foregroundStyle(.red).font(.caption)
                }
            } header: { Text("Your estimate") }
            footer: { Text("A blank field is not zero. Unknown entries are excluded from sleep averages.") }
            if let duplicate {
                Section("An entry already exists for this date") {
                    Text("Edit the saved entry to keep one answer for this night. Switching entries leaves your current form changes unsaved.")
                    Button("Edit the existing entry") {
                        original = duplicate
                        entryID = duplicate.id
                        timeZoneID = duplicate.day.timeZoneID
                        hours = duplicate.hours.map { String($0) } ?? ""
                        unknown = duplicate.hours == nil
                    }
                }
            }
            if let localError { Section { Text(localError).foregroundStyle(.red) } }
            SaveErrorSection()
        }
        .formFlowBackground()
        .navigationTitle(original == nil ? "Log sleep" : "Edit sleep")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled((!unknown && parsedHours == nil) || duplicate != nil)
            }
        }
    }

    private func save() {
        do {
            let day = try LocalTrainingDay(date: trackingDateString(date), timeZoneID: timeZoneID)
            let record = try ManualSleepRecord(id: entryID, day: day, hours: unknown ? nil : parsedHours)
            if store.saveSleep(record) { dismiss() }
        } catch { localError = error.localizedDescription }
    }
}

private struct BodyRecordEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var weight: String
    @State private var waist: String
    @State private var weightUnit: PlanUnit
    @State private var waistUnit: BodyLength.Unit
    @State private var localError: String?
    @State private var didSetInitialUnits = false
    @State private var original: BodyMeasurementRecord?
    @State private var entryID: UUID
    @State private var timeZoneID: String

    init(record: BodyMeasurementRecord?) {
        _original = State(initialValue: record); _entryID = State(initialValue: record?.id ?? UUID())
        let zone = record?.day.timeZoneID ?? TimeZone.current.identifier
        _timeZoneID = State(initialValue: zone)
        _date = State(initialValue: trackingDisplayDate((record?.day ?? LocalTrainingDay(instant: Date(), timeZone: TimeZone(identifier: zone) ?? .current)).date))
        _weight = State(initialValue: record?.weight.map { String($0.value) } ?? "")
        _waist = State(initialValue: record?.waist.map { String($0.value) } ?? "")
        _weightUnit = State(initialValue: record?.weight?.unit ?? .kg)
        _waistUnit = State(initialValue: record?.waist?.unit ?? .cm)
    }

    private var hasWeight: Bool { !weight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasWaist: Bool { !waist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var duplicate: BodyMeasurementRecord? {
        store.bodyRecords.filter { $0.id != entryID && $0.day.date == trackingDateString(date) }
            .max { $0.updatedAt < $1.updatedAt }
    }
    private var valid: Bool {
        (hasWeight || hasWaist)
        && (!hasWeight || trackingParseNumber(weight).map { $0 >= 0 } == true)
        && (!hasWaist || trackingParseNumber(waist).map { $0 >= 0 } == true)
    }
    var body: some View {
        Form {
            Section {
                DatePicker("Measurement date", selection: $date, in: ...trackingTodayDisplayDate(timeZoneID), displayedComponents: .date)
                    .environment(\.timeZone, .gmt)
                LabeledContent("Recorded time zone", value: timeZoneID)
            }
            if let duplicate {
                Section("Measurements already exist for this date") {
                    Text("Edit that entry to preserve both readings. Switching entries leaves your current form changes unsaved.")
                    Button("Edit the existing entry") {
                        original = duplicate
                        entryID = duplicate.id
                        timeZoneID = duplicate.day.timeZoneID
                        weight = duplicate.weight.map { String($0.value) } ?? ""
                        waist = duplicate.waist.map { String($0.value) } ?? ""
                        weightUnit = duplicate.weight?.unit ?? (store.profile.units == .imperial ? .lb : .kg)
                        waistUnit = duplicate.waist?.unit ?? (store.profile.units == .imperial ? .inch : .cm)
                    }
                }
            }
            Section("Weight · optional") {
                TextField("Measured weight", text: $weight).keyboardType(.decimalPad)
                Picker("Weight unit", selection: $weightUnit) {
                    Text("Kilograms (kg)").tag(PlanUnit.kg)
                    Text("Pounds (lb)").tag(PlanUnit.lb)
                }
                if original?.weight != nil {
                    Text("Clearing this field removes the weight from this entry when saved.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Waist · optional") {
                TextField("Measured waist", text: $waist).keyboardType(.decimalPad)
                Picker("Waist unit", selection: $waistUnit) {
                    Text("Centimeters (cm)").tag(BodyLength.Unit.cm)
                    Text("Inches (in)").tag(BodyLength.Unit.inch)
                }
                if original?.waist != nil {
                    Text("Clearing this field removes the waist measurement from this entry when saved.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Enter at least one measurement. Blank means not recorded. Changing a unit keeps the entered number; check the number before saving.")
                    .font(.caption).foregroundStyle(.secondary)
                if (hasWeight || hasWaist) && !valid {
                    Text("Enter zero or a positive number in each filled field.").foregroundStyle(.red).font(.caption)
                }
            }
            if let localError { Section { Text(localError).foregroundStyle(.red) } }
            SaveErrorSection()
        }
        .formFlowBackground()
        .navigationTitle(original == nil ? "Body measurements" : "Edit measurements")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!valid || duplicate != nil) }
        }
        .onAppear {
            if !didSetInitialUnits && original == nil && weight.isEmpty && waist.isEmpty {
                weightUnit = store.profile.units == .imperial ? .lb : .kg
                waistUnit = store.profile.units == .imperial ? .inch : .cm
            }
            didSetInitialUnits = true
        }
    }

    private func save() {
        do {
            let day = try LocalTrainingDay(date: trackingDateString(date), timeZoneID: timeZoneID)
            let weightValue = hasWeight ? trackingParseNumber(weight).map { PlanQuantity(value: $0, unit: weightUnit) } : nil
            let waistValue = hasWaist ? trackingParseNumber(waist).map { BodyLength(value: $0, unit: waistUnit) } : nil
            let record = try BodyMeasurementRecord(id: entryID, day: day, weight: weightValue, waist: waistValue)
            if store.saveBody(record) { dismiss() }
        } catch { localError = error.localizedDescription }
    }
}

struct RecoveryEntryView: View {
    @Environment(AppStore.self) private var store
    let prompt: RecoveryPrompt
    var body: some View {
        if let workout = store.workouts.first(where: { $0.id == prompt.sessionID }) {
            RecoveryRecordForm(workout: workout, phase: prompt.phase,
                               existing: store.recoveryRecords.filter { $0.sessionID == prompt.sessionID && $0.phase == prompt.phase }.max { $0.updatedAt < $1.updatedAt })
        } else {
            ContentUnavailableView("Workout unavailable", systemImage: "exclamationmark.circle", description: Text("This check-in belongs to a specific workout. Return to Today after its record is available."))
        }
    }
}

private struct RecoveryRecordForm: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let workout: WorkoutSession
    let phase: RecoveryPhase
    @State private var entryID: UUID
    private let existing: SessionRecoveryRecord?
    @State private var date: Date
    @State private var rating: Int?
    @State private var readiness: RecoveryReadiness
    @State private var notes: String
    @State private var localError: String?

    init(workout: WorkoutSession, phase: RecoveryPhase, existing: SessionRecoveryRecord?) {
        self.workout = workout; self.phase = phase; self.existing = existing
        _entryID = State(initialValue: existing?.id ?? UUID())
        let zone = TimeZone(identifier: workout.timeZoneIdentifier) ?? .gmt
        let today = LocalTrainingDay(instant: Date(), timeZone: zone)
        _date = State(initialValue: trackingDisplayDate(existing?.day.date ?? today.date))
        _rating = State(initialValue: existing?.rating)
        _readiness = State(initialValue: existing?.readiness ?? .unknown)
        _notes = State(initialValue: existing?.notes ?? "")
    }

    private var sessionDay: LocalTrainingDay {
        LocalTrainingDay(instant: workout.endedAt ?? workout.startedAt, timeZone: TimeZone(identifier: workout.timeZoneIdentifier) ?? .gmt)
    }
    private var eligibleDay: Bool {
        guard workout.endedAt != nil else { return false }
        let selected = trackingDateString(date)
        return phase == .nextMorning ? selected > sessionDay.date : selected == sessionDay.date
    }
    var body: some View {
        Form {
            Section {
                Text(workout.prescription.name).font(.headline)
                LabeledContent("Workout completed", value: trackingDayLabel(sessionDay))
                LabeledContent("Check-in", value: recoveryPhaseLabel(phase))
                Text("This answer applies only to this workout.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DatePicker("Observed on", selection: $date, in: ...trackingTodayDisplayDate(workout.timeZoneIdentifier), displayedComponents: .date)
                    .environment(\.timeZone, .gmt)
                LabeledContent("Workout time zone", value: workout.timeZoneIdentifier)
                if !eligibleDay {
                    Text(phase == .nextMorning ? "A following-morning answer must be dated after the workout's completion date in its saved time zone." : "An evening answer belongs to the workout's completion date.")
                        .font(.caption).foregroundStyle(.red)
                }
            } footer: { Text("Eligibility follows the workout's saved time zone, so travel does not make a next-morning answer eligible early.") }
            Section {
                Picker("Joint response", selection: $rating) {
                    Text("Unknown / not recorded").tag(Int?.none)
                    Text("0 · Comfortable").tag(Int?.some(0))
                    Text("1 · Mild").tag(Int?.some(1))
                    Text("2 · Adjust").tag(Int?.some(2))
                    Text("3 · Stop").tag(Int?.some(3))
                    Text("4 · Red flag").tag(Int?.some(4))
                }
                Picker("Back to your usual baseline?", selection: $readiness) {
                    Text("Not sure").tag(RecoveryReadiness.unknown)
                    Text("Yes").tag(RecoveryReadiness.yes)
                    Text("Not yet").tag(RecoveryReadiness.no)
                }
                if let rating, rating > 1 {
                    Text("A joint response above Mild counts as not recovered for progression, regardless of the baseline answer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Your own report") }
            footer: { Text("Unknown stays unknown. Sleep, sensors, and elapsed time do not answer this question for you.") }
            Section("Notes · optional") {
                TextField("Anything you want to remember", text: $notes, axis: .vertical).lineLimit(3...8)
            }
            Section {
                Button(rating == nil && readiness == .unknown ? "Save as unknown" : "Save response") { save() }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(!eligibleDay || notes.count > 10_000)
                Button(existing == nil ? "Skip for now" : "Cancel edits") { dismiss() }
            }
            if let localError { Section { Text(localError).foregroundStyle(.red) } }
            SaveErrorSection()
        }
        .formFlowBackground()
        .navigationTitle(recoveryPhaseLabel(phase))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save() {
        do {
            let day = try LocalTrainingDay(date: trackingDateString(date), timeZoneID: workout.timeZoneIdentifier)
            let record = try SessionRecoveryRecord(id: entryID, sessionID: workout.id, phase: phase, day: day,
                                                   rating: rating, readiness: readiness, notes: notes)
            if store.saveRecovery(record) { dismiss() }
        } catch { localError = error.localizedDescription }
    }
}

struct TrainingTrendsView: View {
    @Environment(AppStore.self) private var store

    private var sleepPoints: [TrackingChartPoint] {
        Dictionary(grouping: store.sleepRecords, by: { $0.day.date }).values.compactMap { group in
            guard let record = group.max(by: { $0.updatedAt < $1.updatedAt }), let hours = record.hours else { return nil }
            return TrackingChartPoint(id: record.id.uuidString, date: trackingDisplayDate(record.day.date), value: hours)
        }.sorted { $0.date < $1.date }
    }
    private var weightPoints: [TrackingChartPoint] {
        Dictionary(grouping: store.bodyRecords.filter { $0.weight != nil }, by: { $0.day.date }).values.compactMap { group in
            guard let record = group.max(by: { $0.updatedAt < $1.updatedAt }), let kg = record.weightKilograms else { return nil }
            return TrackingChartPoint(id: record.id.uuidString, date: trackingDisplayDate(record.day.date), value: store.profile.units == .imperial ? kg / 0.45359237 : kg)
        }.sorted { $0.date < $1.date }
    }

    var body: some View {
        List {
            Section("Sleep · recorded hours") {
                if sleepPoints.isEmpty {
                    Text("Record a known night's sleep to see this chart. Unknown nights do not become zero.").foregroundStyle(.secondary)
                } else {
                    Chart(sleepPoints) { point in
                        BarMark(x: .value("Night ending", point.date, unit: .day), y: .value("Hours", point.value))
                            .foregroundStyle(FormFlowTheme.accent)
                            .accessibilityLabel(trackingDateLabel(trackingDateString(point.date)))
                            .accessibilityValue("\(trackingNumber(point.value)) hours")
                    }
                    .chartYScale(domain: 0...24)
                    .chartYAxisLabel("Hours")
                    .frame(height: 210)
                    .environment(\.timeZone, .gmt)
                    Text("\(sleepPoints.count) known nights. Missing and unknown nights are excluded; the latest answer for each local date is shown.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Weekly sleep averages") {
                let weeks = TrackingSummary.sleepWeeks(store.sleepRecords).reversed()
                if weeks.isEmpty { Text("No sleep weeks recorded.").foregroundStyle(.secondary) }
                ForEach(Array(weeks), id: \.week) { week in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Week of \(trackingDateLabel(week.week))").font(.subheadline.bold())
                        Text(week.meanHours.map { "\(trackingNumber($0)) hours per recorded night" } ?? "Average unknown")
                        Text("\(week.recordedNights) known · \(week.unknownNights) explicitly unknown")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Body weight · \(store.profile.units == .imperial ? "lb" : "kg")") {
                if weightPoints.isEmpty {
                    Text("No weight measurements recorded.").foregroundStyle(.secondary)
                } else {
                    Chart(weightPoints) { point in
                        PointMark(x: .value("Date", point.date), y: .value("Weight", point.value))
                            .foregroundStyle(FormFlowTheme.accent)
                            .accessibilityLabel(trackingDateLabel(trackingDateString(point.date)))
                            .accessibilityValue("\(trackingNumber(point.value)) \(store.profile.units == .imperial ? "pounds" : "kilograms")")
                    }
                    .chartYAxisLabel(store.profile.units == .imperial ? "lb" : "kg")
                    .frame(height: 210)
                    .environment(\.timeZone, .gmt)
                    Text("\(weightPoints.count) recorded dates, using the latest weight for each date. Values are converted to your preferred unit for this chart; original measurements keep their units.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formFlowBackground()
        .navigationTitle("Trends")
    }
}

private struct TrackingChartPoint: Identifiable { let id: String; let date: Date; let value: Double }
private func trackingParseNumber(_ text: String) -> Double? {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")), value.isFinite else { return nil }
    return value
}
private func trackingNumber(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
private func trackingNewestSleep(_ lhs: ManualSleepRecord, _ rhs: ManualSleepRecord) -> Bool { lhs.day.date == rhs.day.date ? lhs.updatedAt > rhs.updatedAt : lhs.day.date > rhs.day.date }
private func trackingNewestBody(_ lhs: BodyMeasurementRecord, _ rhs: BodyMeasurementRecord) -> Bool { lhs.day.date == rhs.day.date ? lhs.updatedAt > rhs.updatedAt : lhs.day.date > rhs.day.date }
private func recoveryPhaseLabel(_ phase: RecoveryPhase) -> String { phase == .evening ? "Evening check-in" : "Following morning" }
private func recoveryReadinessLabel(_ answer: RecoveryReadiness) -> String {
    switch answer { case .yes: "Back to usual baseline"; case .no: "Not recovered yet"; case .unknown: "Recovery unknown" }
}
private func trackingDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .gmt
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}
private func trackingDisplayDate(_ day: String) -> Date { trackingDateFormatter().date(from: day)?.addingTimeInterval(12 * 3600) ?? Date() }
private func trackingDateString(_ date: Date) -> String { trackingDateFormatter().string(from: date) }
private func trackingTodayDisplayDate(_ timeZoneID: String) -> Date {
    trackingDisplayDate(LocalTrainingDay(instant: Date(), timeZone: TimeZone(identifier: timeZoneID) ?? .gmt).date)
}
private func trackingDateLabel(_ day: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.timeZone = .gmt
    formatter.dateStyle = .medium
    return formatter.string(from: trackingDisplayDate(day))
}
private func trackingDayLabel(_ day: LocalTrainingDay) -> String { trackingDateLabel(day.date) }
