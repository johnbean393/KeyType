import ModelRuntime
import XCTest
@testable import ModelManagement

final class ModelFamilyResolverTests: XCTestCase {

    func testCatalogModelUsesDeclaredFamily() {
        let family = ModelFamilyResolver.family(
            forFilename: ModelContainer.defaultModelFilename,
            vocabSize: 999 // ignored for catalog entries
        )
        XCTAssertEqual(family, "qwen3-v151936")
    }

    func testGemmaCatalogEntryUsesGemmaFamily() {
        let gemma = RuntimeModelCatalog.allModels.first { $0.displayName == "Gemma 4 E2B" }
        let family = ModelFamilyResolver.family(forFilename: gemma!.filename, vocabSize: 1)
        XCTAssertEqual(family, RuntimeModelCatalog.gemmaFamily)
    }

    func testLFM25CatalogEntryUsesLFM25FamilyEvenWhenHardwareFilteredOut() {
        let lowMemoryCatalog = RuntimeModelCatalog.models(forPhysicalMemoryBytes: 8 * 1_073_741_824)
        XCTAssertFalse(lowMemoryCatalog.contains { $0.filename == "LFM2.5-8B-A1B-Base-Q4_K_M.gguf" })

        let family = ModelFamilyResolver.family(
            forFilename: "LFM2.5-8B-A1B-Base-Q4_K_M.gguf",
            vocabSize: 1
        )
        XCTAssertEqual(family, RuntimeModelCatalog.lfm25Family)
    }

    func testUnknownModelDerivesFamilyFromNameAndVocab() {
        let family = ModelFamilyResolver.family(forFilename: "My_Custom Model.Q4.gguf", vocabSize: 32000)
        XCTAssertEqual(family, "my-custom-model-q4-v32000")
    }

    func testDerivedFamilyIsDeterministic() {
        let a = ModelFamilyResolver.derivedFamily(forFilename: "foo.gguf", vocabSize: 100)
        let b = ModelFamilyResolver.derivedFamily(forFilename: "foo.gguf", vocabSize: 100)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "foo-v100")
    }

    func testDerivedFamilyCollapsesAndTrimsSeparators() {
        let family = ModelFamilyResolver.derivedFamily(forFilename: "--a__b--.gguf", vocabSize: 7)
        XCTAssertEqual(family, "a-b-v7")
    }
}
