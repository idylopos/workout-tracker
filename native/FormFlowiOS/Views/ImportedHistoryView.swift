import SwiftUI
import FormFlowCore

struct ImportedHistoryView: View {
    @Environment(AppStore.self) private var store
    @State private var records: [BackupRecord] = []
    @State private var problem: String?
    private var workouts: [LegacyWorkoutSummary] {
        records.compactMap(LegacyWorkoutSummary.init(record:)).sorted { $0.date > $1.date }
    }
    var body: some View {
        List {
            Section {
                Text("Your saved web history").font(.title2.bold())
                Text("Web entries retain their dates, actual values and notes. They are shown separately from native session trends because their recording times and session boundaries may be unknown.")
                    .foregroundStyle(.secondary)
                Text("For the built-in plan, explicit saved strength or pull-up targets, actuals and recovery answers can support comparison with a new native result. Missing targets or unknown answers remain nonqualifying; importing history never enables automatic progression.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if workouts.isEmpty {
                ContentUnavailableView("No imported web workouts", systemImage: "archivebox",
                    description: Text(problem ?? "Restore a web backup from Settings to bring your saved entries here."))
            } else {
                Section("Recorded days") {
                    ForEach(workouts) { workout in
                        NavigationLink {
                            ImportedWorkoutDetailView(workout: workout, record: records.first { $0.key == workout.id })
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(workout.date).font(.headline)
                                Text("\(workout.completedSetCount) completed sets · \(workout.planID)").font(.subheadline)
                                if workout.hasPendingDraft { Label("A newer draft is also retained", systemImage: "square.and.pencil").font(.caption) }
                            }
                        }
                    }
                }
            }
            let body = records.filter { $0.category == .body && $0.payload["nativeType"] == nil }
            let sleep = records.filter { $0.category == .sleep && $0.payload["nativeType"] == nil }
            if !body.isEmpty {
                Section("Body measurements") {
                    ForEach(body.sorted { ($0.payload["date"]?.string ?? "") > ($1.payload["date"]?.string ?? "") }, id: \.key) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.payload["date"]?.string ?? "Date unavailable").font(.headline)
                            if let weight = record.payload["weight"]?.number { Text("Weight: \(weight.formatted()) kg") }
                            if let waist = record.payload["waist"]?.number { Text("Waist: \(waist.formatted()) cm") }
                        }
                    }
                }
            }
            if !sleep.isEmpty {
                Section("Sleep") {
                    ForEach(sleep.sorted { $0.id > $1.id }, id: \.key) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.payload["date"]?.string ?? record.payload["week"]?.string ?? "Date unavailable").font(.headline)
                            if let hours = record.payload["hours"]?.number { Text("\(hours.formatted()) hours") }
                            Text(record.payload["legacyFrequency"] == .string("weekly") ? "Weekly average from web tracker" : "Nightly entry from web tracker")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            NavigationLink("All preserved records and drafts") { ArchivedBackupRecordsView() }
        }.navigationTitle("Imported history")
            .formFlowBackground()
            .task {
                do { records = try store.archivedBackupRecords() }
                catch { problem = error.localizedDescription }
            }
    }
}

private struct ImportedWorkoutDetailView: View {
    let workout: LegacyWorkoutSummary
    let record: BackupRecord?
    var body: some View {
        List {
            Section {
                Text(workout.date).font(.title2.bold())
                LabeledContent("Original plan", value: workout.planID)
                if let zone = workout.timeZoneAssumption {
                    Text("The original backup did not record a time zone. Import used \(zone).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let notes = workout.notes, !notes.isEmpty { Text(notes).textSelection(.enabled) }
                if workout.hasPendingDraft {
                    Label("The saved result and a newer draft were both kept. Draft values are not counted as completed work.", systemImage: "square.and.pencil")
                }
                Text("An unavailable original plan definition is not reconstructed. Progression can use only explicit saved facts that match the current built-in exercise and target; all other imported coaching remains manual.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(workout.exercises) { exercise in
                Section(exercise.name) {
                    Text(exercise.measurement.displayName).font(.caption).foregroundStyle(.secondary)
                    ForEach(exercise.sets) { set in
                        VStack(alignment: .leading, spacing: 5) {
                            Label("Set \(set.index) · \(set.completed ? "Completed" : "Not marked completed")",
                                  systemImage: set.completed ? "checkmark.circle" : "circle")
                            Text(set.actual.summary).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let record {
                NavigationLink("Preserved recovery, coaching and original fields") {
                    List { BackupValueRows(value: record.payload) }.navigationTitle("Preserved record")
                }
            }
        }.navigationTitle("Web workout")
            .formFlowBackground()
    }
}
