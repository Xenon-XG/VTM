import Foundation

nonisolated enum OfflinePackPolicy {
    static let builtInCode = "en"

    static func canonicalCode(_ code: String) -> String {
        let primary = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        let aliases = ["iw": "he", "in": "id", "nb": "no", "nn": "no", "fil": "tl"]
        return aliases[primary] ?? primary
    }

    /// One download per non-English language, shared by all translation directions.
    static func missingCodes(source: String, target: String, isInstalled: (String) -> Bool) -> [String] {
        let source = canonicalCode(source)
        let target = canonicalCode(target)
        let pair = source == target ? [source] : [source, target]
        return pair.filter { !$0.isEmpty && $0 != builtInCode && !isInstalled($0) }
    }
}
