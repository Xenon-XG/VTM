@main
struct LiveSpeechPolicySmoke {
    static func main() {
        testLanguageChoiceAndTextFiltering()
        testCaptureSegmentation()
        testEnhancedEndpoint()
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

    private static func testEnhancedEndpoint() {
        let frame = LiveSpeechSegmenter.frameSize
        var enhanced = LiveSpeechSegmenter(mode: .enhanced, isVoice: { $0[0] > 0 })
        var classic = LiveSpeechSegmenter(mode: .classic, isVoice: { $0[0] > 0 })
        var fastOut: [[Float]] = []
        var oldOut: [[Float]] = []

        func push(_ value: Float, _ frames: Int) {
            Array(repeating: value, count: frame * frames).withUnsafeBufferPointer {
                enhanced.append($0) { fastOut.append($0) }
                classic.append($0) { oldOut.append($0) }
            }
        }

        push(0, 6)
        push(0.03, 12)
        push(0, 20) // a 400 ms pause must not close either phrase
        precondition(fastOut.isEmpty && oldOut.isEmpty)
        push(0.04, 12)
        push(0, 24)
        precondition(fastOut.isEmpty && oldOut.isEmpty)
        push(0, 1)
        precondition(fastOut.count == 1 && oldOut.isEmpty)
        push(0, 4)
        precondition(oldOut.isEmpty)
        push(0, 1)
        precondition(oldOut == fastOut, "500/600 ms closing must not alter the emitted speech PCM")
        precondition(fastOut[0].count == frame * (6 + 12 + 20 + 12 + 6))

        // Six pre-roll frames plus 55 voiced frames exceed the short span
        // cutoff; the Enhanced path must use the same 600 ms as Classic.
        enhanced = LiveSpeechSegmenter(mode: .enhanced, isVoice: { $0[0] > 0 })
        classic = LiveSpeechSegmenter(mode: .classic, isVoice: { $0[0] > 0 })
        fastOut.removeAll()
        oldOut.removeAll()
        push(0, 6)
        push(0.03, 55)
        push(0, 29)
        precondition(fastOut.isEmpty && oldOut.isEmpty)
        push(0, 1)
        precondition(fastOut.count == 1 && fastOut == oldOut)

        fastOut.removeAll()
        oldOut.removeAll()
        push(0.03, 11)
        push(0, 30)
        precondition(fastOut.isEmpty && oldOut.isEmpty, "retain the minimum voiced duration")
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
