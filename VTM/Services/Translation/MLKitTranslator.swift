//
//  MLKitTranslator.swift
//  VTM
//
//  Google ML Kit 翻译引擎 — 主力翻译方案
//  使用 ML Kit Translate SDK，离线翻译，优先用于 zh↔en 等主流语言
//

import Foundation
import Combine
import MLKitTranslate

typealias ContinuousTranslation = @MainActor (String) async throws -> String

/// Google ML Kit 翻译引擎
/// 利用 ML Kit 的离线模型（~30MB/语言对），质量远优于 NLLB distilled
final class MLKitTranslator: NSObject, TranslationEngine {

    // MARK: - TranslationEngine

    var engineName: String { "Google ML Kit" }

    var isReady: Bool {
        // Framework availability is distinct from local model readiness.
        #if canImport(MLKitTranslate)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Public API

    /// 翻译文本（回调版本）
    func translate(
        text: String,
        sourceLang: String,
        targetLang: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        #if canImport(MLKitTranslate)
        performMLKitTranslation(
            text: text,
            sourceLang: sourceLang,
            targetLang: targetLang,
            completion: completion
        )
        #else
        completion(.failure(MLKitError.sdkNotAvailable))
        #endif
    }

    /// 翻译文本（async/await 版本）
    func translateAsync(
        text: String,
        sourceLang: String,
        targetLang: String
    ) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            translate(text: text, sourceLang: sourceLang, targetLang: targetLang) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Use already installed device packs. Starting live interpretation never downloads them.
    @MainActor
    func prepareContinuousPair(source: String, target: String) async throws -> ContinuousTranslation {
        #if canImport(MLKitTranslate)
        guard let original = translateLanguage(from: source),
              let translated = translateLanguage(from: target) else {
            throw MLKitError.unsupportedLanguage(source, target)
        }
        try requireDownloadedPacks(source: source, target: target)
        let options = TranslatorOptions(sourceLanguage: original, targetLanguage: translated)
        let translator = MLKitTranslate.Translator.translator(options: options)
        // Retain one prepared native translator for the entire live session.
        return { rawText in
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            let input = OfflinePackPolicy.canonicalCode(source) == "zh" && OfflinePackPolicy.canonicalCode(target) == "en"
                ? NamedEntityReplacer.preReplaceForChineseToEnglish(trimmed) : trimmed
            return try await withCheckedThrowingContinuation { continuation in
                translator.translate(input) { [translator] translated, error in
                    withExtendedLifetime(translator) {
                        if let error {
                            continuation.resume(throwing: MLKitError.translationFailed(error.localizedDescription))
                        } else if let translated {
                            continuation.resume(returning: Self.removeTrailingDuplication(translated))
                        } else {
                            continuation.resume(throwing: MLKitError.emptyResult)
                        }
                    }
                }
            }
        }
        #else
        throw MLKitError.sdkNotAvailable
        #endif
    }

    // MARK: - Private: ML Kit 实际调用

    #if canImport(MLKitTranslate)
    private func performMLKitTranslation(
        text: String,
        sourceLang: String,
        targetLang: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.success(""))
            return
        }

        // 获取或创建 Translator 实例
        guard let sourceLanguage = translateLanguage(from: sourceLang),
              let targetLanguage = translateLanguage(from: targetLang) else {
            completion(.failure(MLKitError.unsupportedLanguage(sourceLang, targetLang)))
            return
        }

        do {
            try requireDownloadedPacks(source: sourceLang, target: targetLang)
        } catch {
            completion(.failure(error))
            return
        }

        let options = TranslatorOptions(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
        let translator = MLKitTranslate.Translator.translator(options: options)
        let input = OfflinePackPolicy.canonicalCode(sourceLang) == "zh" && OfflinePackPolicy.canonicalCode(targetLang) == "en"
            ? NamedEntityReplacer.preReplaceForChineseToEnglish(trimmed) : trimmed
        // The pinned SDK's translate API returns an error on missing files;
        // it does not automatically start a model download.
        translator.translate(input) { [translator] translatedText, error in
            withExtendedLifetime(translator) {
                if let error {
                    VTMLog.error("ML Kit 翻译失败: \(error.localizedDescription)", category: "Translation")
                    completion(.failure(MLKitError.translationFailed(error.localizedDescription)))
                } else if let translatedText {
                    completion(.success(Self.removeTrailingDuplication(translatedText)))
                } else {
                    completion(.failure(MLKitError.emptyResult))
                }
            }
        }
    }

    private func translateLanguage(from bcp47: String) -> TranslateLanguage? {
        OfflineLanguagePacks.sdkLanguage(for: bcp47)
    }

    private func requireDownloadedPacks(source: String, target: String) throws {
        let missing = OfflineLanguagePacks.shared.missingLanguages(for: source, and: target)
        guard missing.isEmpty else { throw MLKitError.missingLanguagePacks(missing) }
    }
    #endif

    // MARK: - 尾部重复检测

    /// 检测并移除 ML Kit 翻译结果末尾的重复短语
    ///
    /// ML Kit 在离线翻译长句时偶尔会在尾部重复最后几个词，
    /// 例如 "I want to eat rice, I want to eat rice" → "I want to eat rice"
    ///
    /// 策略：将文本按词分割，检查是否存在尾部半截重复（n~n/2 词的滑动窗口），
    /// 如果检测到则截断重复部分
    static func removeTrailingDuplication(_ text: String) -> String {
        // 按词和标点分割（英文以空格为界，中文按字符）
        let isCJK = text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3040...0x309F).contains(scalar.value) ||
            (0xAC00...0xD7AF).contains(scalar.value)
        }

        let tokens: [String]
        if isCJK {
            tokens = text.map { String($0) }
        } else {
            tokens = text.components(separatedBy: .whitespaces)
        }

        guard tokens.count >= 3 else { return text }

        // 尝试不同长度的重复检测（从一半到 2 个 token）
        let maxChunk = tokens.count / 2
        for chunkLen in stride(from: maxChunk, through: 2, by: -1) {
            let suffix = Array(tokens.suffix(chunkLen))
            let candidate = Array(tokens.dropLast(chunkLen).suffix(chunkLen))

            // 如果尾部 chunk 和前面的 chunk 完全相同，截断
            if suffix == candidate, !suffix.isEmpty {
                let deduped: String
                if isCJK {
                    deduped = String(tokens.dropLast(chunkLen).map { String($0) }.joined())
                } else {
                    deduped = tokens.dropLast(chunkLen).joined(separator: " ")
                }
                return deduped.trimmingCharacters(in: .whitespaces)
            }
        }

        return text
    }

}

// MARK: - ML Kit 错误类型

enum MLKitError: LocalizedError {
    case sdkNotAvailable
    case unsupportedLanguage(String, String)
    case missingLanguagePacks([String])
    case translationFailed(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .sdkNotAvailable:
            return "ML Kit SDK 不可用，请检查项目配置"
        case .unsupportedLanguage(let src, let tgt):
            return "ML Kit 不支持 \"\(src)\" → \"\(tgt)\" 的语言对"
        case .missingLanguagePacks(let codes):
            let strings = AppStrings.shared
            let names = codes.map { strings.locale.localizedString(forLanguageCode: $0) ?? $0 }
            return String(format: strings.get("请先在模型管理下载翻译语言包：%@"), names.joined(separator: " / "))
        case .translationFailed(let detail):
            return "ML Kit 翻译失败: \(detail)"
        case .emptyResult:
            return "ML Kit 翻译返回空结果"
        }
    }
}
