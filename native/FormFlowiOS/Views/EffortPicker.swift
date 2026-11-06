import SwiftUI

/// Quick choices remain explicit RPE values so existing progression and history stay compatible.
struct EffortPicker: View {
    @Binding var value: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let options: [(score: Int, face: String, label: String)] = [
        (2, "🙂", "Very easy"), (4, "😐", "Comfortable"),
        (6, "😮‍💨", "Hard but manageable"), (8, "😣", "Very hard"),
        (10, "🥵", "Maximum effort")
    ]

    private var face: String {
        guard let value else { return "—" }
        return options.first { value <= $0.score }?.face ?? "🥵"
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("How hard did it feel?").font(.headline)
            Text(face)
                .font(.system(size: 56))
                .id(face)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
                .accessibilityHidden(true)
            Text(value.map { "RPE \($0) · applied" } ?? "Not recorded")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("effort-selection")
            ForEach(options, id: \.score) { option in
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        value = option.score
                    }
                } label: {
                    HStack(spacing: 12) {
                        Text(option.face).font(.title2).accessibilityHidden(true)
                        Text(option.label)
                        Spacer()
                        Text("\(option.score)").foregroundStyle(.secondary)
                        if value == option.score { Image(systemName: "checkmark.circle.fill") }
                    }
                    .frame(minHeight: 44)
                    .padding(.horizontal, 12)
                    .background(value == option.score ? Color.accentColor.opacity(0.15) : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.label), RPE \(option.score)")
                .accessibilityAddTraits(value == option.score ? .isSelected : [])
                .accessibilityIdentifier("effort-choice-\(option.score)")
            }
            DisclosureGroup("Enter an exact RPE") {
                Picker("RPE", selection: $value) {
                    Text("Not recorded").tag(Optional<Int>.none)
                    ForEach(0...10, id: \.self) { score in
                        Text("\(score)").tag(Optional(score))
                    }
                }
            }
            if value != nil {
                Button("Clear effort") { value = nil }
                    .accessibilityIdentifier("effort-clear")
            }
        }
        .padding(.vertical, 8)
    }
}
