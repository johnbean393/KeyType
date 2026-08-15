import Foundation
import ModelRuntime
import XCTest
@testable import ModelManagement

final class MLXModelCatalogTests: XCTestCase {
    func testCatalogContainsTheThreeCuratedQwenConversions() {
        XCTAssertEqual(MLXModelCatalog.models.map(\.onboardingLabel), ["Fastest", "Recommended", "Higher capacity"])
        XCTAssertEqual(Set(MLXModelCatalog.models.map(\.id)).count, 3)
        XCTAssertTrue(MLXModelCatalog.models.allSatisfy { $0.sourceModelRepository.hasPrefix("Qwen/Qwen3.5-") })
        XCTAssertTrue(MLXModelCatalog.models.allSatisfy { !$0.id.contains("Base") })
        XCTAssertTrue(MLXModelCatalog.models.allSatisfy { $0.immutableRevision.count == 40 })
        XCTAssertTrue(MLXModelCatalog.models.allSatisfy { $0.expectedTokenizerDigest == "a5ef0db942b70a225a6ca8f8b4e5fe80" })
    }

    func testCatalogPinsEveryLoaderRequiredFile() {
        let expected = Set(["config.json", "model.safetensors", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "vocab.json"])
        for model in MLXModelCatalog.models {
            XCTAssertEqual(Set(model.requiredFiles.map(\.relativePath)), expected)
            XCTAssertTrue(model.requiredFiles.allSatisfy { $0.expectedSizeBytes > 0 && $0.sha256.count == 64 })
        }
    }

    func testRecommendedModelIsAvailableOnTwentyFourGiBMacs() throws {
        let model = try XCTUnwrap(MLXModelCatalog.recommended(
            forPhysicalMemoryBytes: 24 * 1_073_741_824,
            architecture: .arm64
        ))
        XCTAssertEqual(model.onboardingLabel, "Recommended")
        XCTAssertEqual(model.quantization, "4-bit")
    }

    func testHardwareFilteredCatalogDoesNotOfferUnsupportedBundles() {
        let models = MLXModelCatalog.models(
            forPhysicalMemoryBytes: 8 * 1_073_741_824,
            architecture: .arm64
        )

        XCTAssertEqual(models.map(\.onboardingLabel), ["Fastest"])
        XCTAssertEqual(
            MLXModelCatalog.recommended(
                forPhysicalMemoryBytes: 8 * 1_073_741_824,
                architecture: .arm64
            )?.onboardingLabel,
            "Fastest"
        )
        XCTAssertNil(MLXModelCatalog.recommended(
            forPhysicalMemoryBytes: 4 * 1_073_741_824,
            architecture: .arm64
        ))
    }

    func testHardwareFilteredCatalogDoesNotOfferMLXOnIntel() {
        XCTAssertTrue(MLXModelCatalog.models(
            forPhysicalMemoryBytes: 64 * 1_073_741_824,
            architecture: .x86_64
        ).isEmpty)
        XCTAssertNil(MLXModelCatalog.recommended(
            forPhysicalMemoryBytes: 64 * 1_073_741_824,
            architecture: .x86_64
        ))
    }
}
