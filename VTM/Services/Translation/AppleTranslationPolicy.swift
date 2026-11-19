import Foundation

nonisolated enum VTMTranslationEngine: String, CaseIterable, Sendable {
    case mlKit
    case apple

    static let preferenceKey = "translationEngine"

    static func preference(from rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .mlKit
    }

    static var storedPreference: Self {
        preference(from: UserDefaults.standard.string(forKey: preferenceKey))
    }
}

nonisolated enum AppleTranslationAvailability: Equatable, Sendable {
    case installed
    case missing
    case unsupported
    case unavailable

    static func bidirectional(_ forward: Self, _ reverse: Self) -> Self {
        if forward == .unavailable || reverse == .unavailable { return .unavailable }
        if forward == .unsupported || reverse == .unsupported { return .unsupported }
        if forward == .missing || reverse == .missing { return .missing }
        return .installed
    }
}

nonisolated enum AppleTranslationPolicy {
    static func languageIdentifier(_ code: String) -> String {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        switch normalized.lowercased() {
        case "zh", "zh-cn", "zh-sg", "zh-hans": return "zh-Hans"
        case "zh-tw", "zh-hk", "zh-mo", "zh-hant": return "zh-Hant"
        default: return normalized
        }
    }

    static func pair(_ source: String, _ target: String) -> (source: String, target: String)? {
        let a = languageIdentifier(source)
        let b = languageIdentifier(target)
        guard !a.isEmpty, !b.isEmpty, a.lowercased() != b.lowercased() else { return nil }
        return (a, b)
    }
}
