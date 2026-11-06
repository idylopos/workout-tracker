import SwiftUI
import Charts
import FormFlowCore

struct WorkoutTrendsView: View {
    @Environment(AppStore.self) private var store
    @State private var distanceUnit = "km"

    private var report: WorkoutTrendsReport { WorkoutTrends.report(workouts: store.includedWorkouts.filter { !store.isRetiredIncomplete($0) }) }
    var body: some View {
        let report = report
        List {
            Section {
                Text("Your recorded training").font(.title2.bold())
                Text("Finished sessions, including partial workouts, supply these totals. Targets and unlogged sets never count as actuals.")
                    .foregroundStyle(.secondary)
            }
            Section("Last 8 weeks") {
                HStack {
                    countLabel(report.finishedCount, "Finished")
                    Spacer()
                    countLabel(report.partialCount, "Partial")
                    Spacer()
                    countLabel(report.abandonedCount, "Abandoned")
                }
                if report.finishedCount + report.partialCount > 0 {
                    Chart(report.weeks) { week in
                        BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Sessions", week.finished))
                            .foregroundStyle(by: .value("Outcome", "Finished"))
                        BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Sessions", week.partial))
                            .foregroundStyle(by: .value("Outcome", "Partial"))
                    }
                    .chartForegroundStyleScale(["Finished": Color.teal, "Partial": Color.orange])
                    .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                    .frame(height: 185)
                    .accessibilityLabel("Weekly recorded sessions. Finished and partial workouts are shown separately.")
                } else {
                    Text("Finish a workout to see your weekly pattern.").foregroundStyle(.secondary)
                }
                if report.inProgressCount > 0 {
                    Text("\(report.inProgressCount) in progress — excluded from finished totals.").foregroundStyle(.secondary)
                }
                DisclosureGroup("Weekly counts") {
                    ForEach(report.weeks) { week in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Week of \(week.start.formatted(date: .abbreviated, time: .omitted))")
                            Text("\(week.finished) finished · \(week.partial) partial · \(week.abandoned) abandoned")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Weeks begin Monday and use \(report.timeZoneIdentifier). Sessions are counted on their finish date. This shows recorded consistency, not a planned-workout completion percentage.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Recorded cardio · last 8 weeks") {
                Picker("Distance unit", selection: $distanceUnit) {
                    Text("Kilometres").tag("km")
                    Text("Miles").tag("mi")
                }
                actualTotal("Distance", total: report.cardio.distanceMeters,
                    divisor: distanceUnit == "mi" ? 1_609.344 : 1_000, unit: distanceUnit)
                actualTotal("Duration", total: report.cardio.durationSeconds, divisor: 60, unit: "min")
                actualTotal("Calories", total: report.cardio.calories, divisor: 1, unit: "kcal")
                Text("Completed distance/time, distance and duration/calorie entries count here. Duration-only entries count in cardio, conditioning or endurance sessions. Completed intervals count once, including warm-up and recovery. A dash means no actual was recorded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Exercise history · all time") {
                if report.exercises.isEmpty {
                    Text("No completed exercise results yet. Partial finishes still preserve completed work.")
                        .foregroundStyle(.secondary)
                }
                ForEach(report.exercises) { trend in
                    NavigationLink {
                        ExerciseTrendDetailView(trend: trend)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(trend.name)
                            Text("\(trend.measurement.displayName) · \(trend.samples.count) recorded results")
                                .font(.caption).foregroundStyle(.secondary)
                            if !trend.equipment.isEmpty {
                                Text(trend.equipment.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("Exercises are matched by their performed exercise identity, measurement and equipment. Similar names alone do not combine histories.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formFlowBackground()
        .navigationTitle("Workout trends")
    }
    private func countLabel(_ count: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(count, format: .number).font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
    private func actualTotal(_ label: String, total: RecordedActualTotal, divisor: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(label) {
                if let value = total.value {
                    Text("\((value / divisor).formatted(.number.precision(.fractionLength(0...2)))) \(unit)").monospacedDigit()
                } else { Text("—").accessibilityLabel("No recorded actual") }
            }
            if total.missingCount > 0 {
                Text("Known total from \(total.knownCount) entries; \(total.missingCount) entries have no value.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if total.knownCount > 0 {
                Text("\(total.knownCount) recorded entries").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ExerciseTrendDetailView: View {
    let trend: WorkoutExerciseTrend
    @State private var selectedMetric: WorkoutTrendMetric?
    @State private var imperial = false
    private var metric: WorkoutTrendMetric? { selectedMetric ?? trend.availableMetrics.first }
    private var recentSamples: [WorkoutTrendSample] { Array(trend.samples.suffix(200)) }

    var body: some View {
        List {
            Section {
                Text(trend.measurement.displayName).font(.headline)
                if !trend.equipment.isEmpty { Text(trend.equipment.joined(separator: ", ")).foregroundStyle(.secondary) }
                Text("Every point is a completed set or interval from a finished workout. Partial workouts are included. A higher number alone does not establish progress.")
                    .foregroundStyle(.secondary)
            }
            if let metric {
                Section("Recorded actuals") {
                    Picker("Measure", selection: Binding(get: { metric }, set: { selectedMetric = $0 })) {
                        ForEach(trend.availableMetrics, id: \.rawValue) { item in Text(title(item)).tag(item) }
                    }
                    if [.loadKilograms, .assistanceKilograms, .distanceMeters].contains(metric) {
                        Toggle("Use pounds and miles", isOn: $imperial)
                    }
                    Chart(recentSamples) { sample in
                        if let actual = displayValue(sample, metric: metric) {
                            PointMark(x: .value("Recorded", sample.date), y: .value(title(metric), actual))
                                .foregroundStyle(sample.partialWorkout ? Color.orange : Color.teal)
                                .symbol(sample.partialWorkout ? .square : .circle)
                                .accessibilityLabel(sample.date.formatted(date: .abbreviated, time: .shortened))
                                .accessibilityValue("\(actual.formatted(.number.precision(.fractionLength(0...2)))) \(unit(metric)); \(sample.partialWorkout ? "partial workout" : "finished workout")")
                        }
                    }
                    .frame(height: 220)
                    Text("\(title(metric)) (\(unit(metric))) · teal circles: finished · orange squares: partial")
                        .font(.caption).foregroundStyle(.secondary)
                    if metric == .assistanceKilograms {
                        Text("Less assistance means less support. Compare repetitions, technique and equipment before interpreting a change.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if metric == .loadKilograms {
                        Text("Compare load together with repetitions and technique; the actual set values remain below.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if trend.samples.count > recentSamples.count {
                        Text("Chart shows the latest \(recentSamples.count) results.").font(.caption).foregroundStyle(.secondary)
                    }
                    if Set(trend.samples.map(\.workoutID)).count < 2 {
                        Text("One workout recorded. More comparable sessions are needed to see a pattern.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Section { Text("Completion is recorded, but there are no numeric actuals to chart.").foregroundStyle(.secondary) }
            }
            Section("Latest results · original units") {
                ForEach(Array(trend.samples.suffix(30).reversed())) { sample in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(sample.date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
                        Text(sample.actual.summary)
                        if sample.partialWorkout || sample.intervalKind != nil {
                            Text([sample.partialWorkout ? "Partial workout" : nil, sample.intervalKind?.rawValue.capitalized]
                                .compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if trend.samples.count > 30 {
                    Text("Latest 30 results shown. Full sessions remain in training history.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formFlowBackground()
        .navigationTitle(trend.name)
        .navigationBarTitleDisplayMode(.inline)
    }
    private func title(_ metric: WorkoutTrendMetric) -> String {
        switch metric {
        case .loadKilograms: "Load"
        case .assistanceKilograms: "Assistance"
        case .repetitions: "Repetitions"
        case .distanceMeters: "Distance"
        case .durationSeconds: "Duration"
        case .calories: "Calories"
        }
    }
    private func unit(_ metric: WorkoutTrendMetric) -> String {
        switch metric {
        case .loadKilograms, .assistanceKilograms: imperial ? "lb" : "kg"
        case .repetitions: "reps"
        case .distanceMeters: imperial ? "mi" : "km"
        case .durationSeconds: "min"
        case .calories: "kcal"
        }
    }
    private func displayValue(_ sample: WorkoutTrendSample, metric: WorkoutTrendMetric) -> Double? {
        guard let value = sample.value(for: metric) else { return nil }
        switch metric {
        case .loadKilograms, .assistanceKilograms: return imperial ? value / 0.45359237 : value
        case .distanceMeters: return value / (imperial ? 1_609.344 : 1_000)
        case .durationSeconds: return value / 60
        default: return value
        }
    }
}
