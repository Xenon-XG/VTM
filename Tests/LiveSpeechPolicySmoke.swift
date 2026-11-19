@main
struct LiveSpeechPolicySmoke {
    static func main() {
        testLanguageChoiceAndTextFiltering()
        testCaptureSegmentation()
        print("Live interpreting language routing, text filtering and segmentation smoke tests passed.")
    }

    private static func testCaptureSegmentation() {
        let frame = LiveSpeechSegmenter.frameSize
        precondition(frame == 320)
        precondition(LiveSpeechSegmenter.pcm16(2) == Int16.max)
        precondition(LiveSpeechSegmenter.pcm16(-2) == Int16.min)
        precondition(LiveSpeechSegmenter.pcm16(0.5) == 16_384)
        precondition(LiveSpeechSegmenter.pcm16(.nan) == 0)

        // Fixed RMS rejects quiet samples. A separate classifier can retain
        // exactly those Float32 samples without gain or PCM16 quantization.
        let quiet: Float = 0.00314159
        let samples = Array(repeating: quiet, count: frame * 12)
        var classic = LiveSpeechSegmenter()
        samples.withUnsafeBufferPointer { classic.append($0) { _ in preconditionFailure() } }
        precondition(classic.finish() == nil)
        var enhanced = LiveSpeechSegmenter(isVoice: { $0[0] == quiet })
        Array(samples.prefix(137)).withUnsafeBufferPointer {
            enhanced.append($0) { _ in preconditionFailure() }
        }
        Array(samples.dropFirst(137)).withUnsafeBufferPointer {
            enhanced.append($0) { _ in preconditionFailure() }
        }
        let final = enhanced.finish()
        precondition(final?.count == frame * 24)
        precondition(final.map { Array($0.prefix(samples.count)) } == samples)

        // Classic still emits after 600ms silence, keeps 120ms pre-roll and
        // 120ms tail, and preserves the existing 4.3-second bound.
        let silence = Array(repeating: Float(0), count: frame * 30)
        let spoken = Array(repeating: Float(0.03), count: frame * 15)
        var segments: [[Float]] = []
        (silence + spoken + silence).withUnsafeBufferPointer {
            classic.append($0) { segments.append($0) }
        }
        precondition(segments.count == 1)
        precondition(segments[0].count == frame * (6 + 15 + 6))
        precondition(Array(segments[0][(frame * 6)..<(frame * 21)]) == spoken)
        var continuous = LiveSpeechSegmenter(isVoice: { _ in true })
        segments.removeAll()
        Array(repeating: Float(0.01), count: frame * 215).withUnsafeBufferPointer {
            continuous.append($0) { segments.append($0) }
        }
        precondition(segments.count == 1 && segments[0].count == frame * 215)
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
