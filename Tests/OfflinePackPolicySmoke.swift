@main
struct OfflinePackPolicySmoke {
    static func main() {
        let missing = OfflinePackPolicy.missingCodes
        let noPacks: (String) -> Bool = { _ in false }

        precondition(OfflinePackPolicy.canonicalCode(" zh_Hans ") == "zh")
        precondition(OfflinePackPolicy.canonicalCode("EN-US") == "en")
        precondition(OfflinePackPolicy.canonicalCode("iw-IL") == "he")
        precondition(missing("en", "en-US", noPacks).isEmpty, "English is built in")
        precondition(missing("zh-Hans", "en-GB", noPacks) == ["zh"])
        precondition(missing("en-US", "zh", noPacks) == ["zh"])
        precondition(missing("ja", "fr-CA", noPacks) == ["ja", "fr"])
        precondition(missing("ja", "fr", { $0 == "ja" }) == ["fr"])
        precondition(missing("fr", "ja", { $0 == "ja" }) == ["fr"], "directions share models")
        precondition(missing("ja-JP", "ja", noPacks) == ["ja"], "never request duplicate model")
        precondition(missing("ja", "fr", { _ in true }).isEmpty)
        print("Offline language-pack policy smoke tests passed.")
    }
}
