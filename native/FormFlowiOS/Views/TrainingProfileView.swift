import SwiftUI
import FormFlowCore

struct TrainingProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showBrief = false
    @State private var editingFromBrief = false

    private let titles = ["Your goals", "Your starting point", "Your week", "Your training space", "Your limitations", "A little context", "Your preferences"]
    private var step: Int { min(max(store.onboardingStep, 0), titles.count - 1) }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Section \(step + 1) of \(titles.count)").font(.subheadline).foregroundStyle(.secondary)
                    ProgressView(value: Double(step + 1), total: Double(titles.count))
                        .accessibilityLabel("Profile progress")
                    Text("Your answers save as you go. You can leave and return later.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            questionnaireFields
            SaveErrorSection()
        }
        .formFlowBackground()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(titles[step])
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Save & close") {
                    store.saveDraft()
                    if store.errorMessage == nil { dismiss() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 16) {
                if step > 0 && !editingFromBrief {
                    Button("Back") {
                        store.onboardingStep = step - 1
                        store.saveDraft()
                    }.frame(minWidth: 54, minHeight: 44)
                }
                Button(editingFromBrief ? "Return to brief" : step == titles.count - 1 ? "Review my brief" : "Next") {
                    if step == 2 { store.profile.hasReviewedAvailability = true }
                    guard store.saveDraft() else { return }
                    if editingFromBrief || step == titles.count - 1 {
                        editingFromBrief = false
                        showBrief = true
                    }
                    else { store.onboardingStep = step + 1 }
                }.buttonStyle(PrimaryActionStyle())
                    .accessibilityIdentifier("profile-next")
            }
            .padding()
            .background(.regularMaterial)
        }
        .navigationDestination(isPresented: $showBrief) {
            TrainingBriefView { requirement in
                store.onboardingStep = requirement.sectionIndex
                editingFromBrief = true
                showBrief = false
                store.saveDraft()
            }
        }
    }

    @ViewBuilder
    private var questionnaireFields: some View {
        @Bindable var store = store
        switch step {
        case 0:
            Section {
                Picker("Main goal", selection: $store.profile.goal) {
                    Text("Choose a goal").tag("")
                    ForEach(["General fitness", "Build strength", "Build muscle", "Improve endurance", "Prepare for an event", "Other"], id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("profile-main-goal")
                TextField(store.profile.goal == "Other" ? "Describe your main goal" : "Anything else you want to work on?", text: $store.profile.secondaryGoals, axis: .vertical)
                    .lineLimit(2...5)
                TextField("Timeframe or event date, if any", text: $store.profile.goalTimeframe, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("profile-goal-timeframe")
            } header: { Text("What would you like training to do for you?") }
            footer: { Text(store.profile.goal == "Other" ? "Describe your goal so the AI has useful direction. A timeframe is optional." : "Your main goal is required. A timeframe and additional goals are optional.") }

        case 1:
            Section("Experience") {
                experiencePicker("Strength training", selection: $store.profile.strengthExperience)
                experiencePicker("Cardio training", selection: $store.profile.cardioExperience)
            }
            Section {
                TextField("What have you been doing recently?", text: $store.profile.recentRoutine, axis: .vertical)
                    .lineLimit(3...7)
            } header: { Text("Recent routine · optional") }
            footer: { Text("Walking, sport, gym sessions, or a break from training all count. Include roughly how often.") }
            Section {
                TextField("What can you comfortably do now?", text: $store.profile.currentCapabilities, axis: .vertical)
                    .lineLimit(3...7)
            } header: { Text("Current starting point · optional") }
            footer: {
                Text(store.profile.strengthExperience == "New to this" || store.profile.strengthExperience == "Not sure"
                     ? "You don't need to test yourself or know exercise numbers. Everyday activity is useful context; leave this blank if unsure."
                     : "Include familiar exercises, approximate weights, a comfortable walk or run, or anything else you already know. Unknown values stay unknown.")
            }

        case 2:
            Section("Days you can train") {
                ForEach(Weekday.allCases, id: \.self) { day in
                    Toggle(day.displayName, isOn: Binding(
                        get: { store.profile.availableDays.contains(day) },
                        set: { selected in
                            if selected && !store.profile.availableDays.contains(day) { store.profile.availableDays.append(day) }
                            if !selected { store.profile.availableDays.removeAll { $0 == day } }
                        }
                    ))
                    .accessibilityIdentifier("profile-day-\(day.rawValue)")
                }
            }
            Section {
                Stepper("About \(store.profile.sessionMinutes) minutes per session", value: Binding(
                    get: { store.profile.sessionMinutes },
                    set: { store.profile.sessionMinutes = $0; store.profile.hasReviewedAvailability = true }
                ), in: 10...180, step: 5)
            } header: { Text("Available time") }
            footer: { Text("Choose a realistic total, including warm-up and rest. You can describe different time budgets or split sessions in your preferences.") }

        case 3:
            Section("Where will you train?") {
                Picker("Training space", selection: $store.profile.trainingLocation) {
                    Text("Choose a space").tag("")
                    ForEach(["Home", "Gym", "Outdoors", "A mix of places", "Not sure yet"], id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("profile-training-location")
            }
            Section {
                TextField("Equipment you can use", text: $store.profile.equipment, axis: .vertical)
                    .lineLimit(3...7)
                Button("Use bodyweight / no equipment") { store.profile.equipment = "Bodyweight / no equipment" }
                    .accessibilityIdentifier("profile-bodyweight")
            } header: { Text("Available equipment") }
            footer: { Text("For example: dumbbells up to 10 kg, resistance bands, a pull-up bar, a treadmill, or access to a full gym. Include weight increments or assistance setup if you know them.") }
            Section("Measurement preference") {
                Picker("Units", selection: $store.profile.units) {
                    Text(UnitPreference.metric.label).tag(UnitPreference.metric)
                    Text(UnitPreference.imperial.label).tag(UnitPreference.imperial)
                }
            }

        case 4:
            Section {
                Picker("Anything training should account for?", selection: $store.profile.limitationsAnswer) {
                    Text(LimitationsAnswer.unanswered.label).tag(LimitationsAnswer.unanswered)
                    Text(LimitationsAnswer.none.label).tag(LimitationsAnswer.none)
                    Text(LimitationsAnswer.reported.label).tag(LimitationsAnswer.reported)
                    Text(LimitationsAnswer.preferNotToSay.label).tag(LimitationsAnswer.preferNotToSay)
                }
                if store.profile.limitationsAnswer == .reported {
                    TextField("Limitations or movements to avoid", text: $store.profile.limitations, axis: .vertical)
                        .lineLimit(3...7)
                    TextField("Existing clinician instructions, if any", text: $store.profile.clinicianInstructions, axis: .vertical)
                        .lineLimit(3...7)
                }
            } header: { Text("Optional training constraints") }
            footer: { Text("This helps describe constraints, not establish medical clearance. You choose whether these details are included in the prompt before copying. Skipping keeps the answer unknown.") }

        case 5:
            Section {
                Picker("Age range", selection: $store.profile.ageRange) {
                    Text("Not supplied").tag("")
                    ForEach(["18–29", "30–39", "40–49", "50–59", "60–69", "70+", "Prefer not to say"], id: \.self) { Text($0).tag($0) }
                }
                TextField(store.profile.units == .metric ? "Height, e.g. 175 cm" : "Height, e.g. 5 ft 9 in", text: $store.profile.height)
                TextField(store.profile.units == .metric ? "Weight, e.g. 70 kg" : "Weight, e.g. 154 lb", text: $store.profile.weight)
                TextField("Usual sleep or recovery context", text: $store.profile.usualSleep, axis: .vertical)
                    .lineLimit(2...5)
            } header: { Text("About you · all optional") }
            footer: { Text("Include units with height and weight; changing your unit preference does not convert these written answers. These details are excluded until you choose to include them in the brief review.") }
            Section {
                TextField("Sport, active work, caregiving, or other activity", text: $store.profile.otherActivity, axis: .vertical)
                    .lineLimit(3...6)
            } header: { Text("Activity beyond training · optional") }

        default:
            Section {
                TextField("Activities you enjoy and how you like to train", text: $store.profile.preferences, axis: .vertical)
                    .lineLimit(3...8)
                TextField("Exercises or activities you dislike", text: $store.profile.dislikes, axis: .vertical)
                    .lineLimit(3...6)
            } header: { Text("Make the plan feel like yours · optional") }
            footer: { Text("Mention preferred session length on particular days, split sessions, solo or group training, and anything else that will help the plan fit your life.") }
            Section {
                Text("Next, review what is known, what is still unknown, and what you want to share with your AI. No information has been sent anywhere.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func experiencePicker(_ title: String, selection: Binding<String>) -> some View {
        NavigationLink {
            ExperienceChoiceView(title: title, selection: selection)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).foregroundStyle(.primary)
                Text(selection.wrappedValue.isEmpty ? "Choose an answer" : selection.wrappedValue)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier(title == "Strength training" ? "profile-strength-experience" : "profile-cardio-experience")
    }
}

private struct ExperienceChoiceView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @Binding var selection: String

    var body: some View {
        List {
            ForEach(["New to this", "Returning after a break", "Training regularly", "Not sure"], id: \.self) { answer in
                Button {
                    selection = answer
                    dismiss()
                } label: {
                    HStack {
                        Text(answer).fixedSize(horizontal: false, vertical: true)
                        if selection == answer { Spacer(); Image(systemName: "checkmark") }
                    }
                }
                .accessibilityLabel(answer)
                .accessibilityAddTraits(selection == answer ? [.isSelected] : [])
            }
        }
        .navigationTitle(title)
        .formFlowBackground()
    }
}

struct TrainingBriefView: View {
    @Environment(AppStore.self) private var store
    @State private var showPrompt = false
    let editRequirement: (TrainingProfileRequirement) -> Void

    var body: some View {
        @Bindable var store = store
        List {
            Section {
                Text("Your training brief").font(.title2.bold())
                Text("Review the information behind your prompt. Unanswered questions stay unknown; they are not interpreted as no limitations or existing ability.")
                    .foregroundStyle(.secondary)
            }
            if !store.profile.missingEssentials.isEmpty {
                Section("Complete these before creating a prompt") {
                    ForEach(store.profile.missingRequirements) { requirement in
                        Button { editRequirement(requirement) } label: {
                            Label(requirement.title, systemImage: "pencil")
                        }
                        .accessibilityIdentifier("brief-edit-\(requirement.rawValue)")
                    }
                    Text("Tap an item to complete it, then return directly to this brief. Optional personal details can stay blank.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Goals and experience") {
                BriefValue("Primary goal", store.profile.goal)
                BriefValue("Other goals", store.profile.secondaryGoals)
                BriefValue("Timeframe", store.profile.goalTimeframe)
                BriefValue("Strength experience", store.profile.strengthExperience)
                BriefValue("Cardio experience", store.profile.cardioExperience)
                BriefValue("Recent routine", store.profile.recentRoutine)
                BriefValue("Current capabilities", store.profile.currentCapabilities)
            }
            Section("Your week and equipment") {
                BriefValue("Training days", Weekday.allCases.filter { store.profile.availableDays.contains($0) }.map(\.displayName).joined(separator: ", "))
                BriefValue("Time per session", "\(store.profile.sessionMinutes) minutes")
                BriefValue("Training space", store.profile.trainingLocation)
                BriefValue("Equipment", store.profile.equipment)
                BriefValue("Units", store.profile.units.label)
                BriefValue("Other activity", store.profile.otherActivity)
            }
            Section {
                BriefValue("Answer", store.profile.limitationsAnswer.label)
                if store.profile.limitationsAnswer == .reported {
                    BriefValue("Limitations", store.profile.limitations)
                }
                Toggle("Include my limitations answer and details", isOn: $store.profile.includeLimitationsInPrompt)
                if store.profile.limitationsAnswer == .reported {
                    BriefValue("Clinician instructions", store.profile.clinicianInstructions)
                    Toggle("Include clinician instructions", isOn: $store.profile.includeClinicianInstructionsInPrompt)
                }
            } header: { Text("Training constraints · private by default") }
            footer: { Text("When excluded, the prompt must treat limitations as unknown. This choice controls what is copied, not what is stored on this iPhone.") }
            Section {
                BriefValue("Age range", store.profile.ageRange)
                Toggle("Include age range", isOn: $store.profile.includeAgeRangeInPrompt)
                BriefValue("Height", store.profile.height)
                Toggle("Include height", isOn: $store.profile.includeHeightInPrompt)
                BriefValue("Weight", store.profile.weight)
                Toggle("Include weight", isOn: $store.profile.includeWeightInPrompt)
                BriefValue("Sleep context", store.profile.usualSleep)
                Toggle("Include sleep context", isOn: $store.profile.includeSleepInPrompt)
            } header: { Text("Personal details · private by default") }
            footer: { Text("Review the exact text on the next screen. Pasting it into an AI service shares the included information with that service.") }
            Section("Preferences") {
                BriefValue("Enjoyed activities", store.profile.preferences)
                BriefValue("Dislikes", store.profile.dislikes)
            }
            Section {
                if !store.profile.canGeneratePrompt {
                    Text("Still needed: \(store.profile.missingEssentials.joined(separator: "; ")).")
                        .font(.subheadline)
                    Text("Optional bio details and sharing permissions are not required.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(store.profile.canGeneratePrompt ? "Create and review prompt" : "Complete missing answers") {
                    if let requirement = store.profile.missingRequirements.first {
                        editRequirement(requirement)
                    } else {
                        store.generatePrompt()
                        if store.errorMessage == nil && !store.promptDraft.isEmpty { showPrompt = true }
                    }
                }
                .buttonStyle(PrimaryActionStyle())
                .accessibilityIdentifier("brief-primary-action")
            }
            SaveErrorSection()
        }
        .formFlowBackground()
        .navigationTitle("Review brief")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showPrompt) { PromptReviewView() }
    }
}

private struct BriefValue: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown · not supplied" : value)
                .textSelection(.enabled)
        }.padding(.vertical, 2)
    }
}

private extension TrainingProfileRequirement {
    var sectionIndex: Int {
        switch self {
        case .goal, .goalDescription: 0
        case .strengthExperience, .cardioExperience: 1
        case .availableDays, .sessionLength: 2
        case .trainingLocation, .equipment: 3
        case .limitationsDetails: 4
        }
    }
}
