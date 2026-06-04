import ConstrainedGeneration
import XCTest

/// The FIM-quality tunables (ADR-057) are always-applied numeric defaults, not on/off flags. This
/// pins their default values so an accidental change is caught.
final class DecodingConfigurationTests: XCTestCase {
    func testFIMQualityDefaults() {
        let config = DecodingConfiguration()
        XCTAssertEqual(config.fimMaxPrefixTokens, 256)
        XCTAssertEqual(config.fimMaxSuffixTokens, 64)
        XCTAssertEqual(config.suffixRerankTokenCount, 3)
        XCTAssertEqual(config.suffixRerankWeight, 1.0)
    }

    func testExistingDefaultsUnchanged() {
        let config = DecodingConfiguration()
        XCTAssertEqual(config.branchWidth, 2)
        XCTAssertEqual(config.maxCandidates, 5)
        XCTAssertFalse(config.enableFillInMiddle)
    }
}
