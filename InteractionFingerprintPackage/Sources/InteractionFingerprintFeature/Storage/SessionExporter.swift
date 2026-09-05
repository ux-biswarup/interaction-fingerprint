import Foundation

/// Writes a recorded session to disk as JSON.
///
/// Two files per session. A single document for reading and archiving, and a
/// newline-delimited event file, which pandas reads directly with `lines=True` and which
/// stays readable when a session runs long enough that holding the whole array in memory
/// is wasteful.
///
/// Everything lands in the app's Documents directory so a researcher can pull it off with
/// Finder or the Files app. Nothing is uploaded anywhere.
public enum SessionExporter {

    public struct Export: Sendable, Equatable {
        public let documentURL: URL
        public let eventsURL: URL
        public let eventCount: Int
    }

    public struct Document: Codable, Sendable {
        public let session: SessionRecord
        public let events: [FingerprintEvent]
    }

    public enum ExportError: Error, LocalizedError {
        case noDocumentsDirectory

        public var errorDescription: String? {
            switch self {
            case .noDocumentsDirectory: "The app has no Documents directory to write to."
            }
        }
    }

    public static func directory() throws -> URL {
        guard let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { throw ExportError.noDocumentsDirectory }
        let folder = base.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @discardableResult
    public static func write(
        session: SessionRecord,
        events: [FingerprintEvent],
        to folder: URL? = nil
    ) throws -> Export {
        let folder = try folder ?? directory()
        let stem = "session_\(session.id)"

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Seconds since 1970 rather than a formatted string, so a reader never has to guess
        // a timezone.
        encoder.dateEncodingStrategy = .secondsSince1970

        let documentURL = folder.appendingPathComponent("\(stem).json")
        try encoder.encode(Document(session: session, events: events)).write(to: documentURL)

        let eventsURL = folder.appendingPathComponent("\(stem).jsonl")
        var lines = Data()
        for event in events {
            lines.append(try encoder.encode(event))
            lines.append(0x0A)
        }
        try lines.write(to: eventsURL)

        return Export(documentURL: documentURL, eventsURL: eventsURL, eventCount: events.count)
    }

    /// Everything a calibration produced: the chosen model and every frame it was fitted on.
    public struct CalibrationDocument: Codable, Sendable {
        public let createdAt: Date
        public let model: GazeModel?
        public let failedTargets: Int
        public let points: [GazeCalibrationPoint]
    }

    /// Writes a calibration's raw frames beside the sessions.
    ///
    /// The accuracy figure says how good a calibration is; only the points say *where* it
    /// is bad. Three calibrations in a row put their worst target in the top row, next to
    /// the camera, and that could not be investigated because the frames were thrown away
    /// the moment the model was accepted.
    @discardableResult
    public static func writeCalibration(
        model: GazeModel?,
        points: [GazeCalibrationPoint],
        failedTargets: Int,
        to folder: URL? = nil,
        at date: Date = Date()
    ) throws -> URL {
        let folder = try folder ?? directory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let url = folder.appendingPathComponent("calibration_\(Int(date.timeIntervalSince1970)).json")
        try encoder.encode(
            CalibrationDocument(createdAt: date, model: model, failedTargets: failedTargets, points: points)
        ).write(to: url)
        return url
    }

    /// The most recent calibration file, if one has been written.
    public static func latestCalibration(in folder: URL? = nil) -> URL? {
        guard let folder = try? folder ?? directory(),
              let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return nil }
        return contents
            .filter { $0.lastPathComponent.hasPrefix("calibration_") }
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Sessions already on disk, newest first.
    public static func existing() -> [URL] {
        guard let folder = try? directory(),
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
              )
        else { return [] }
        return contents
            .filter { $0.pathExtension == "json" }
            .sorted { left, right in
                let l = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
    }
}
