import SwiftUI
import FormFlowCore

struct WorkoutIntervalEntryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    let setID: UUID
    let intervalID: UUID
    @State private var values = WorkoutSetValues()
    @State private var loaded = false
    @State private var distanceUnit: PlanUnit = .km
    @State private var skipReason = ""
    private var workout: WorkoutSession? { store.workouts.first { $0.id == sessionID } }
    private var interval: WorkoutInterval? {
        workout?.exercises.flatMap(\.sets).first { $0.id == setID }?.intervals?.first { $0.id == intervalID }
    }
    private var correction: Bool { interval?.status == .completed || workout?.state.isTerminal == true }
    private var isRetired: Bool { workout.map { store.isRetiredIncomplete($0) } ?? false }
    var body: some View {
        Form {
            if let interval {
                Section {
                    Text("\(interval.prescription.kind.rawValue.capitalized) · round \(interval.repetition)").font(.headline)
                    Text(interval.prescription.target.summary)
                    if let instructions = interval.prescription.instructions { Text(instructions).foregroundStyle(.secondary) }
                }
                if isRetired {
                    Section("Archived interval · read only") {
                        Text(interval.actual.summary)
                        Text(interval.status.rawValue.capitalized).font(.caption)
                        if let date = interval.completedAt { Text(date.formatted()).font(.caption) }
                        if let reason = interval.skipReason { Text(reason).font(.caption) }
                        Text("Saved values belong to an older workspace and remain unchanged.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section("Actual interval result") {
                        TextField("Duration in seconds", value: $values.durationSeconds, format: .number).keyboardType(.decimalPad)
                        HStack {
                            TextField("Distance (optional)", value: Binding<Double?>(get: { values.distance?.value }, set: { number in
                                values.distance = number.map { .init(value: $0, unit: values.distance?.unit ?? distanceUnit) }
                            }), format: .number).keyboardType(.decimalPad)
                            Picker("Distance unit", selection: $distanceUnit) {
                                ForEach([PlanUnit.m, .km, .mi], id: \.self) { Text($0.rawValue).tag($0) }
                            }.onChange(of: distanceUnit) { if values.distance != nil { values.distance?.unit = distanceUnit } }
                        }
                        TextField("Calories (optional)", value: $values.calories, format: .number).keyboardType(.decimalPad)
                        EffortPicker(value: $values.rpe)
                        Button(correction ? "Save interval correction" : "Log interval") {
                            let command: WorkoutCommand = correction
                                ? .updateInterval(setID: setID, intervalID: intervalID, values: values)
                                : .logInterval(setID: setID, intervalID: intervalID, values: values)
                            if store.applyWorkoutCommand(command, sessionID: sessionID) { dismiss() }
                        }.buttonStyle(PrimaryActionStyle())
                    }
                    if workout?.state.isTerminal == false {
                        Section {
                            if interval.status == .planned {
                                TextField("Reason for skipping · optional", text: $skipReason)
                                Button("Skip this interval") {
                                    if store.applyWorkoutCommand(.skipInterval(setID: setID, intervalID: intervalID,
                                        reason: skipReason.isEmpty ? nil : skipReason), sessionID: sessionID) { dismiss() }
                                }
                            } else {
                                Button("Undo interval completion or skip") {
                                    if store.applyWorkoutCommand(.undoInterval(setID: setID, intervalID: intervalID), sessionID: sessionID) { dismiss() }
                                }
                            }
                        }
                    }
                }
            }
            SaveErrorSection()
        }
        .navigationTitle(isRetired ? "Archived interval" : "Record interval")
        .disabled(!isRetired && (workout?.ownerDeviceID != store.deviceID || workout?.state == .paused || workout?.state == .abandoned))
        .safeAreaInset(edge: .bottom) { WorkoutRestBar(sessionID: sessionID) }
        .scrollDismissesKeyboard(.interactively)
        .task {
            guard !loaded, !isRetired, let interval else { return }
            values = interval.actual
            distanceUnit = values.distance?.unit ?? (store.profile.units == .metric ? .km : .mi)
            loaded = true
        }
        .onChange(of: values) {
            if loaded && !isRetired && !correction {
                store.applyWorkoutCommand(.updateInterval(setID: setID, intervalID: intervalID, values: values), sessionID: sessionID)
            }
        }
    }
}
