//
//  WhisperModel.swift
//  VTM
//
//  Downloadable multilingual ggml Whisper models.
//

import Foundation
import CryptoKit

struct WhisperModel: Identifiable {
    var id: String { filename }
    let name: String
    let displayName: String
    let downloadSizeLabel: String
    let filename: String
    let expectedBytes: Int64
    let sha256: String

    var url: String {
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)"
    }

    var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }

    func fileExists() -> Bool {
        fileSize == expectedBytes
    }

    var fileSize: Int64? {
        (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    var formattedSize: String {
        guard let size = fileSize else { return "未下载" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    // The original file/path remains valid on upgrade.
    static let standard = WhisperModel(
        name: "small", displayName: "Whisper Small", downloadSizeLabel: "466 MiB",
        filename: "ggml-small.bin", expectedBytes: 487_601_967,
        sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
    )
    static let compact = WhisperModel(
        name: "small-q5_1", displayName: "Whisper Small Q5", downloadSizeLabel: "181 MiB",
        filename: "ggml-small-q5_1.bin", expectedBytes: 190_085_487,
        sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
    )
    static let turbo = WhisperModel(
        name: "large-v3-turbo-q5_0", displayName: "Whisper Large v3 Turbo Q5", downloadSizeLabel: "547 MiB",
        filename: "ggml-large-v3-turbo-q5_0.bin", expectedBytes: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
    )

    // Stable order keeps ordinary translation on the original Small when installed.
    static let availableModels = [standard, compact, turbo]

    static func downloadedModels() -> [WhisperModel] {
        availableModels.filter { $0.fileExists() }
    }

    static func recommendedModel() -> WhisperModel? {
        downloadedModels().first
    }
}

/// Verify downloaded bytes before installation without reading an entire model into RAM.
nonisolated func verifyWhisperDownload(_ url: URL, expectedBytes: Int64, sha256: String) throws -> Bool {
    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
          Int64(size) == expectedBytes else { return false }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
        digest.update(data: data)
    }
    return digest.finalize().map { String(format: "%02x", Int($0)) }.joined() == sha256
}
