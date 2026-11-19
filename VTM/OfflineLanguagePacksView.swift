import SwiftUI

/// ML Kit translation language packs. This screen does not manage the Whisper speech model.
struct OfflineLanguagePacksView: View {
    var focusCodes: [String] = []

    @ObservedObject private var packs = OfflineLanguagePacks.shared
    @ObservedObject private var strings = AppStrings.shared
    @State private var query = ""

    private let commonCodes = ["zh", "en", "ja", "ko", "fr", "es", "de", "it",
                               "pt", "ru", "ar", "hi", "vi", "th", "id"]
    private var supportedCodes: [String] { OfflineLanguagePacks.supportedCodes }
    private var focused: [String] {
        focusCodes.reduce(into: []) { result, code in
            if supportedCodes.contains(code), !result.contains(code) { result.append(code) }
        }
    }
    private var common: [String] {
        commonCodes.filter { supportedCodes.contains($0) && !focused.contains($0) }
    }
    private var remaining: [String] {
        sorted(supportedCodes.filter { !focused.contains($0) && !common.contains($0) })
    }
    private var enteredQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var results: [String] {
        sorted(supportedCodes.filter {
            languageName($0).localizedCaseInsensitiveContains(enteredQuery)
                || selfName($0).localizedCaseInsensitiveContains(enteredQuery)
                || $0.localizedCaseInsensitiveContains(enteredQuery)
        })
    }

    var body: some View {
        List {
            Section {
                Label(L10n: "先下载所选语言包，再离线使用同传。英语已内置。", systemImage: "arrow.left.arrow.right")
                Label(L10n: "语言包用于翻译；语音识别仍需要单独下载 Whisper。", systemImage: "waveform")
                Label(L10n: "请连接 Wi-Fi，并保持 VTM 在前台，直到下载完成。", systemImage: "wifi")
            }
            .font(.footnote)
            if supportedCodes.isEmpty {
                Text(L10n: "当前版本不支持下载翻译语言包。")
                    .foregroundStyle(.secondary)
            } else if !enteredQuery.isEmpty {
                if results.isEmpty {
                    Text(L10n: "找不到匹配的语言。").foregroundStyle(.secondary)
                } else {
                    ForEach(results, id: \.self) { packRow($0) }
                }
            } else {
                if !focused.isEmpty {
                    Section {
                        ForEach(focused, id: \.self) { packRow($0) }
                    } header: { Text(L10n: "同传所选语言") }
                }
                if !common.isEmpty {
                    Section {
                        ForEach(common, id: \.self) { packRow($0) }
                    } header: { Text(L10n: "常用语言") }
                }
                if !remaining.isEmpty {
                    Section {
                        ForEach(remaining, id: \.self) { packRow($0) }
                    } header: { Text(L10n: "其他语言") }
                }
            }
        }
        .navigationTitle(Text(L10n: "离线翻译语言包"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: Text(L10n: "搜索语言"))
        .onAppear { packs.refresh() }
    }

    private func packRow(_ code: String) -> some View {
        let name = languageName(code)
        let state = packs.state(for: code)
        let fraction = packs.progress[code].flatMap { $0 > 0 && $0 < 1 ? $0 : nil }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: name)
                    .font(.body.weight(.medium))
                switch state {
                case .installed:
                    Text(L10n: code == "en" ? "内置" : "已下载").font(.caption).foregroundStyle(.secondary)
                case .missing:
                    Text(L10n: "未下载").font(.caption).foregroundStyle(.secondary)
                case .downloading:
                    if let fraction {
                        Text(verbatim: strings.get("下载中") + " · " + fraction.formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n: "下载中").font(.caption).foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Text(verbatim: message.isEmpty ? strings.get("下载失败") : message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            switch state {
            case .installed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            case .downloading:
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(width: 44)
                        .accessibilityHidden(true)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            case .missing, .failed:
                Button {
                    packs.download(code)
                } label: {
                    Image(systemName: isFailure(state) ? "arrow.clockwise.circle" : "arrow.down.circle")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(L10n: isFailure(state) ? "重试" : "下载"))
                .accessibilityValue(Text(verbatim: name))
            }
        }
        .padding(.vertical, 2)
    }

    private func isFailure(_ state: OfflineLanguagePacks.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func languageName(_ code: String) -> String {
        strings.locale.localizedString(forLanguageCode: code) ?? selfName(code)
    }

    private func selfName(_ code: String) -> String {
        Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
    }

    private func sorted(_ codes: [String]) -> [String] {
        codes.sorted {
            languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending
        }
    }
}
