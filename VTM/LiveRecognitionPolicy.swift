import Foundation

nonisolated enum LiveRecognitionPolicy {
    /// Rank the two languages selected by the user. The global score is not a
    /// gate, and a tie among two usable scores always chooses language A.
    static func selectedLanguageID(first: Int32, second: Int32, probabilities: [Float]) -> Int32? {
        guard first != second,
              probabilities.indices.contains(Int(first)), probabilities.indices.contains(Int(second))
        else { return nil }
        let a = probabilities[Int(first)]
        let b = probabilities[Int(second)]
        guard (0...1).contains(a), (0...1).contains(b), a > 0 || b > 0 else { return nil }
        return a >= b ? first : second
    }

    private static let shortResponses: Set<String> = [
        "好", "对", "行", "嗯", "哦", "是", "不", "来", "走", "等", "喂", "谁", "有", "无", "错"
    ]
    private static let knownStandaloneNoise: Set<String> = ["小小姐", "字幕", "感谢观看"]

    static func recognizedText(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.hasPrefix("[BLANK_AUDIO]"),
              text.range(of: #"^\[.*\]$"#, options: .regularExpression) == nil
        else { return nil }
        let normalized = text.trimmingCharacters(
            in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        )
        guard !knownStandaloneNoise.contains(normalized),
              normalized.count >= 2 || shortResponses.contains(normalized)
        else { return nil }
        return text
    }
}
