import Foundation

/// A text-only record. Audio is deliberately not part of this type.
struct InterpretationSegment: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let source: String
    let target: String
    let original: String
    var translation: String?
    var failed: Bool = false

    init(source: String, target: String, original: String) {
        id = UUID()
        date = Date()
        self.source = source
        self.target = target
        self.original = original
    }
}

/// Keep this history private to this app and device, not in iCloud or app backups.
@MainActor
enum InterpretationHistory {
    static let capacity = 100

    private static func fileURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        var directory = support.appendingPathComponent("Interpretation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory.appendingPathComponent("history.json", isDirectory: false)
    }

    static func load() -> [InterpretationSegment] {
        guard let url = try? fileURL(),
              let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([InterpretationSegment].self, from: data)
        else { return [] }
        return Array(saved.prefix(capacity))
    }

    static func save(_ segments: [InterpretationSegment]) throws {
        let url = try fileURL()
        if segments.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } else {
            let data = try JSONEncoder().encode(Array(segments.prefix(capacity)))
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }
}
