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
