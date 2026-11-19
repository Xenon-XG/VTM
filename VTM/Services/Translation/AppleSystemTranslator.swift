import Foundation

#if canImport(Translation) && os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
import Translation
#endif

/// The Apple translation engine uses only language models already installed by iOS.
/// It never creates a SwiftUI-owned session that could show a download prompt.
@MainActor
enum AppleSystemTranslator {
    static var isAvailable: Bool {
        #if canImport(Translation) && os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    static func availability(source: String, target: String) async -> AppleTranslationAvailability {
        #if canImport(Translation) && os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        guard #available(iOS 26.0, *) else { return .unavailable }
        guard let pair = AppleTranslationPolicy.pair(source, target) else { return .unsupported }
        let original = Locale.Language(identifier: pair.source)
        let translated = Locale.Language(identifier: pair.target)
        let inventory: LanguageAvailability
        if #available(iOS 26.4, *) {
            inventory = LanguageAvailability(preferredStrategy: .lowLatency)
        } else {
            inventory = LanguageAvailability()
        }
        switch await inventory.status(from: original, to: translated) {
        case .installed: return .installed
        case .supported: return .missing
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
        #else
        return .unavailable
        #endif
    }

    static func bidirectionalAvailability(_ languageA: String, _ languageB: String) async -> AppleTranslationAvailability {
        let forward = await availability(source: languageA, target: languageB)
        if forward == .unsupported || forward == .unavailable || Task.isCancelled {
            return forward
        }
        let reverse = await availability(source: languageB, target: languageA)
        return .bidirectional(forward, reverse)
    }

    static func preparePair(source: String, target: String) async throws -> ContinuousTranslation {
        try Task.checkCancellation()
        switch await availability(source: source, target: target) {
        case .unavailable: throw failure("Apple 系统翻译需要 iOS 26 或更新版本的实体设备。")
        case .unsupported: throw failure("Apple 系统翻译不支持所选语言组合。")
        case .missing: throw failure("请先在系统设置的翻译应用中下载所选语言。")
        case .installed: break
        }
        try Task.checkCancellation()
        #if canImport(Translation) && os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *), let pair = AppleTranslationPolicy.pair(source, target) {
            let installed = AppleInstalledPair(
                source: Locale.Language(identifier: pair.source),
                target: Locale.Language(identifier: pair.target)
            )
            return { text in try await installed.translate(text) }
        }
        #endif
        throw failure("Apple 系统翻译需要 iOS 26 或更新版本的实体设备。")
    }

    fileprivate static func failure(_ key: String) -> AppleTranslationFailure {
        AppleTranslationFailure(message: AppStrings.shared.get(key))
    }

    fileprivate static func nativeFailure(_ detail: String) -> AppleTranslationFailure {
        AppleTranslationFailure(message: String(format: AppStrings.shared.get("Apple 系统翻译失败：%@"), detail))
    }
}

nonisolated struct AppleTranslationFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

#if canImport(Translation) && os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
@available(iOS 26.0, *)
@MainActor
private final class AppleInstalledPair {
    private let session: TranslationSession

    init(source: Locale.Language, target: Locale.Language) {
        if #available(iOS 26.4, *) {
            session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(installedSource: source, target: target)
        }
    }

    func translate(_ text: String) async throws -> String {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return "" }
        try Task.checkCancellation()
        // Defense in depth: this must stay a prompt-free installed-only session.
        guard !session.canRequestDownloads else {
            throw AppleSystemTranslator.failure("请先在系统设置的翻译应用中下载所选语言。")
        }
        do {
            let response = try await withTaskCancellationHandler {
                try await session.translate(input)
            } onCancel: { [self] in
                Task { @MainActor in self.session.cancel() }
            }
            try Task.checkCancellation()
            return response.targetText
        } catch TranslationError.notInstalled {
            throw AppleSystemTranslator.failure("请先在系统设置的翻译应用中下载所选语言。")
        } catch TranslationError.unsupportedLanguagePairing {
            throw AppleSystemTranslator.failure("Apple 系统翻译不支持所选语言组合。")
        } catch TranslationError.unsupportedSourceLanguage {
            throw AppleSystemTranslator.failure("Apple 系统翻译不支持所选语言组合。")
        } catch TranslationError.unsupportedTargetLanguage {
            throw AppleSystemTranslator.failure("Apple 系统翻译不支持所选语言组合。")
        } catch TranslationError.alreadyCancelled {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw AppleSystemTranslator.nativeFailure(error.localizedDescription)
        }
    }
}
#endif
