//
//  SpeechRecognizer.swift
//  VTM
//
//  基于 whisper.cpp 的本地语音识别引擎
//  - 替代 Apple SFSpeechRecognizer
//  - 完全离线，无需网络
//  - 支持多语言（需下载对应模型）
//

import Foundation
import AVFoundation
import Combine
import whisper
import UIKit

// MARK: - SpeechRecognizer (ObservableObject)

class SpeechRecognizer: ObservableObject {
    @Published var transcribedText: String = ""
    @Published var isRecording: Bool = false
    @Published var errorMessage: String?
    @Published var isModelLoaded: Bool = false

    private var whisperContext: WhisperContext?
    private var loadedModelPath: String?
    private var liveModelPath: String?
    private var activeInferences = 0
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recordingStartTime: Date?
    private var continuousMicrophoneOwner: UUID?
    private var isFinishingRecording = false

    /// 标记正在加载模型，防止此期间内存警告误卸载
    private var isLoadingModels = false

    /// 最短有效录音时长（秒），低于此值视为误触
    static let minRecordingDuration: TimeInterval = 0.5

    /// 短录音时长阈值 — 低于此值视为"可能误触"，使用更严格的过滤策略
    /// 提高到 1.2s：用户按住 ~1s 后的短暂噪音（如"小小姐"幻觉）会被更严格地过滤
    static let shortRecordingThreshold: TimeInterval = 1.2

    /// 普通录音 RMS 静音阈值 — 低于此值视为静音
    static let normalSilenceRMS: Float = 0.008

    /// 短录音 RMS 静音阈值 — 更严格（关门声等尖锐噪音峰值高但无持续语音特征）
    /// 提高到 0.025：1 秒左右的环境噪音 RMS 通常 < 0.02，真实语音 > 0.03
    static let shortSilenceRMS: Float = 0.025

    /// 最短有效字符数 — 转录结果少于此值视为噪音幻觉
    /// 设为 2：允许真实短词（"你好"、"乐观"、"可以"等），拒绝单字噪音（"嗯"、"啊"）
    /// "小小姐" 等 3 字已知幻觉由 hallucinationPatterns 黑名单拦截
    static let minTranscriptionLength = 2

    /// 幻觉模式黑名单 — 静音录音时 Whisper 可能产生的伪影
    /// 含这些子串的转录结果直接丢弃
    static let hallucinationPatterns: [String] = [
        "小小姐",     // 短录音 Whisper 幻觉（与训练数据中的影视字幕相关）
        "字幕",      // 日/中文字幕标记幻觉，如 "(字幕：小小姐)"
        "感谢观看",   // 视频结尾伪影
        "订阅",      // YouTube 订阅呼吁
        "点赞",      // 社交媒体伪影
        "♪",        // 音乐符号
        "♫",        // 音乐符号
    ]

    /// 当前录音的语言提示（用于 Whisper initial_prompt 引导标点符号输出）
    private var transcriptionLanguage: String?

    /// 当前录音临时文件路径
    private var recordingFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vtm_recording.wav")
    }

    // MARK: - Lifecycle

    init() {
        // 监听内存警告：内存不足时自动卸载模型防止 OOM 崩溃
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        // NLLB 即将加载 → Whisper 主动卸载让出内存
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNLLBWillLoad),
            name: NSNotification.Name("NLLBWillLoad"),
            object: nil
        )
    }

    // MARK: - Memory Management

    /// 释放 Whisper 模型内存（~466MB），供 NLLB 或系统使用
    func unload() {
        guard !isLoadingModels else {
            VTMLog.memory("🟡 正在加载 Whisper 模型，跳过卸载")
            return
        }
        VTMLog.memory("🟡 Whisper 主动卸载，释放 ~466MB 内存")
        clearLoadedModel()
    }

    @objc private func handleMemoryWarning() {
        // 模型加载中 → 不卸载（避免竞态：上下文已创建但 isModelLoaded 未设）
        guard !isLoadingModels else {
            VTMLog.memory("🟡 收到内存警告但正在加载模型，跳过卸载")
            return
        }
        VTMLog.memory("🟡 收到内存警告，卸载 Whisper 模型释放内存")
        clearLoadedModel()
    }

    @objc private func handleNLLBWillLoad() {
        VTMLog.memory("📢 收到 NLLBWillLoad 通知 → 卸载 Whisper 释放内存")
        unload()
    }

    // MARK: - Model Loading

    private func clearLoadedModel() {
        whisperContext = nil
        loadedModelPath = nil
        isModelLoaded = false
    }

    private func modelPath(_ url: URL) -> String { url.standardizedFileURL.path }

    /// Wait for an existing load or a canceled decode to finish before allocating
    /// another model. Whisper context memory must not overlap during switching.
    private func loadNativeModel(path: String, continuousOwner owner: UUID? = nil) async throws {
        let path = modelPath(URL(fileURLWithPath: path))
        func validateOwner() throws {
            try Task.checkCancellation()
            guard continuousMicrophoneOwner == owner, audioRecorder == nil, !isFinishingRecording else {
                throw CancellationError()
            }
        }

        try validateOwner()
        while isLoadingModels || activeInferences > 0 {
            try await Task.sleep(for: .milliseconds(75))
            try validateOwner()
        }
        if whisperContext != nil, loadedModelPath == path { return }

        isLoadingModels = true
        defer { isLoadingModels = false }
        clearLoadedModel()
        // NLLB and Whisper never need to occupy memory simultaneously.
        NotificationCenter.default.post(name: NSNotification.Name("WhisperWillLoad"), object: nil)

        let context: WhisperContext = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try WhisperContext.createContext(path: path))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        try validateOwner()
        whisperContext = context
        loadedModelPath = path
        isModelLoaded = true
        errorMessage = nil
        VTMLog.model("✅ Whisper 模型已加载: \(path)")
    }

    /// Existing push-to-talk and model management entry point.
    func loadModel(path: String) async {
        do {
            try await loadNativeModel(path: path)
        } catch is CancellationError {
            // A foreground interpreting session owns the model or the caller left.
        } catch {
            errorMessage = "模型加载失败: \(error.localizedDescription)"
            VTMLog.error("Whisper 模型加载失败: \(error)", category: "Model")
        }
    }

    func loadDefaultModel() async {
        guard continuousMicrophoneOwner == nil else { return }
        if let model = WhisperModel.recommendedModel() {
            await loadModel(path: model.fileURL.path)
        } else {
            errorMessage = "未找到已下载的模型，请先下载模型"
        }
    }

    // MARK: - Continuous foreground recognition

    func claimContinuousMicrophone(owner: UUID) throws {
        guard continuousMicrophoneOwner == nil, audioRecorder == nil, !isFinishingRecording else {
            throw LiveSpeechError.alreadyRecording
        }
        continuousMicrophoneOwner = owner
    }

    func releaseContinuousMicrophone(owner: UUID) {
        guard continuousMicrophoneOwner == owner else { return }
        continuousMicrophoneOwner = nil
        defer { liveModelPath = nil }
        // Keep the default warm only if this session selected the exact same file.
        // A live-only choice must not silently become the legacy tab's model.
        if let liveModelPath, loadedModelPath == liveModelPath,
           WhisperModel.recommendedModel().map({ modelPath($0.fileURL) }) != liveModelPath {
            clearLoadedModel()
        }
    }

    func prepareContinuousRecognition(model: WhisperModel, owner: UUID) async throws {
        guard continuousMicrophoneOwner == owner else { throw CancellationError() }
        let path = modelPath(model.fileURL)
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw LiveSpeechError.selectedModelNotDownloaded
        }
        liveModelPath = path
        do {
            try await loadNativeModel(path: path, continuousOwner: owner)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            VTMLog.error("Whisper 同传模型加载失败: \(error)", category: "Model")
            throw LiveSpeechError.modelUnavailable
        }
        guard whisperContext != nil, loadedModelPath == path else { throw LiveSpeechError.modelUnavailable }
    }

    func transcribeContinuous(
        samples: [Float], languages: ContinuousLanguagePair, owner: UUID
    ) async throws -> ContinuousSpeechResult {
        guard continuousMicrophoneOwner == owner else { throw CancellationError() }
        guard let context = whisperContext, let liveModelPath, loadedModelPath == liveModelPath else {
            throw LiveSpeechError.modelUnavailable
        }
        guard !samples.isEmpty else { return .empty }
        try Task.checkCancellation()
        activeInferences += 1
        defer { activeInferences -= 1 }
        let detected = await context.transcribeBidirectionally(samples: samples, languages: languages)
        try Task.checkCancellation()
        guard continuousMicrophoneOwner == owner else { throw CancellationError() }
        guard case let .recognized(raw, sourceLanguage) = detected else { return detected }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= Self.minTranscriptionLength,
              !text.hasPrefix("[BLANK_AUDIO]"),
              text.range(of: #"^\[.*\]$"#, options: .regularExpression) == nil,
              !Self.hallucinationPatterns.contains(where: { text.contains($0) })
        else { return .empty }
        return .recognized(text, sourceLanguage: sourceLanguage)
    }

    // MARK: - Recording

    /// 开始录音
    /// - Parameter language: 源语言代码（如 "zh"、"en"），用于 Whisper 标点符号引导
    func startRecording(language: String? = nil) throws {
        guard continuousMicrophoneOwner == nil, audioRecorder == nil, !isFinishingRecording else {
            throw LiveSpeechError.alreadyRecording
        }
        CrashDiagnostics.log("SR.startRecording: ENTERED")
        CrashDiagnostics.logMemory(tag: "sr.startRecording.enter")
        CrashDiagnostics.log("SR.startRecording: guard isModelLoaded")
        guard isModelLoaded else {
            CrashDiagnostics.log("SR.startRecording: FAIL - model not loaded")
            throw NSError(domain: "SpeechRecognizer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "模型未加载，无法录音"])
        }

        // 存储语言提示，转录时使用
        self.transcriptionLanguage = language

        CrashDiagnostics.log("SR.startRecording: AVAudioSession.sharedInstance()")
        let session = AVAudioSession.sharedInstance()

        CrashDiagnostics.log("SR.startRecording: setCategory(.playAndRecord)")
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])

        CrashDiagnostics.log("SR.startRecording: setActive(true)")
        CrashDiagnostics.logMemory(tag: "sr.preactivateAudio")
        try session.setActive(true)
        CrashDiagnostics.logMemory(tag: "sr.postactivateAudio")

        CrashDiagnostics.log("SR.startRecording: building settings dict")
        // WAV 16kHz mono — whisper.cpp 所需格式
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        CrashDiagnostics.log("SR.startRecording: recordingURL setup")
        recordingURL = recordingFile

        CrashDiagnostics.log("SR.startRecording: removeItem if exists")
        // 删除旧录音文件
        if FileManager.default.fileExists(atPath: recordingFile.path) {
            try? FileManager.default.removeItem(at: recordingFile)
        }

        CrashDiagnostics.log("SR.startRecording: AVAudioRecorder init(url:settings:)")
        CrashDiagnostics.logMemory(tag: "sr.beforeRecorderInit")
        let recorder = try AVAudioRecorder(url: recordingFile, settings: settings)
        CrashDiagnostics.logMemory(tag: "sr.afterRecorderInit")

        CrashDiagnostics.log("SR.startRecording: recorder.record()")
        guard recorder.record() else {
            CrashDiagnostics.log("SR.startRecording: FAIL - record() returned false")
            throw NSError(domain: "SpeechRecognizer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "启动录音失败"])
        }
        self.audioRecorder = recorder

        CrashDiagnostics.log("SR.startRecording: recordingStartTime = Date()")
        recordingStartTime = Date()

        CrashDiagnostics.log("SR.startRecording: DispatchQueue.main.async")
        DispatchQueue.main.async {
            guard self.audioRecorder === recorder else { return }
            CrashDiagnostics.log("SR.startRecording: isRecording = true (in async)")
            self.isRecording = true
            self.transcribedText = ""
            self.errorMessage = nil
        }

        CrashDiagnostics.log("SR.startRecording: SUCCESS ✓")
    }

    /// Abandon an existing manual recording without starting inference.
    func cancelManualRecording() {
        guard continuousMicrophoneOwner == nil, let recorder = audioRecorder else { return }
        recorder.stop()
        audioRecorder = nil
        recordingStartTime = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// 停止录音并等待转录完成（async）
    /// - Returns: 转录后的文本（空字符串表示无有效语音）
    func stopRecording() async -> String {
        guard continuousMicrophoneOwner == nil, let recorder = audioRecorder,
              !isFinishingRecording else { return "" }
        isFinishingRecording = true
        defer { isFinishingRecording = false }
        recorder.stop()
        audioRecorder = nil

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartTime = nil

        await MainActor.run {
            self.isRecording = false
        }

        // 录音太短 → 直接跳过，不浪费 whisper 推理
        if duration < Self.minRecordingDuration {
            await MainActor.run {
                self.transcribedText = ""
            }
            print("⏱️ 录音时长 \(String(format: "%.2f", duration))s < \(String(format: "%.1f", Self.minRecordingDuration))s，跳过转写")
            return ""
        }

        guard let url = recordingURL else { return "" }

        // 等待转录完成
        await transcribe(url: url, duration: duration)

        // 切换音频会话为播放模式（TTS 需要）
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            print("🔊 音频会话切换为播放模式")
        } catch {
            print("⚠️ 音频会话切换失败: \(error)")
        }

        return transcribedText
    }

    // MARK: - Transcription

    private func transcribe(url: URL, duration: TimeInterval) async {
        guard let context = whisperContext else {
            await MainActor.run {
                errorMessage = "模型未加载，无法转写"
            }
            return
        }

        do {
            let samples = try decodeWaveFile(url)

            // 🔇 静音检测 — 根据录音时长采用不同阈值
            // 短录音（< 0.8s）容易误触（关门声等），使用更严格的 RMS 阈值
            let rmsThreshold: Float = duration < Self.shortRecordingThreshold
                ? Self.shortSilenceRMS  // 0.015 → 更严格
                : Self.normalSilenceRMS  // 0.008 → 正常

            let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
            if rms < rmsThreshold {
                await MainActor.run {
                    self.transcribedText = ""
                    print("🔇 检测到静音/噪音 (时长=\(String(format: "%.2f", duration))s, RMS=\(String(format: "%.5f", rms)), 阈值=\(rmsThreshold))，跳过转写")
                }
                return
            }

            let lang = transcriptionLanguage
            // 🩹 短录音（< 2s）跳过 initial_prompt：内容太少时 Whisper 会"续写"prompt 文本
            // 导致 "你好" 变成 "你好，请问今天天气怎么样？..."
            let skipPrompt = duration < 2.0
            activeInferences += 1
            let text = await context.fullTranscribe(samples: samples, language: lang, skipPrompt: skipPrompt)
            activeInferences -= 1

            await MainActor.run {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

                // 过滤 whisper 的空白音频标记和无效输出
                if trimmed.isEmpty
                    || trimmed == "[BLANK_AUDIO]"
                    || trimmed.hasPrefix("[BLANK_AUDIO]")
                    || trimmed.range(of: #"^\[.*\]$"#, options: .regularExpression) != nil {
                    self.transcribedText = ""
                    print("🎙️ 识别结果为空/空白标记，已过滤")
                } else if trimmed.count < Self.minTranscriptionLength {
                    // 转录结果太短（如关门声被幻觉成单个字母） → 视为噪音
                    self.transcribedText = ""
                    print("🎙️ 识别结果过短 (\"\(trimmed)\", \(trimmed.count)字 < \(Self.minTranscriptionLength))，视为噪音过滤")
                } else if Self.hallucinationPatterns.contains(where: { trimmed.contains($0) }) {
                    // 转录结果包含已知幻觉模式 → 丢弃
                    let matched = Self.hallucinationPatterns.first(where: { trimmed.contains($0) }) ?? ""
                    self.transcribedText = ""
                    print("🎙️ 识别结果含幻觉模式 \"\(matched)\"，已过滤: \"\(trimmed)\"")
                } else {
                    self.transcribedText = trimmed
                    print("🎙️ 识别结果: \(self.transcribedText)")
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = "转写失败: \(error.localizedDescription)"
                print("❌ 转写失败: \(error)")
            }
        }
    }
}

// MARK: - WAV 解码工具

/// 将 16kHz mono WAV 文件解码为 Float 采样数组（whisper.cpp 所需格式）
fileprivate func decodeWaveFile(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    let floats = stride(from: 44, to: data.count, by: 2).map {
        return data[$0..<$0 + 2].withUnsafeBytes {
            let short = Int16(littleEndian: $0.load(as: Int16.self))
            return max(-1.0, min(Float(short) / 32767.0, 1.0))
        }
    }
    return floats
}

// MARK: - Live interpretation language routing

nonisolated enum ContinuousSpeechResult: Sendable {
    case recognized(String, sourceLanguage: String)
    case unroutable
    case empty
}

nonisolated struct ContinuousLanguagePair: Sendable {
    private struct Choice: Sendable {
        let selection: String
        let whisperCode: String
        let id: Int32

        init?(_ selection: String) {
            let base = selection.replacingOccurrences(of: "_", with: "-").split(separator: "-").first
            guard let base else { return nil }
            let aliases = ["iw": "he", "in": "id", "nb": "no", "nn": "no"]
            let lower = base.lowercased()
            let code = aliases[lower] ?? lower
            let id = code.withCString(whisper_lang_id)
            guard id >= 0 else { return nil }
            self.selection = selection
            whisperCode = code
            self.id = id
        }
    }

    private let first: Choice
    private let second: Choice

    init(_ languages: (String, String)) throws {
        guard let first = Choice(languages.0), let second = Choice(languages.1), first.id != second.id else {
            throw LiveSpeechError.invalidLanguagePair
        }
        self.first = first
        self.second = second
    }

    /// A selected language has to win globally, not merely win against the other
    /// selected language: a confident third language must not be translated.
    func acceptedLanguage(topID: Int32, probabilities: [Float], sampleCount: Int)
        -> (source: String, whisperCode: String)? {
        let top = Int(topID)
        guard probabilities.indices.contains(top) else { return nil }
        let choice = topID == first.id ? first : (topID == second.id ? second : nil)
        guard let choice else { return nil }
        let probability = probabilities[top]
        guard probability.isFinite, probability >= 0 else { return nil }
        let runnerUp = probabilities.enumerated()
            .filter { $0.offset != top && $0.element.isFinite }
            .map(\.element).max() ?? 0
        // Very short phrases have much less evidence. Prefer asking for a
        // clearer phrase to silently sending text in the wrong direction.
        let shortPhrase = sampleCount < 16_000
        guard probability >= (shortPhrase ? 0.68 : 0.53),
              probability - runnerUp >= (shortPhrase ? 0.25 : 0.17) else { return nil }
        return (choice.selection, choice.whisperCode)
    }
}

// MARK: - WhisperContext (内嵌 Actor)

/// whisper.cpp C 桥接层（actor 保证线程安全）
actor WhisperContext {
    private var context: OpaquePointer

    init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        whisper_free(context)
    }

    /// Detect from microphone audio, not the script of the decoded text.
    /// Use the scores of all Whisper languages to reject uncertain directions.
    /// Reuse the mel spectrogram for one recognition pass once routing is known.
    func transcribeBidirectionally(samples: [Float], languages: ContinuousLanguagePair) -> ContinuousSpeechResult {
        guard !Task.isCancelled else { return .empty }
        guard whisper_is_multilingual(context) != 0 else { return .unroutable }
        let threads = Int32(max(1, min(8, cpuCount() - 2)))
        let melStatus = samples.withUnsafeBufferPointer {
            whisper_pcm_to_mel(context, $0.baseAddress, Int32($0.count), threads)
        }
        guard melStatus == 0 else { return .unroutable }

        var probabilities = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        let detectedID = probabilities.withUnsafeMutableBufferPointer {
            whisper_lang_auto_detect(context, 0, threads, $0.baseAddress)
        }
        guard let language = languages.acceptedLanguage(
            topID: detectedID, probabilities: probabilities, sampleCount: samples.count
        ) else { return .unroutable }
        guard !Task.isCancelled else { return .empty }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = threads
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.detect_language = false
        params.no_context = true
        params.token_timestamps = false
        params.vad = false
        params.offset_ms = 0
        let status = language.whisperCode.withCString {
            params.language = $0
            // v1.8.7 skips its PCM-to-mel step when n_samples == 0. It
            // then decodes the existing mel data instead of recomputing it.
            return whisper_full(context, params, nil, 0)
        }
        guard status == 0 else { return .empty }
        return .recognized(getTranscription(), sourceLanguage: language.source)
    }

    /// Keep the native decode and result read in one actor call, so two callers
    /// can never observe the other decode's segments.
    func fullTranscribe(
        samples: [Float], language: String? = nil, skipPrompt: Bool = false, printRealtime: Bool = true
    ) -> String {
        guard !samples.isEmpty else { return "" }
        let maxThreads = max(1, min(8, cpuCount() - 2))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        let langStr = language ?? "auto"
        let promptText = skipPrompt ? nil : Self.initialPrompt(for: langStr)

        params.print_realtime   = printRealtime
        params.print_progress   = false
        params.print_timestamps = false
        params.print_special    = false
        params.translate        = false
        params.n_threads        = Int32(maxThreads)
        params.offset_ms        = 0
        params.no_context       = true
        params.single_segment   = false

        let result: Int32 = langStr.withCString { langPtr in
            params.language = langPtr

            // ML Kit uses punctuation; retain the original prompt behavior for
            // the manual mode, but not for short continuous segments.
            if let prompt = promptText {
                return prompt.withCString { promptPtr in
                    params.initial_prompt = promptPtr
                    params.carry_initial_prompt = false
                    whisper_reset_timings(context)
                    return samples.withUnsafeBufferPointer {
                        whisper_full(context, params, $0.baseAddress, Int32($0.count))
                    }
                }
            }
            whisper_reset_timings(context)
            return samples.withUnsafeBufferPointer {
                whisper_full(context, params, $0.baseAddress, Int32($0.count))
            }
        }
        guard result == 0 else {
            print("❌ whisper_full 执行失败")
            return ""
        }
        return getTranscription()
    }

    // MARK: - initial_prompt 模板

    /// 根据语言返回标点符号引导文本
    /// Whisper 会从这些文本中学习标点风格，从而在输出中更倾向于添加标点
    private static func initialPrompt(for language: String) -> String? {
        switch language {
        // 中文：包含逗号、句号、问号、感叹号
        case "zh", "zh-CN", "zh-TW", "zh-HK", "zh-Hans", "zh-Hant", "chinese":
            return "你好，请问今天天气怎么样？我想去公园散步，但是不知道会不会下雨。好吧，那我们带把伞吧！"

        // 英文：包含 commas, periods, question marks, exclamation marks
        case "en", "en-US", "en-GB", "en-AU", "english":
            return "Hello, how are you today? I'd like to go for a walk, but I'm not sure if it will rain. Well, let's bring an umbrella then!"

        // 日文：包含句読点
        case "ja", "japanese":
            return "こんにちは、今日の天気はどうですか？散歩に行きたいのですが、雨が降るかもしれません。では、傘を持っていきましょう。"

        // 韩文
        case "ko", "korean":
            return "안녕하세요, 오늘 날씨가 어떻습니까? 산책하러 가고 싶은데, 비가 올지 모르겠네요. 그럼, 우산을 가져갑시다."

        // 其他语言：使用通用英文提示（包含标点）
        default:
            return "Hello, how are you? I'd like to go for a walk, but I'm not sure about the weather. Well, let's go anyway!"
        }
    }

    private func getTranscription() -> String {
        var transcription = ""
        for i in 0..<whisper_full_n_segments(context) {
            transcription += String(cString: whisper_full_get_segment_text(context, i))
        }
        // 🛡 安全过滤：去除 whisper 可能产生的训练数据伪影
        // 例如 "*subs by @dryfus*"、"[MUSIC]" 等标记
        var cleaned = transcription
            .replacingOccurrences(of: #"\*[^*]+\*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[MUSIC\]"#, with: "", options: .regularExpression)
        // 清理可能出现的多余空格
        cleaned = cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return cleaned
    }

    static func createContext(path: String) throws -> WhisperContext {
        var params = whisper_context_default_params()
#if targetEnvironment(simulator)
        params.use_gpu = false
        print("🔧 模拟器环境，使用 CPU 推理")
#else
        params.flash_attn = true
#endif
        let context = whisper_init_from_file_with_params(path, params)
        if let context {
            return WhisperContext(context: context)
        } else {
            print("❌ 无法加载模型: \(path)")
            throw NSError(domain: "WhisperContext", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法初始化 Whisper 模型上下文"])
        }
    }
}

private func cpuCount() -> Int {
    ProcessInfo.processInfo.processorCount
}
