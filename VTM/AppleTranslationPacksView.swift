import SwiftUI

#if canImport(Translation)
import Translation
#endif

struct TranslationEnginePicker: View {
    @Binding var engine: VTMTranslationEngine

    var body: some View {
        Picker(selection: $engine) {
            Text(L10n: "Google ML Kit").tag(VTMTranslationEngine.mlKit)
            Text(L10n: "Apple 系统翻译")
                .tag(VTMTranslationEngine.apple)
                .disabled(!AppleSystemTranslator.isAvailable)
        } label: {
            Text(L10n: "翻译引擎")
        }
    }
}

/// Apple's downloads are managed by the system and cannot be substituted with ML Kit packs.
struct AppleTranslationPacksView: View {
    let source: String
    let target: String
    var bidirectional = false

    var body: some View {
        if #available(iOS 26.0, *), AppleSystemTranslator.isAvailable {
            #if canImport(Translation)
            AppleModelPreparationView(source: source, target: target, bidirectional: bidirectional)
            #else
            unavailable
            #endif
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label(L10n: "Apple 系统翻译", systemImage: "apple.logo")
        } description: {
            Text(L10n: "Apple 系统翻译需要 iOS 26 或更新版本的实体设备。")
        }
        .navigationTitle(Text(L10n: "Apple 系统翻译"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if canImport(Translation)
@available(iOS 26.0, *)
private struct AppleModelPreparationView: View {
    let source: String
    let target: String
    let bidirectional: Bool

    @ObservedObject private var strings = AppStrings.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var availability: AppleTranslationAvailability?
    @State private var configuration: TranslationSession.Configuration?
    @State private var preparing = false
    @State private var didRequestDownload = false
    @State private var requestError: String?
    @State private var refreshID = UUID()
    @State private var preparationTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                LabeledContent {
                    Text(verbatim: languageName(source) + (bidirectional ? " ↔ " : " → ") + languageName(target))
                        .multilineTextAlignment(.trailing)
                } label: { Text(L10n: "语言对") }
                if let availability {
                    statusRow(availability)
                } else {
                    ProgressView { Text(L10n: "正在检查苹果语言资源…") }
                }
            }
            Section {
                Text(L10n: "苹果语言资源由系统管理，和 ML Kit 语言包互不通用。")
                Text(L10n: "也可在 iOS 设置 → App → 翻译 → 已下载语言中管理苹果语言资源。")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .navigationTitle(Text(L10n: "Apple 系统翻译"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { Task { await refresh() } }
        }
        .onDisappear {
            refreshID = UUID()
            if let preparationTask {
                preparationTask.cancel()
                self.preparationTask = nil
                preparing = false
            }
        }
        .translationTask(configuration) { session in
            guard preparing else { return }
            defer {
                preparing = false
                configuration = nil
            }
            do {
                try await session.prepareTranslation()
                guard !Task.isCancelled else { return }
                didRequestDownload = true
                await refresh()
            } catch is CancellationError {
                // Leaving the screen cancels this UI-scoped request.
            } catch {
                guard !Task.isCancelled else { return }
                requestError = error.localizedDescription
                await refresh()
            }
        }
    }

    @ViewBuilder
    private func statusRow(_ availability: AppleTranslationAvailability) -> some View {
        switch availability {
        case .installed:
            Label(L10n: "苹果语言资源已就绪", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .missing:
            if preparing {
                ProgressView { Text(L10n: "正在请求系统下载…") }
            } else {
                Button {
                    requestPreparation()
                } label: {
                    Label(L10n: "准备苹果语言资源", systemImage: "arrow.down.circle")
                }
            }
            if let requestError {
                Text(verbatim: requestError).font(.footnote).foregroundStyle(.secondary)
            } else if didRequestDownload {
                Text(L10n: "系统尚未完成下载。请稍后刷新，或在系统设置中查看。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .unsupported:
            Text(L10n: "Apple 系统翻译不支持所选语言组合。")
                .foregroundStyle(.secondary)
        case .unavailable:
            Text(L10n: "当前环境无法使用Apple 系统翻译。")
                .foregroundStyle(.secondary)
        }
    }

    private func requestPreparation() {
        guard !preparing else { return }
        requestError = nil
        preparing = true
        preparationTask = Task {
            // Verify immediately before invoking a system UI. In simultaneous mode,
            // the unavailable direction is not always A → B.
            let missing = await refreshInventory()
            guard !Task.isCancelled else { return }
            preparationTask = nil
            guard let missing, let pair = AppleTranslationPolicy.pair(missing.source, missing.target) else {
                preparing = false
                return
            }
            let original = Locale.Language(identifier: pair.source)
            let translated = Locale.Language(identifier: pair.target)
            if #available(iOS 26.4, *) {
                configuration = .init(source: original, target: translated, preferredStrategy: .lowLatency)
            } else {
                configuration = .init(source: original, target: translated)
            }
        }
    }

    private func refresh() async {
        guard preparationTask == nil else { return }
        _ = await refreshInventory()
    }

    private func refreshInventory() async -> (source: String, target: String)? {
        let id = UUID()
        refreshID = id
        let forward = await AppleSystemTranslator.availability(source: source, target: target)
        guard !Task.isCancelled, refreshID == id else { return nil }
        if !bidirectional || forward == .unsupported || forward == .unavailable {
            availability = forward
            return forward == .missing ? (source, target) : nil
        }
        let reverse = await AppleSystemTranslator.availability(source: target, target: source)
        guard !Task.isCancelled, refreshID == id else { return nil }
        let combined = AppleTranslationAvailability.bidirectional(forward, reverse)
        availability = combined
        guard combined == .missing else { return nil }
        return forward == .missing ? (source, target) : (target, source)
    }

    private func languageName(_ code: String) -> String {
        let base = code.split(separator: "-").first.map(String.init) ?? code
        return strings.locale.localizedString(forLanguageCode: base) ?? code
    }
}
#endif
