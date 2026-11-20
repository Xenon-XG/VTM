nonisolated enum LiveSpeechDetectionMode: String, CaseIterable, Sendable {
    case enhanced
    case classic
}

/// Processes 20ms frames independent of input hardware and buffer boundaries.
nonisolated struct LiveSpeechSegmenter {
    static let frameSize = 320  // 16 kHz × 20 ms
    private static let preRollFrames = 6             // 120ms
    private static let minVoicedFrames = 12           // 240ms
    private static let minPhraseFrames = 24            // 480ms
    private static let classicFinishSilenceFrames = 30 // 600 ms
    private static let shortEnhancedSilenceFrames = 25 // 500 ms
    private static let shortEnhancedSpanFrames = 60    // 1.2 s including pre-roll
    private static let maximumFrames = 215            // 4.3s
    private static let voiceThreshold: Float = 0.013

    private let mode: LiveSpeechDetectionMode
    private let isVoice: ([Float]) -> Bool
    private var window: [Float] = []
    private var preRoll: [[Float]] = []
    private var phrase: [Float] = []
    private var voicedCount = 0
    private var silentCount = 0

    init(
        mode: LiveSpeechDetectionMode = .classic,
        isVoice: @escaping ([Float]) -> Bool = LiveSpeechSegmenter.classicIsVoice
    ) {
        self.mode = mode
        self.isVoice = isVoice
        window.reserveCapacity(Self.frameSize)
    }

    static func classicIsVoice(_ frame: [Float]) -> Bool {
        let meanSquare = frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(Self.frameSize)
        return meanSquare >= Self.voiceThreshold * Self.voiceThreshold
    }

    // WebRTC expects signed PCM16; never pass the quantized copy to Whisper.
    static func pcm16(_ sample: Float) -> Int16 {
        guard sample.isFinite else { return 0 }
        return Int16(clamping: Int((min(1, max(-1, sample)) * 32_768).rounded()))
    }

    mutating func append(_ samples: UnsafeBufferPointer<Float>, emit: ([Float]) -> Void) {
        for sample in samples {
            window.append(sample.isFinite ? sample : 0)
            if window.count == Self.frameSize {
                if let completed = consume(window) { emit(completed) }
                window.removeAll(keepingCapacity: true)
            }
        }
    }

    mutating func finish() -> [Float]? {
        if !window.isEmpty {
            window.append(contentsOf: repeatElement(0, count: Self.frameSize - window.count))
            if let completed = consume(window) { return completed }
        }
        guard voicedCount >= Self.minVoicedFrames else { return nil }
        if phrase.count < Self.minPhraseFrames * Self.frameSize {
            phrase.append(contentsOf: repeatElement(0, count: Self.minPhraseFrames * Self.frameSize - phrase.count))
        }
        return phrase
    }

    private mutating func consume(_ frame: [Float]) -> [Float]? {
        let voiced = isVoice(frame)
        if phrase.isEmpty {
            if !voiced {
                preRoll.append(frame)
                if preRoll.count > Self.preRollFrames { preRoll.removeFirst() }
                return nil
            }
            phrase.reserveCapacity(Self.maximumFrames * Self.frameSize)
            for previous in preRoll { phrase.append(contentsOf: previous) }
            preRoll.removeAll(keepingCapacity: true)
        }
        phrase.append(contentsOf: frame)
        if voiced {
            voicedCount += 1
            silentCount = 0
        } else {
            silentCount += 1
        }

        let count = phrase.count / Self.frameSize
        // The span through the last voiced frame stays fixed while silence
        // accumulates. Short utterances can finish sooner, while longer
        // phrases keep the full pause tolerance.
        let spanThroughLastVoice = count - silentCount
        let finishSilenceFrames = mode == .enhanced && spanThroughLastVoice <= Self.shortEnhancedSpanFrames
            ? Self.shortEnhancedSilenceFrames : Self.classicFinishSilenceFrames
        guard silentCount >= finishSilenceFrames || count >= Self.maximumFrames else { return nil }
        defer {
            phrase = []
            voicedCount = 0
            silentCount = 0
        }
        guard voicedCount >= Self.minVoicedFrames else { return nil }
        // Retain some trailing silence. The stream never gets unbounded input.
        let trim = min(max(0, silentCount - 6), max(0, count - Self.minPhraseFrames))
        if trim > 0 { phrase.removeLast(trim * Self.frameSize) }
        return phrase
    }
}
