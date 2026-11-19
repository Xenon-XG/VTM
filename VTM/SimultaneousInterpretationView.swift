import SwiftUI

struct SimultaneousInterpretationView: View {
    let isTabSelected: Bool

    @ObservedObject private var strings = AppStrings.shared
    @EnvironmentObject private var speechRecognizer: SpeechRecognizer
    @EnvironmentObject private var translator: Translator
    @EnvironmentObject private var ttsManager: TTSManager
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = SimultaneousInterpretationController()
    @AppStorage("continuousInterpretationSource") private var source = "zh"
    @AppStorage("continuousInterpretationTarget") private var target = "en"
    @State private var showHistory = false
    @State private var showClearConfirmation = false

    // Common languages shared by Whisper and this app's ML Kit router.
    private static let choices = ["zh", "en", "ja", "ko", "fr", "es", "de", "it", "pt",
                                  "ru", "ar", "hi", "vi", "th", "id", "nl", "tr", "uk"]
        .filter { TranslationRouter.isMLKitSupported(sourceLang: $0, targetLang: "en") }

    private var busy: Bool { controller.phase != .idle }
    private var hasWhisperModel: Bool { speechRecognizer.isModelLoaded || !WhisperModel.downloadedModels().isEmpty }

    var body: some View {
        NavigationStack {
            Group {
                if controller.segments.isEmpty && controller.history.isEmpty {
                    emptyState
                } else {
                    liveFeed
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { controls }
            .safeAreaInset(edge: .bottom, spacing: 0) { microphoneControls }
            .navigationTitle(Text(L10n: "同声传译"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showHistory = true
                    } label: {
                        Label(L10n: "同传历史", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
        }
        .sheet(isPresented: $showHistory) { historySheet }
        .onChange(of: isTabSelected) { _, selected in
            if !selected { controller.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || (phase == .inactive && [.listening, .finishing].contains(controller.phase)) {
                controller.stop()
            }
        }
        .onDisappear { controller.stop() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    languageMenu("源语言", selection: $source, excluding: target)
                    swapButton
                    languageMenu("目标语言", selection: $target, excluding: source)
                }
                VStack(spacing: 10) {
                    languageMenu("源语言", selection: $source, excluding: target)
                    languageMenu("目标语言", selection: $target, excluding: source)
                    swapButton
                }
            }
            .disabled(busy)
            Text(L10n: "同传支持所列语言。首次使用语言对可能需要 Wi-Fi 下载模型。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let message = controller.errorMessage {
                HStack(alignment: .top) {
                    Label { Text(verbatim: message) } icon: { Image(systemName: "exclamationmark.circle") }
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Spacer()
                    Button {
                        controller.dismissError()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n: "关闭"))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func languageMenu(_ label: String, selection: Binding<String>, excluding: String) -> some View {
        Menu {
            Picker(selection: selection) {
                ForEach(Self.choices.filter { $0 != excluding }, id: \.self) { code in
                    Text(verbatim: languageName(code)).tag(code)
                }
            } label: {
                Text(L10n: label)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n: label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(verbatim: languageName(selection.wrappedValue))
                        .font(.headline)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(Text(L10n: label))
        .accessibilityValue(Text(verbatim: languageName(selection.wrappedValue)))
    }

    private var swapButton: some View {
        Button {
            let previous = source
            source = target
            target = previous
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(L10n: "交换语言"))
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(L10n: "逐段显示原文和译文")
                    .font(.title2.bold())
                Text(L10n: "点开始后持续收音。说完一句停顿一下，译文就会出现在这里。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text(L10n: "退出同传页或切到后台会停止。仅在本机保存文字，不保存录音。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
            .padding(28)
        }
    }

    private var recentHistory: [InterpretationSegment] {
        let liveIDs = Set(controller.segments.map(\.id))
        return Array(controller.history.lazy.filter { !liveIDs.contains($0.id) }.prefix(12).reversed())
    }

    private var liveFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !recentHistory.isEmpty {
                        Text(L10n: "最近同传记录")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(recentHistory) { row in
                            segmentCard(row, pending: false)
                        }
                    }
                    if !controller.segments.isEmpty {
                        Text(L10n: "本次同传")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(controller.segments) { row in
                        segmentCard(row, pending: !row.failed && row.translation == nil)
                            .id(row.id)
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: controller.segments.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var microphoneControls: some View {
        VStack(alignment: .center, spacing: 8) {
            if !hasWhisperModel && !busy {
                Text(L10n: "需要先下载 Whisper 语音识别模型。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    NotificationCenter.default.post(name: NSNotification.Name("SwitchToSettingsTab"), object: nil)
                } label: {
                    Label(L10n: "去设置 → 模型管理", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    if busy {
                        controller.finish()
                    } else {
                        ttsManager.stopSpeaking()
                        controller.start(recognizer: speechRecognizer, translator: translator, source: source, target: target)
                    }
                } label: {
                    Label(L10n: busy ? "停止同传" : "开始同传", systemImage: busy ? "stop.fill" : "mic.fill")
                        .frame(maxWidth: 360, minHeight: 26)
                }
                .buttonStyle(.borderedProminent)
                .tint(busy ? .red : .accentColor)
                .disabled(controller.phase == .finishing || (!busy && (!isTabSelected || scenePhase != .active)))
                if busy {
                    HStack(spacing: 8) {
                        if controller.phase != .listening || controller.translationInProgress {
                            ProgressView().controlSize(.small)
                        } else {
                            Circle().fill(.red).frame(width: 8, height: 8).accessibilityHidden(true)
                        }
                        Text(L10n: phaseText)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if controller.droppedSegments > 0 {
                        Text(L10n: "设备处理跟不上，部分语音未翻译。请稍作停顿。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var phaseText: String {
        switch controller.phase {
        case .preparing: return "正在准备翻译模型…"
        case .starting: return "正在准备麦克风…"
        case .listening: return controller.translationInProgress ? "持续收音 · 正在翻译" : "持续收音中"
        case .finishing: return "正在完成最后一段…"
        case .idle: return ""
        }
    }

    private var historySheet: some View {
        NavigationStack {
            Group {
                if controller.history.isEmpty {
                    ContentUnavailableView {
                        Label(L10n: "暂无同传记录", systemImage: "text.bubble")
                    } description: {
                        Text(L10n: "最近 100 段文字保存在本机。")
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(controller.history) { row in
                                segmentCard(row, pending: false)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(Text(L10n: "同传历史"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHistory = false } label: { Text(L10n: "完成") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { showClearConfirmation = true } label: { Text(L10n: "清空历史") }
                        .disabled(controller.history.isEmpty || busy)
                }
            }
            .confirmationDialog(strings.get("清空所有本机同传记录？"), isPresented: $showClearConfirmation, titleVisibility: .visible) {
                Button(role: .destructive) { controller.clearHistory() } label: { Text(L10n: "清空历史") }
                Button(role: .cancel) {} label: { Text(L10n: "取消") }
            }
        }
    }

    private func segmentCard(_ segment: InterpretationSegment, pending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(verbatim: "\(languageName(segment.source)) → \(languageName(segment.target))")
                Spacer()
                Text(segment.date, style: .time)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(L10n: "原文").font(.caption).foregroundStyle(.secondary)
            Text(verbatim: segment.original).textSelection(.enabled)
            Divider()
            Text(L10n: "译文").font(.caption).foregroundStyle(.secondary)
            if let translation = segment.translation {
                Text(verbatim: translation).font(.body.weight(.semibold)).textSelection(.enabled)
            } else if pending {
                Label(L10n: "正在翻译…", systemImage: "ellipsis")
                    .foregroundStyle(.secondary)
            } else {
                Label(L10n: "这段未翻译", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func languageName(_ code: String) -> String {
        strings.locale.localizedString(forLanguageCode: code) ?? code
    }
}
