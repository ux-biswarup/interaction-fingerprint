import SwiftUI

/// The day's study block: who, how they are sitting, what light, and the four sessions in
/// today's order. Starting a session hands its condition to the recording, which stores it
/// in the session record and runs the task's prompt and time limit.
/// Protocol: `docs/product/04-EXPERIMENT-PLAN.md`.
struct StudyPlanView: View {
    let onStart: (SessionCondition) -> Void
    let onClose: () -> Void

    @AppStorage("interactionFingerprint.study.participant") private var participant = "P1"
    @AppStorage("interactionFingerprint.study.posture") private var postureRaw = SessionCondition.Posture.sitting.rawValue
    @AppStorage("interactionFingerprint.study.light") private var lightRaw = SessionCondition.Light.daylight.rawValue

    private var posture: SessionCondition.Posture { .init(rawValue: postureRaw) ?? .sitting }
    private var light: SessionCondition.Light { .init(rawValue: lightRaw) ?? .daylight }
    private var today: Int { StudyPlan.dayNumber() }

    var body: some View {
        NavigationStack {
            Form {
                Section("Participant") {
                    TextField("Label, never a name", text: $participant)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .accessibilityIdentifier("study_participant")
                }
                Section("How the phone is held right now") {
                    Picker("Posture", selection: $postureRaw) {
                        Text("Sitting").tag(SessionCondition.Posture.sitting.rawValue)
                        Text("Lying back").tag(SessionCondition.Posture.lyingBack.rawValue)
                        Text("Standing").tag(SessionCondition.Posture.standing.rawValue)
                    }
                    .pickerStyle(.segmented)
                    Picker("Light", selection: $lightRaw) {
                        Text("Daylight").tag(SessionCondition.Light.daylight.rawValue)
                        Text("Lamp").tag(SessionCondition.Light.lamp.rawValue)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    ForEach(Array(StudyPlan.order(forDay: today).enumerated()), id: \.offset) { index, entry in
                        let condition = SessionCondition(
                            participant: participant.trimmingCharacters(in: .whitespaces).isEmpty ? "P?" : participant,
                            task: entry.task, pace: entry.pace, posture: posture, light: light
                        )
                        let done = StudyLog.count(condition, day: today)
                        Button {
                            onStart(condition)
                        } label: {
                            HStack {
                                Text("\(index + 1)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.task == .browse ? "Browse" : "Search")
                                        .font(.body.weight(.semibold))
                                    Text(entry.pace == .relaxed ? "relaxed · \(Int(condition.limitSeconds)) s, no clock shown" : "hurried · \(Int(condition.limitSeconds)) s countdown")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if done > 0 {
                                    Text(done == 1 ? "done" : "done ×\(done)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                                Image(systemName: "play.fill").foregroundStyle(.tint)
                            }
                        }
                        .accessibilityIdentifier("study_start_\(entry.task.rawValue)_\(entry.pace.rawValue)")
                    }
                } header: {
                    Text("Today's block · order rotates daily")
                } footer: {
                    Text("Four sessions, one to two minutes each. Hand the phone over after starting; the prompt is read from the screen. Search ends when a product is added to the basket.")
                }
            }
            .navigationTitle("Study block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { onClose() } }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Which sessions of the block have been recorded today, kept in user defaults so the plan
/// can show ticks. The recordings themselves are the record; this is only a reminder.
enum StudyLog {
    static let key = "interactionFingerprint.study.log"

    static func entry(_ condition: SessionCondition, day: Int) -> String {
        "\(day)|\(condition.participant)|\(condition.task.rawValue)|\(condition.pace.rawValue)"
    }

    static func record(_ condition: SessionCondition, day: Int = StudyPlan.dayNumber()) {
        var log = UserDefaults.standard.stringArray(forKey: key) ?? []
        log.append(entry(condition, day: day))
        UserDefaults.standard.set(Array(log.suffix(400)), forKey: key)
    }

    static func count(_ condition: SessionCondition, day: Int = StudyPlan.dayNumber()) -> Int {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 == entry(condition, day: day) }.count
    }
}
