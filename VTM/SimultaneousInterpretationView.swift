import SwiftUI

struct SimultaneousInterpretationView: View {
    let isTabSelected: Bool

    @ObservedObject private var strings = AppStrings.shared
    @ObservedObject private var offlinePacks = OfflineLanguagePacks.shared
    @EnvironmentObject private var speechRecognizer: SpeechRecognizer
    @EnvironmentObject private var translator: Translator
    @EnvironmentObject private var ttsManager: TTSManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var controller = SimultaneousInterpretationController()
    // Keep existing stored language choices; these are now the unordered A/B pair.
    @AppStorage("continuousInterpretationSource") private var languageA = "zh"
    @AppStorage("continuousInterpretationTarget") private var languageB = "en"
    @AppStorage("continuousInterpretationWhisperModel") private var modelFilename = "ggml-small.bin"
    @State private var showHistory = false
    @State private var showTranslationPacks = false
    @State private var showClearConfirmation = false
    @State private var selectionSheet: ChoiceSheet?

    private enum ChoiceSheet: String, Identifiable {
        case languageA, languageB, recognitionModel
        var id: String { rawValue }

        var title: String {
            switch self {
            case .languageA: return "选择语言 A"
            case .languageB: return "选择语言 B"
            case .recognitionModel: return "选择语音识别模型"
            }
        }
    }

    // Common languages shared by Whisper and this app's ML Kit router.
    private static let choices = ["zh", "en", "ja", "ko", "fr", "es", "de", "it", "pt",
                                  "ru", "ar", "hi", "vi", "th", "id", "nl", "tr", "uk"]
        .filter { TranslationRouter.isMLKitSupported(sourceLang: $0, targetLang: "en") }

    private var busy: Bool { controller.phase != .idle }
    private var selectedModel: WhisperModel {
        // Fall back only for an unknown stored identifier, never for a known missing download.
        WhisperModel.availableModels.first { $0.filename == modelFilename }
            ?? WhisperModel.standard
    }

    private var hasWhisperModel: Bool { selectedModel.fileExists() }
    private var missingPackNames: String {
        offlinePacks.missingLanguages(for: languageA, and: languageB)
            .map { languageName($0) }.joined(separator: " / ")
    }

    var body: some View {
        NavigationStack {
            Group {
                if controller.segments.isEmpty && controller.history.isEmpty {
                    emptyState
                } else {
                    liveFeed
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !dynamicTypeSize.isAccessibilitySize { controls }
            }
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
        .sheet(item: $selectionSheet) { sheet in choices(for: sheet) }
        .sheet(isPresented: $showTranslationPacks, onDismiss: { offlinePacks.refresh() }) {
            NavigationStack {
                OfflineLanguagePacksView(focusCodes: [languageA, languageB])
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { showTranslationPacks = false } label: { Text(L10n: "完成") }
                        }
                    }
            }
        }
        .onAppear { offlinePacks.refresh() }
        .onChange(of: isTabSelected) { _, selected in
            if selected {
                offlinePacks.refresh()
            } else {
                showTranslationPacks = false
                controller.stop()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && isTabSelected { offlinePacks.refresh() }
            if phase == .background || (phase == .inactive && [.listening, .finishing].contains(controller.phase)) {
                controller.stop()
            }
        }
        .onDisappear { controller.stop() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 7) {
                        languageChoice(.languageA, code: languageA)
                        directionIcon
                        languageChoice(.languageB, code: languageB)
                    }
                } else {
                    HStack(alignment: .center, spacing: 8) {
                        languageChoice(.languageA, code: languageA)
                        directionIcon
                        languageChoice(.languageB, code: languageB)
                    }
                }
                modelChoice
            }
            .disabled(busy)
            Text(L10n: "自动判断每段语音的语言，两种语言都能说。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !busy && (missingPackNames.isEmpty || !hasWhisperModel) {
                Button {
                    showTranslationPacks = true
                } label: {
                    Label(L10n: "离线翻译语言包", systemImage: "arrow.down.circle")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }
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

    private var directionIcon: some View {
        Image(systemName: "arrow.left.arrow.right")
            .font(.system(.callout, design: .rounded, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(7)
            .background(Color.accentColor.opacity(0.13), in: Circle())
            .accessibilityHidden(true)
    }

    private func languageChoice(_ sheet: ChoiceSheet, code: String) -> some View {
        let title = sheet == .languageA ? "语言 A" : "语言 B"
        return Button {
            selectionSheet = sheet
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n: title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(verbatim: languageName(code))
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11).strokeBorder(.quaternary, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n: title))
        .accessibilityValue(Text(verbatim: languageName(code)))
    }

    private var modelChoice: some View {
        Button {
            selectionSheet = .recognitionModel
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n: "语音识别模型")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: selectedModel.displayName)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !hasWhisperModel {
                        Text(L10n: "未下载").font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 9)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11).strokeBorder(.quaternary, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n: "语音识别模型"))
        .accessibilityValue(Text(verbatim: selectedModel.displayName))
    }

    private func choices(for sheet: ChoiceSheet) -> some View {
        NavigationStack {
            List {
                if sheet == .recognitionModel {
                    ForEach(WhisperModel.availableModels, id: \.filename) { model in
                        choiceRow(title: model.displayName,
                                  detail: "\(model.downloadSizeLabel) · \(strings.get(model.fileExists() ? "已下载" : "未下载"))",
                                  isSelected: model.filename == selectedModel.filename) {
                            modelFilename = model.filename
                        }
                    }
                } else {
                    let current = sheet == .languageA ? languageA : languageB
                    let other = sheet == .languageA ? languageB : languageA
                    let sorted = Self.choices.filter { $0 != other }.sorted {
                        languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending
                    }
                    ForEach(sorted, id: \.self) { code in
                        choiceRow(title: languageName(code), detail: nil, isSelected: code == current) {
                            if sheet == .languageA { languageA = code } else { languageB = code }
                        }
                    }
                }
            }
            .navigationTitle(Text(L10n: sheet.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { selectionSheet = nil } label: { Text(L10n: "完成") }
                }
            }
        }
    }

    private func choiceRow(title: String, detail: String?, isSelected: Bool, select: @escaping () -> Void) -> some View {
        Button {
            select()
            selectionSheet = nil
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title).foregroundStyle(.primary)
                    if let detail {
                        Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var emptyState: some View {
        ScrollView {
            if dynamicTypeSize.isAccessibilitySize { controls }
            VStack(alignment: .center, spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(L10n: "逐段显示原文和译文")
                    .font(.title2.bold())
                Text(L10n: "两种语言都可以说。说完一句停顿一下，应用会自动翻成另一种语言。")
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
                    if dynamicTypeSize.isAccessibilitySize { controls }
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
                Text(L10n: "选中的识别模型尚未下载，请先在模型管理中下载。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    NotificationCenter.default.post(name: NSNotification.Name("SwitchToSettingsTab"), object: nil)
                } label: {
                    Label(L10n: "去设置 → 模型管理", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
            } else if !busy && !missingPackNames.isEmpty {
                Text(verbatim: String(format: strings.get("请先在模型管理下载翻译语言包：%@"), missingPackNames))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    showTranslationPacks = true
                } label: {
                    Label(L10n: "管理离线翻译语言包", systemImage: "arrow.down.circle")
                        .frame(maxWidth: 360, minHeight: 26)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isTabSelected || scenePhase != .active)
            } else {
                Button {
                    if busy {
                        controller.finish()
                    } else {
                        ttsManager.stopSpeaking()
                        controller.start(recognizer: speechRecognizer, translator: translator, model: selectedModel,
                                         languageA: languageA, languageB: languageB)
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
                    if controller.hasUnroutablePhrase {
                        Text(L10n: "这一段识别失败，已跳过。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
