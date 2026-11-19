import Combine
import Foundation
import MLKitCommon
import MLKitTranslate
import UIKit

/// A shared view of ML Kit's own on-disk model store. Nothing here downloads until
/// the user chooses Download in model management.
@MainActor
final class OfflineLanguagePacks: ObservableObject {
    enum State: Equatable {
        case installed
        case missing
        case downloading
        case failed(String)
    }

    static let shared = OfflineLanguagePacks()
    private static let supportedLanguages = Dictionary(
        TranslateLanguage.allLanguages().map { (OfflinePackPolicy.canonicalCode($0.rawValue), $0) },
        uniquingKeysWith: { first, _ in first }
    )

    static let supportedCodes: [String] = Array(
        Set(supportedLanguages.keys).union([OfflinePackPolicy.builtInCode])
    ).sorted()

    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var progress: [String: Double] = [:]

    private let manager = ModelManager.modelManager()
    private var requests: [String: UUID] = [:]
    private var downloads: [String: Progress] = [:]
    private var observations: [NSObjectProtocol] = []
    private var progressObservations: [String: NSKeyValueObservation] = [:]

    private init() {
        let center = NotificationCenter.default
        for event in [Notification.Name.mlkitModelDownloadDidSucceed, .mlkitModelDownloadDidFail] {
            let succeeded = event == .mlkitModelDownloadDidSucceed
            let observer = center.addObserver(forName: event, object: nil, queue: .main) { [weak self] note in
                guard let model = note.userInfo?[ModelDownloadUserInfoKey.remoteModel.rawValue] as? TranslateRemoteModel else {
                    return
                }
                let code = model.language.rawValue
                let error = (note.userInfo?[ModelDownloadUserInfoKey.error.rawValue] as? NSError)?.localizedDescription
                Task { @MainActor [weak self] in
                    self?.finish(code, succeeded: succeeded, error: error)
                }
            }
            observations.append(observer)
        }
        observations.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        })
        refresh()
    }

    static func sdkLanguage(for code: String) -> TranslateLanguage? {
        supportedLanguages[OfflinePackPolicy.canonicalCode(code)]
    }

    func state(for code: String) -> State {
        let code = OfflinePackPolicy.canonicalCode(code)
        return code == OfflinePackPolicy.builtInCode ? .installed : states[code, default: .missing]
    }

    func refresh() {
        let locallyInstalled = Set(manager.downloadedTranslateModels.map {
            OfflinePackPolicy.canonicalCode($0.language.rawValue)
        })
        var updated = states
        for code in Self.supportedCodes {
            if code == OfflinePackPolicy.builtInCode || locallyInstalled.contains(code) {
                updated[code] = .installed
            } else if requests[code] != nil {
                updated[code] = .downloading
            } else if case .failed? = updated[code] {
                // Leave the retry affordance visible while the pack is absent.
            } else {
                updated[code] = .missing
            }
        }
        if updated != states { states = updated }
    }

    func missingLanguages(for source: String, and target: String) -> [String] {
        OfflinePackPolicy.missingCodes(source: source, target: target) { isInstalled($0) }
    }

    func download(_ languageCode: String) {
        let code = OfflinePackPolicy.canonicalCode(languageCode)
        guard code != OfflinePackPolicy.builtInCode,
              let language = Self.supportedLanguages[code], requests[code] == nil else { return }
        let model = TranslateRemoteModel.translateRemoteModel(language: language)
        if manager.isModelDownloaded(model) {
            states[code] = .installed
            return
        }
        let id = UUID()
        requests[code] = id
        states[code] = .downloading
        progress[code] = 0
        // The app owns the progress, not the model-management navigation view.
        // No cellular or background model traffic.
        let download = manager.download(model, conditions: ModelDownloadConditions(
            allowsCellularAccess: false, allowsBackgroundDownloading: false
        ))
        downloads[code] = download
        progressObservations[code] = download.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] item, _ in
            let fraction = item.fractionCompleted
            Task { @MainActor [weak self] in
                guard let self, self.requests[code] == id else { return }
                self.progress[code] = fraction.isFinite ? min(1, max(0, fraction)) : 0
            }
        }
    }

    private func isInstalled(_ languageCode: String) -> Bool {
        let code = OfflinePackPolicy.canonicalCode(languageCode)
        if code == OfflinePackPolicy.builtInCode { return true }
        guard let language = Self.supportedLanguages[code] else { return false }
        return manager.isModelDownloaded(TranslateRemoteModel.translateRemoteModel(language: language))
    }

    private func finish(_ languageCode: String, succeeded: Bool, error: String?) {
        let code = OfflinePackPolicy.canonicalCode(languageCode)
        guard requests.removeValue(forKey: code) != nil else { return }
        progressObservations.removeValue(forKey: code)?.invalidate()
        downloads.removeValue(forKey: code)
        progress.removeValue(forKey: code)
        if isInstalled(code) {
            states[code] = .installed
        } else {
            states[code] = .failed(error ?? AppStrings.shared.get(
                succeeded ? "下载后未找到翻译语言包，请重试。" : "翻译语言包下载失败，请重试。"
            ))
        }
    }
}
