import ModelRuntime
import XCTest
@testable import ModelManagement

final class RuntimeModelCatalogTests: XCTestCase {

    func testCatalogHasSixCuratedBaseModels() {
        XCTAssertEqual(RuntimeModelCatalog.allModels.count, 6)
    }

    func testFilenamesAreUnique() {
        let filenames = RuntimeModelCatalog.allModels.map(\.filename)
        XCTAssertEqual(Set(filenames).count, filenames.count)
    }

    func testEveryGgufFilenameEndsInGguf() {
        for model in RuntimeModelCatalog.allModels {
            XCTAssertTrue(model.filename.lowercased().hasSuffix(".gguf"), "\(model.filename)")
        }
    }

    func testRecommendedMatchesContainerDefault() {
        XCTAssertEqual(RuntimeModelCatalog.recommended.filename, ModelContainer.defaultModelFilename)
    }

    func testDefaultModelKeepsLegacyQwenFamily() {
        // An ACPF profile already on disk for the default model must keep loading without a rebuild,
        // so its family must equal the value the pipeline historically hardcoded.
        let model = RuntimeModelCatalog.model(forFilename: ModelContainer.defaultModelFilename)
        XCTAssertEqual(model?.tokenizerFamily, "qwen3-v151936")
    }

    func testUnverifiedEntriesAreNotDownloadable() {
        for model in RuntimeModelCatalog.allModels where model.downloadURL == nil {
            XCTAssertFalse(model.isDownloadable)
            XCTAssertNotNil(model.unavailableReason)
        }
    }

    func testLFM25OnlyAppearsOnMacsWithAtLeast24GiBMemory() {
        let belowThreshold = RuntimeModelCatalog.lfm25MinimumPhysicalMemoryBytes - 1
        XCTAssertNil(RuntimeModelCatalog.models(forPhysicalMemoryBytes: belowThreshold).first {
            $0.filename == "LFM2.5-8B-A1B-Base-Q4_K_M.gguf"
        })

        let atThreshold = RuntimeModelCatalog.models(
            forPhysicalMemoryBytes: RuntimeModelCatalog.lfm25MinimumPhysicalMemoryBytes
        )
        XCTAssertNotNil(atThreshold.first { $0.filename == "LFM2.5-8B-A1B-Base-Q4_K_M.gguf" })
    }

    func testLFM25CatalogEntryPinsDownloadMetadata() {
        let model = RuntimeModelCatalog.model(forFilename: "LFM2.5-8B-A1B-Base-Q4_K_M.gguf")
        XCTAssertEqual(model?.tokenizerFamily, RuntimeModelCatalog.lfm25Family)
        XCTAssertEqual(model?.expectedSizeBytes, 5_155_564_416)
        XCTAssertEqual(
            model?.sha256,
            "304496159b83de5b300daa94283f8f1c145d69785aaa1994a4957ec734f653ec"
        )
        XCTAssertEqual(
            model?.downloadURL?.absoluteString,
            "https://huggingface.co/johnbean393/LFM2.5-8B-A1B-Base-GGUF/resolve/main/LFM2.5-8B-A1B-Base-Q4_K_M.gguf?download=true"
        )
    }
}
