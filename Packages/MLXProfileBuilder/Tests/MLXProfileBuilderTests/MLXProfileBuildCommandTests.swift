import XCTest
@testable import acpf_build_mlx

final class MLXProfileBuildCommandTests: XCTestCase {
    func testExplicitOutputIsUsedWithoutTouchingTheFilesystem() throws {
        let command = try MLXProfileBuildCommand.parse([
            "--model-directory", "/tmp/model",
            "--output", "/tmp/keytype-profile.acpf",
        ])

        XCTAssertEqual(try command.resolveOutputURL().path, "/tmp/keytype-profile.acpf")
    }

    func testDefaultsKeepWritesEnabledAndRefuseReplacement() throws {
        let command = try MLXProfileBuildCommand.parse(["--model-directory", "/tmp/model"])

        XCTAssertFalse(command.dryRun)
        XCTAssertFalse(command.force)
    }
}
