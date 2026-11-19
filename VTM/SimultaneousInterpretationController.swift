import Foundation
import Combine

@MainActor
final class SimultaneousInterpretationController: ObservableObject {
    enum Phase: Equatable { case idle, preparing, starting, listening, finishing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var segments: [InterpretationSegment] = []
    @Published private(set) var history: [InterpretationSegment] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var translationInProgress = false
    @Published private(set) var droppedSegments = 0
    @Published private(set) var hasUnroutablePhrase = false

    private let capture = ContinuousSpeechCapture()
    private var captureObservers: Set<AnyCancellable> = []
    private var startTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var sessionID = UUID()

    init() {
        history = InterpretationHistory.load()
        capture.$failure
            .compactMap { $0 }
            .sink { [weak self] failure in
                Task { @MainActor [weak self] in
                    guard let self, self.capture.failure == failure, self.phase != .idle else { return }
                    self.stop()
                    self.errorMessage = failure
                }
            }
            .store(in: &captureObservers)
        capture.$isRunning.removeDuplicates().dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.capture.isRunning, self.phase == .listening else { return }
                    let failure = self.capture.failure
                    self.stop()
                    self.errorMessage = failure
                }
            }
            .store(in: &captureObservers)
        capture.$droppedSegments
            .sink { [weak self] count in
                Task { @MainActor [weak self] in
                    guard let self, self.capture.droppedSegments == count else { return }
                    self.droppedSegments = count
                }
            }
            .store(in: &captureObservers)
    }

    func start(recognizer: SpeechRecognizer, translator: Translator, model: WhisperModel, languageA: String, languageB: String) {
        guard phase == .idle, languageA != languageB else { return }
        errorMessage = nil
        droppedSegments = 0
        hasUnroutablePhrase = false
        segments.removeAll()
        let id = UUID()
        sessionID = id
        phase = .preparing
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let directions = try await translator.prepareContinuousDirections(languageA: languageA, languageB: languageB)
                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                self.phase = .starting
                try await self.capture.start(
                    recognizer: recognizer,
                    model: model,
                    languages: (languageA, languageB),
                    onTranscript: { [weak self] transcript, detected in
                        guard let self, self.sessionID == id else { return }
                        if detected == languageA {
                            await self.translate(transcript, using: directions.aToB,
                                                 source: languageA, target: languageB, session: id)
                        } else if detected == languageB {
                            await self.translate(transcript, using: directions.bToA,
                                                 source: languageB, target: languageA, session: id)
                        } else {
                            self.hasUnroutablePhrase = true
                        }
                    },
                    onUnroutable: { [weak self] in
                        guard let self, self.sessionID == id else { return }
                        self.hasUnroutablePhrase = true
                    }
                )
                guard self.sessionID == id else { return }
                guard self.capture.isRunning else {
                    self.stop()
                    return
                }
                self.phase = .listening
                self.startTask = nil
            } catch {
                guard self.sessionID == id else { return }
                self.stop()
                if !(error is CancellationError) {
                    self.errorMessage = (error as? LiveSpeechError)?.localizedMessage ?? error.localizedDescription
                }
            }
        }
    }

    /// Explicit stop releases the microphone now and drains the last recorded phrase.
    func finish() {
        guard phase == .listening else {
            if phase != .finishing { stop() }
            return
        }
        let id = sessionID
        phase = .finishing
        finishTask = Task { [weak self] in
            guard let self else { return }
            await self.capture.stopAndFinish()
            guard self.sessionID == id else { return }
            self.finishTask = nil
            self.stop()
        }
    }

    func stop() {
        guard phase != .idle else { return }
        sessionID = UUID()
        startTask?.cancel()
        startTask = nil
        finishTask?.cancel()
        finishTask = nil
        phase = .idle
        capture.stop()
        // Keep the transcript, but do not show an eternal spinner on canceled segments.
        if translationInProgress, let last = segments.indices.last, segments[last].translation == nil {
            segments[last].failed = true
        }
        translationInProgress = false
    }

    func clearHistory() {
        guard phase == .idle else { return }
        do {
            try InterpretationHistory.save([])
            history.removeAll()
            segments.removeAll()
        } catch {
            errorMessage = AppStrings.shared.get("未能清除同传历史。")
        }
    }

    func dismissError() { errorMessage = nil }

    private func translate(
        _ raw: String, using translate: ContinuousTranslation, source: String, target: String, session: UUID
    ) async {
        guard sessionID == session, phase != .idle else { return }
        let original = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        guard !original.isEmpty else { return }
        hasUnroutablePhrase = false
        var segment = InterpretationSegment(source: source, target: target, original: original)
        segments.append(segment)
        if segments.count > 50 { segments.removeFirst(segments.count - 50) }
        translationInProgress = true
        do {
            let text = try await translate(original)
            guard sessionID == session, !Task.isCancelled else { return }
            let translated = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
            segment.translation = translated.isEmpty ? nil : translated
            segment.failed = translated.isEmpty
        } catch {
            guard sessionID == session, !Task.isCancelled else { return }
            segment.failed = true
        }
        if let index = segments.firstIndex(where: { $0.id == segment.id }) {
            segments[index] = segment
        }
        translationInProgress = false
        history.insert(segment, at: 0)
        if history.count > InterpretationHistory.capacity {
            history.removeLast(history.count - InterpretationHistory.capacity)
        }
        do {
            try InterpretationHistory.save(history)
        } catch {
            errorMessage = AppStrings.shared.get("未能保存同传历史。")
        }
    }
}
