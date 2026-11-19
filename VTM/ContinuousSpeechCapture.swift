import AVFoundation
import Combine
import Foundation
import UIKit

/// Foreground-only microphone capture. Recognition and delivery are serial; the tap
/// stays open while either is underway and keeps at most three pending phrases.
@MainActor
final class ContinuousSpeechCapture: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isFinishing = false
    @Published private(set) var failure: String?
    @Published private(set) var droppedSegments = 0

    private var generation = UUID()
    private var isStarting = false
    private weak var recognizer: SpeechRecognizer?
    private var captureOwner: UUID?
    private var engine: AVAudioEngine?
    private var processingTask: Task<Void, Never>?
    private var phrases: AsyncStream<[Float]>.Continuation?
    private var audioTap: LiveAudioTap?
    private var observations: [NSObjectProtocol] = []
    private var ownsAudioSession = false

    func start(
        recognizer: SpeechRecognizer,
        sourceLanguage: String,
        onTranscript: @escaping @MainActor (String) async -> Void
    ) async throws {
        guard !isRunning, !isStarting, !isFinishing else { throw LiveSpeechError.alreadyRecording }
        let owner = UUID()
        generation = owner
        isStarting = true
        failure = nil
        droppedSegments = 0

        do {
            let granted = await AVAudioApplication.requestRecordPermission()
            try ensureCurrent(owner)
            guard granted else { throw LiveSpeechError.microphonePermission }
            guard UIApplication.shared.applicationState == .active else {
                throw LiveSpeechError.needsForeground
            }

            try recognizer.claimContinuousMicrophone(owner: owner)
            self.recognizer = recognizer
            captureOwner = owner
            try await recognizer.prepareContinuousRecognition()
            try ensureCurrent(owner)
            guard UIApplication.shared.applicationState == .active else {
                throw LiveSpeechError.needsForeground
            }

            let session = AVAudioSession.sharedInstance()
            // Nothing from this mode is played back automatically. Measurement
            // mode avoids the spoken translation being captured as new input.
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            ownsAudioSession = true

            let audioEngine = AVAudioEngine()
            let input = audioEngine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw LiveSpeechError.microphoneUnavailable
            }
            let stream = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(3))
            let processor = try LiveAudioTap(
                inputFormat: inputFormat,
                continuation: stream.continuation,
                onDrop: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == owner else { return }
                        self.droppedSegments += 1
                    }
                },
                onConversionFailure: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == owner, self.isRunning else { return }
                        self.interrupt(with: LiveSpeechError.microphoneUnavailable.localizedMessage)
                    }
                }
            )
            input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat, block: processor.handler())
            engine = audioEngine
            audioTap = processor
            phrases = stream.continuation
            audioEngine.prepare()
            try audioEngine.start()
            installObservers(engine: audioEngine, owner: owner)
            isRunning = true
            isStarting = false

            processingTask = Task { @MainActor [weak self, weak recognizer] in
                for await samples in stream.stream {
                    guard !Task.isCancelled, self?.generation == owner, let recognizer else { break }
                    do {
                        let text = try await recognizer.transcribeContinuous(
                            samples: samples, sourceLanguage: sourceLanguage, owner: owner
                        )
                        guard !Task.isCancelled, self?.generation == owner else { break }
                        if !text.isEmpty { await onTranscript(text) }
                    } catch is CancellationError {
                        break
                    } catch {
                        guard self?.generation == owner else { break }
                        self?.interrupt(with: (error as? LiveSpeechError)?.localizedMessage ?? error.localizedDescription)
                        break
                    }
                }
            }
        } catch {
            if generation == owner { stop() }
            throw error
        }
    }

    /// Cancels immediately, including pending text and any in-flight UI delivery.
    /// Use for navigation, interruption, and app inactivity.
    func stop() {
        generation = UUID()
        isStarting = false
        isFinishing = false
        isRunning = false
        processingTask?.cancel()
        processingTask = nil
        disableMicrophone()
        phrases?.finish()
        phrases = nil
        audioTap = nil
        for observer in observations { NotificationCenter.default.removeObserver(observer) }
        observations.removeAll()
        if let captureOwner { recognizer?.releaseContinuousMicrophone(owner: captureOwner) }
        captureOwner = nil
        recognizer = nil
    }

    /// The user pressed Stop rather than leaving the page. Release microphone use
    /// before doing any more inference, then deliver completed words in order.
    func stopAndFinish() async {
        guard isRunning else { return }
        let owner = generation
        let pending = processingTask
        isFinishing = true
        isRunning = false
        disableMicrophone()
        audioTap?.finish()
        phrases?.finish()
        audioTap = nil
        phrases = nil
        await pending?.value
        if generation == owner { stop() }
    }

    private func disableMicrophone() {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            ownsAudioSession = false
        }
    }

    private func ensureCurrent(_ owner: UUID) throws {
        try Task.checkCancellation()
        guard generation == owner else { throw CancellationError() }
    }

    private func interrupt(with message: String?) {
        stop()
        failure = message
    }

    private func installObservers(engine: AVAudioEngine, owner: UUID) {
        let center = NotificationCenter.default
        observations.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == owner else { return }
                self.interrupt(with: nil)
            }
        })
        observations.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            guard note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == owner, self.isRunning else { return }
                self.interrupt(with: LiveSpeechError.microphoneInterrupted.localizedMessage)
            }
        })
        observations.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == owner, self.isRunning else { return }
                self.interrupt(with: LiveSpeechError.microphoneInterrupted.localizedMessage)
            }
        })
    }
}

nonisolated enum LiveSpeechError: LocalizedError {
    case alreadyRecording
    case microphonePermission
    case needsForeground
    case microphoneUnavailable
    case microphoneInterrupted
    case modelUnavailable

    @MainActor var localizedMessage: String {
        AppStrings.shared.get(errorDescription ?? "同传失败，请重试。")
    }

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "麦克风已被录音功能占用。"
        case .microphonePermission: return "请在系统设置中允许 VTM 使用麦克风。"
        case .needsForeground: return "请在 VTM 前台开启同声传译。"
        case .microphoneUnavailable: return "无法使用当前麦克风。"
        case .microphoneInterrupted: return "麦克风连接已改变或中断，请重新开始。"
        case .modelUnavailable: return "语音识别模型尚未就绪，请先下载并加载 Whisper 模型。"
        }
    }
}

/// AVAudioEngine invokes this callback on its audio thread, not on MainActor.
/// Each tap owns its converter, output buffer and segmentation state.
nonisolated private final class LiveAudioTap {
    private let converter: AVAudioConverter
    private let outputBuffer: AVAudioPCMBuffer
    private let continuation: AsyncStream<[Float]>.Continuation
    private let onDrop: @Sendable () -> Void
    private let onConversionFailure: @Sendable () -> Void
    private let lock = NSLock()
    private var finished = false
    private var reportedConversionFailure = false
    private var segmenter = LiveSpeechSegmenter()

    init(
        inputFormat: AVAudioFormat,
        continuation: AsyncStream<[Float]>.Continuation,
        onDrop: @escaping @Sendable () -> Void,
        onConversionFailure: @escaping @Sendable () -> Void
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: format),
            let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192)
        else { throw LiveSpeechError.microphoneUnavailable }
        self.converter = converter
        self.outputBuffer = outputBuffer
        self.continuation = continuation
        self.onDrop = onDrop
        self.onConversionFailure = onConversionFailure
    }

    func handler() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in process(buffer) }
    }

    /// Called only after the engine releases its microphone; lock in case its tap
    /// already entered the callback on another thread before removal.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        if let samples = segmenter.finish() { deliver(samples) }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        // PCM supplied by the tap cannot be used after this callback returns.
        // Reuse the converter and output storage to maintain resampling state.
        var providedInput = false
        var error: NSError?
        outputBuffer.frameLength = 0
        let status = converter.convert(to: outputBuffer, error: &error) { _, status in
            if providedInput {
                status.pointee = .noDataNow
                return nil
            }
            providedInput = true
            status.pointee = .haveData
            return buffer
        }
        if status == .error || error != nil {
            if !reportedConversionFailure {
                reportedConversionFailure = true
                onConversionFailure()
            }
            return
        }
        guard outputBuffer.frameLength > 0, let channel = outputBuffer.floatChannelData?[0] else { return }
        let pcm = UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength))
        segmenter.append(pcm) { [continuation, onDrop] samples in
            if case .dropped = continuation.yield(samples) { onDrop() }
        }
    }

    private func deliver(_ samples: [Float]) {
        if case .dropped = continuation.yield(samples) { onDrop() }
    }
}

/// Processes 20ms frames independent of input hardware and buffer boundaries.
/// Not a neural VAD: RMS filters silence; Whisper filters hallucinated transcript.
nonisolated private struct LiveSpeechSegmenter {
    private static let frameSize = 320
    private static let preRollFrames = 6             // 120ms
    private static let minVoicedFrames = 12           // 240ms
    private static let minPhraseFrames = 24            // 480ms
    private static let finishSilenceFrames = 30        // 600ms
    private static let maximumFrames = 215            // 4.3s
    private static let voiceThreshold: Float = 0.013

    private var window: [Float] = []
    private var preRoll: [[Float]] = []
    private var phrase: [Float] = []
    private var voicedCount = 0
    private var silentCount = 0

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
        let meanSquare = frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(Self.frameSize)
        let voiced = meanSquare >= Self.voiceThreshold * Self.voiceThreshold
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
        guard silentCount >= Self.finishSilenceFrames || count >= Self.maximumFrames else { return nil }
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
