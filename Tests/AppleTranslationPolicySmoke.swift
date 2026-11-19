@main
struct AppleTranslationPolicySmoke {
    static func main() {
        precondition(VTMTranslationEngine.preference(from: nil) == .mlKit)
        precondition(VTMTranslationEngine.preference(from: "future-choice") == .mlKit)
        precondition(VTMTranslationEngine.preference(from: "apple") == .apple)
        precondition(VTMTranslationEngine.preference(from: "mlKit") == .mlKit)
        precondition(AppleTranslationPolicy.pair("zh", "en")?.source == "zh-Hans")
        precondition(AppleTranslationPolicy.pair("en", "zh_CN")?.target == "zh-Hans")
        precondition(AppleTranslationPolicy.pair("zh-HK", "ja")?.source == "zh-Hant")
        precondition(AppleTranslationPolicy.pair("zh", "zh-Hans") == nil)
        precondition(AppleTranslationPolicy.pair("", "ja") == nil)
        precondition(AppleTranslationAvailability.bidirectional(.installed, .installed) == .installed)
        precondition(AppleTranslationAvailability.bidirectional(.missing, .installed) == .missing)
        precondition(AppleTranslationAvailability.bidirectional(.installed, .unsupported) == .unsupported)
        precondition(AppleTranslationAvailability.bidirectional(.missing, .unavailable) == .unavailable)
        print("Apple translation selection and pair policy smoke tests passed.")
    }
}
