@main
struct LiveSpeechPolicySmoke {
    static func main() {
        testLanguageChoiceAndTextFiltering()
        print("Live interpreting language routing and text filtering smoke tests passed.")
    }

    private static func testLanguageChoiceAndTextFiltering() {
        let decide = LiveRecognitionPolicy.selectedLanguageID
        precondition(decide(0, 1, [0.06, 0.04, 0.90]) == 0, "ignore higher-scoring languages not in the selected pair")
        precondition(decide(0, 1, [0.01, 0.02, 0.97]) == 1, "route a low-scoring second language when it wins the pair")
        precondition(decide(1, 0, [0.01, 0.02, 0.97]) == 1, "swapping selections does not change a strict winner")
        precondition(decide(1, 0, [0.02, 0.02, 0.96]) == 1, "a tie uses the first selection")
        precondition(decide(0, 1, [0, 0, 1]) == nil, "no usable score is an error")
        precondition(decide(0, 1, [.nan, 0.2, 0.8]) == nil, "do not guess after invalid native scores")
        precondition(decide(-1, 0, [1]) == nil, "unsupported language index cannot be routed")
        precondition(LiveRecognitionPolicy.recognizedText("  好。 ") == "好。")
        precondition(LiveRecognitionPolicy.recognizedText("这段有字幕。") == "这段有字幕。")
        precondition(LiveRecognitionPolicy.recognizedText("[BLANK_AUDIO]") == nil)
        precondition(LiveRecognitionPolicy.recognizedText("感谢观看。") == nil)
    }
}
