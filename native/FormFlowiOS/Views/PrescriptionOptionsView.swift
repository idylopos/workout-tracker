import SwiftUI
import FormFlowCore

struct AlternativesPlanEditorView: View {
    @Binding var alternatives: [PlanAlternative]?
    @State private var selected: PlanAlternative?
    var body: some View {
        List {
            Section {
                Text("Alternatives keep their own targets and equipment. During a workout, choose one before entering any results.").font(.subheadline).foregroundStyle(.secondary)
                ForEach(alternatives ?? []) { option in
                    Button(option.name.isEmpty ? "Name this alternative" : option.name) { selected = option }
                }.onDelete { offsets in
                    alternatives?.remove(atOffsets: offsets)
                    if alternatives?.isEmpty == true { alternatives = nil }
                }
                Button("Add alternative") {
                    selected = .init(id: "alternative-\(UUID().uuidString.lowercased())",
                        exerciseId: "exercise-\(UUID().uuidString.lowercased())", name: "", measurement: .completion,
                        target: .init(sets: 1, restSeconds: 0))
                }.disabled((alternatives?.count ?? 0) >= 6)
            }
        }.navigationTitle("Alternatives")
            .sheet(item: $selected) { option in
                NavigationStack {
                    ExercisePlanEditorView(exercise: option.prescription(instanceId: option.id), allowsAlternatives: false) { value in
                        let updated = PlanAlternative(id: option.id, exerciseId: value.exerciseId, name: value.name,
                            measurement: value.measurement, equipment: value.equipment, target: value.target,
                            instructions: value.instructions, intervals: value.intervals)
                        var options = alternatives ?? []
                        if let index = options.firstIndex(where: { $0.id == option.id }) { options[index] = updated }
                        else { options.append(updated) }
                        alternatives = options
                    }
                }
            }
    }
}

struct IntervalBlocksEditorView: View {
    @Binding var blocks: [PlanIntervalBlock]?
    var body: some View {
        List {
            Section {
                Text("Each block repeats its steps in order. Enter work, recovery and warm-up targets yourself; they remain separate from recorded results.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(Array((blocks ?? []).enumerated()), id: \.element.id) { index, block in
                Section("Block \(index + 1)") {
                    Stepper("Repeat \(block.repeatCount) times", value: Binding(get: {
                        blocks?.first { $0.id == block.id }?.repeatCount ?? 1
                    }, set: { count in
                        if let index = blocks?.firstIndex(where: { $0.id == block.id }) { blocks?[index].repeatCount = count }
                    }), in: 1...100)
                    ForEach(block.steps) { step in
                        NavigationLink {
                            IntervalStepEditorView(step: Binding(get: {
                                blocks?.first { $0.id == block.id }?.steps.first { $0.id == step.id } ?? step
                            }, set: { updated in
                                if let b = blocks?.firstIndex(where: { $0.id == block.id }),
                                   let s = blocks?[b].steps.firstIndex(where: { $0.id == step.id }) { blocks?[b].steps[s] = updated }
                            }))
                        } label: {
                            VStack(alignment: .leading) {
                                Text(step.kind.rawValue.capitalized)
                                Text(step.target.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.onDelete { offsets in
                        if let index = blocks?.firstIndex(where: { $0.id == block.id }) { blocks?[index].steps.remove(atOffsets: offsets) }
                    }.onMove { offsets, target in
                        if let index = blocks?.firstIndex(where: { $0.id == block.id }) { blocks?[index].steps.move(fromOffsets: offsets, toOffset: target) }
                    }
                    Button("Add interval step") {
                        if let index = blocks?.firstIndex(where: { $0.id == block.id }) {
                            blocks?[index].steps.append(.init(id: "step-\(UUID().uuidString.lowercased())", kind: .work,
                                measurement: .duration, target: .init(sets: 1, restSeconds: 0)))
                        }
                    }.disabled((blocks ?? []).reduce(0) { $0 + $1.steps.count } >= 40)
                    Button("Remove block", role: .destructive) {
                        blocks?.removeAll { $0.id == block.id }
                        if blocks?.isEmpty == true { blocks = nil }
                    }
                }
            }
            Section {
                Button("Add block") {
                    var updated = blocks ?? []
                    updated.append(.init(id: "block-\(UUID().uuidString.lowercased())", steps: [
                        .init(id: "step-\(UUID().uuidString.lowercased())", kind: .work, measurement: .duration,
                              target: .init(sets: 1, restSeconds: 0))
                    ]))
                    blocks = updated
                }.disabled((blocks ?? []).reduce(0) { $0 + $1.steps.count } >= 40)
            }
        }.navigationTitle("Interval sequence")
            .toolbar { EditButton() }
    }
}

private struct IntervalStepEditorView: View {
    @Binding var step: PlanIntervalStep
    var body: some View {
        Form {
            Section {
                Picker("Step", selection: $step.kind) {
                    ForEach([PlanIntervalKind.warmup, .work, .recovery, .cooldown], id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Measure", selection: $step.measurement) {
                    ForEach([MeasurementKind.duration, .durationCalories, .distance, .distanceTime], id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("Instructions", text: Binding(get: { step.instructions ?? "" }, set: { step.instructions = $0.isEmpty ? nil : $0 }), axis: .vertical)
            }
            RangeTargetSection(title: "Duration", range: $step.target.duration, allowed: [.s, .min])
            RangeTargetSection(title: "Distance", range: $step.target.distance, allowed: [.m, .km, .mi])
            if step.measurement == .durationCalories {
                RangeTargetSection(title: "Calories", range: $step.target.calories, allowed: [.kcal])
            }
            Section {
                Text("Unsupported combinations are identified when you save the plan. Recovery time belongs in a recovery step.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Interval target")
    }
}

struct PlanIntervalSummaryView: View {
    let blocks: [PlanIntervalBlock]
    var body: some View {
        ForEach(blocks) { block in
            DisclosureGroup("\(block.steps.count) steps · repeat \(block.repeatCount) times") {
                ForEach(block.steps) { step in
                    VStack(alignment: .leading) {
                        Text(step.kind.rawValue.capitalized).font(.headline)
                        Text(step.target.summary)
                        if let instructions = step.instructions { Text(instructions).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}
