import Foundation

/// The circumstances a session was recorded under, set on purpose before it starts.
///
/// Phase 4 is a repeated-measures study of a few people over many days. Its questions are
/// which features hold still for a person across days and which move when the situation
/// is changed deliberately. Every session therefore carries its condition in the record,
/// where analysis reads it, rather than in anyone's notebook. See
/// `docs/product/04-EXPERIMENT-PLAN.md`.
public struct SessionCondition: Codable, Sendable, Equatable, Hashable {
    /// What the participant is asked to do.
    public enum Task: String, Codable, Sendable, CaseIterable {
        /// Look around with nothing to find. Ends by itself at the time limit.
        case browse
        /// Find the cheapest product rated 4 or more and add it to the basket. Ends on the
        /// selection, or at the time limit.
        case search
    }

    /// Whether time pressure is applied. Hurried shows a countdown; relaxed shows nothing,
    /// though it too has a limit so sessions stay comparable in length.
    public enum Pace: String, Codable, Sendable, CaseIterable {
        case relaxed
        case hurried
    }

    public enum Posture: String, Codable, Sendable, CaseIterable {
        case sitting
        case lyingBack = "lying_back"
        case standing
    }

    public enum Light: String, Codable, Sendable, CaseIterable {
        case daylight
        case lamp
    }

    /// A label the researcher assigns, such as `P1`. Never a name.
    public var participant: String
    public var task: Task
    public var pace: Pace
    public var posture: Posture
    public var light: Light

    public init(participant: String, task: Task, pace: Pace, posture: Posture, light: Light) {
        self.participant = participant
        self.task = task
        self.pace = pace
        self.posture = posture
        self.light = light
    }

    /// Seconds after which the session ends by itself.
    public var limitSeconds: TimeInterval {
        switch (task, pace) {
        case (.browse, .relaxed): 90
        case (.browse, .hurried): 45
        case (.search, .relaxed): 120
        case (.search, .hurried): 45
        }
    }

    public var showsCountdown: Bool { pace == .hurried }
    public var endsOnSelection: Bool { task == .search }

    /// Read to the participant by the app, word for word, every time.
    public var prompt: String {
        switch task {
        case .browse: "Browse the shop as you would in a spare minute. There is nothing to find."
        case .search: "Find the cheapest product with a rating of 4 or more and add it to the basket."
        }
    }

    public var paceNote: String {
        switch pace {
        case .relaxed: "Take your time."
        case .hurried: "You have \(Int(limitSeconds)) seconds. A countdown will show."
        }
    }

    public var shortLabel: String { "\(task.rawValue) · \(pace.rawValue)" }
}

/// The block structure of the study: four sessions, one per task and pace, in an order
/// that rotates with the day so that order effects cancel over the ten days.
public enum StudyPlan {
    public static let sessions: [(task: SessionCondition.Task, pace: SessionCondition.Pace)] = [
        (.browse, .relaxed), (.browse, .hurried), (.search, .relaxed), (.search, .hurried),
    ]

    /// The four sessions of a block for a given day. Four rotations of a fixed order over
    /// consecutive days: each session appears in each position once every four days, which
    /// balances first-in-block and last-in-block over the study.
    public static func order(forDay day: Int) -> [(task: SessionCondition.Task, pace: SessionCondition.Pace)] {
        let shift = ((day % 4) + 4) % 4
        return Array(sessions[shift...] + sessions[..<shift])
    }

    /// Day number for rotation: days since the epoch in the local calendar.
    public static func dayNumber(for date: Date = Date(), calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: Date(timeIntervalSince1970: 0), to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// The right answer to the search task, from the catalogue itself so the task text and
    /// the check can never disagree. Rating at least 4.0, then cheapest.
    public static func correctSearchProduct(in catalogue: [Product]) -> Product? {
        catalogue.filter { $0.rating >= 4.0 }.min { $0.priceGBP < $1.priceGBP }
    }
}
