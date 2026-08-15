import Foundation
import XCTest
@testable import MLXModelProfileGeneration
import ModelManagement

final class MLXModelPreflightTests: XCTestCase {
    private static let allBundleEnvironment: [(String, String)] = [
        ("KEYTYPE_MLX_08B_MODEL_DIR", "Qwen3.5-0.8B-MLX-6bit"),
        ("KEYTYPE_MLX_2B_MODEL_DIR", "Qwen3.5-2B-MLX-4bit"),
        ("KEYTYPE_MLX_4B_MODEL_DIR", "Qwen3.5-4B-MLX-4bit"),
    ]

    func testPinnedBundlePassesLivePreflight() async throws {
        guard let path = ProcessInfo.processInfo.environment["KEYTYPE_MLX_MODEL_DIR"], !path.isEmpty else {
            throw XCTSkip("KEYTYPE_MLX_MODEL_DIR is not set")
        }
        let modelID = ProcessInfo.processInfo.environment["KEYTYPE_MLX_MODEL_ID"]
            ?? MLXModelCatalog.recommended()?.id
            ?? ""
        guard let model = MLXModelCatalog.model(id: modelID) else {
            return XCTFail("missing MLX catalog entry \(modelID)")
        }

        let prepared = try await MLXModelPreflight.prepare(
            model,
            directory: URL(fileURLWithPath: path, isDirectory: true)
        )
        XCTAssertEqual(prepared.family, "qwen3-v151936")
        await MLXModelPreflight.shutdown(prepared)
    }

    func testAllPinnedBundlesPassLivePreflight() async throws {
        let environment = ProcessInfo.processInfo.environment
        let missing = Self.allBundleEnvironment.map(\.0).filter { environment[$0]?.isEmpty ?? true }
        guard missing.isEmpty else {
            throw XCTSkip("set \(missing.joined(separator: ", ")) to validate every pinned MLX bundle")
        }

        for (variable, modelID) in Self.allBundleEnvironment {
            let model = try XCTUnwrap(MLXModelCatalog.model(id: modelID))
            let prepared = try await MLXModelPreflight.prepare(
                model,
                directory: URL(fileURLWithPath: try XCTUnwrap(environment[variable]), isDirectory: true)
            )
            XCTAssertEqual(prepared.family, "qwen3-v151936")
            await MLXModelPreflight.shutdown(prepared)
        }
    }
}
