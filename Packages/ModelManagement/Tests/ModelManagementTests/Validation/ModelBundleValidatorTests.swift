import Foundation
import XCTest
@testable import ModelManagement

final class ModelBundleValidatorTests: XCTestCase {
    func testValidatesTheExactRequiredFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keytype-model-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data("KeyType".utf8)
        let path = directory.appendingPathComponent("config.json")
        try payload.write(to: path)
        let manifest = makeManifest(file: .init(
            relativePath: "config.json",
            expectedSizeBytes: Int64(payload.count),
            sha256: "4a6d314ff52f2bc0704a18906f240511027fff61e54f2915eab5c847ec1e8ff4"
        ))

        XCTAssertNoThrow(try ModelBundleValidator.validate(directory: directory, manifest: manifest))
    }

    func testRejectsMissingRequiredFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keytype-model-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try ModelBundleValidator.validate(directory: directory, manifest: makeManifest(file: .init(
            relativePath: "missing.json", expectedSizeBytes: 1, sha256: String(repeating: "0", count: 64)
        )))) { error in
            XCTAssertEqual(error as? ModelBundleValidator.ValidationError, .missingFile("missing.json"))
        }
    }

    private func makeManifest(file: VerifiedModelBundleFile) -> SupportedMLXModel {
        SupportedMLXModel(
            id: "fixture", displayName: "Fixture", onboardingLabel: "Fixture", detail: "Fixture",
            approximateDownloadSizeLabel: "0 GB", minimumPhysicalMemoryBytes: 0,
            sourceRepository: "example/fixture", immutableRevision: String(repeating: "a", count: 40),
            sourceModelRepository: "example/source",
            requiredFiles: [file], expectedTokenizerDigest: String(repeating: "0", count: 32),
            tokenizerFamily: "fixture", quantization: "fixture",
            tuningPreset: .init(maxPromptTokens: 1, topK: 1, topP: 1, temperature: 1, branchWidth: 1, relativeCutoff: 1, minimumBranchProbability: 1, enableFillInMiddle: false, fimMaxPrefixTokens: 0, fimMaxSuffixTokens: 0),
            validationVersion: 1
        )
    }
}
