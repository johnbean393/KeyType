import XCTest
@testable import MacContextCapture

final class AppBundleWebAppClassifierTests: XCTestCase {
    func testChromeBundleIsKnownWebBacked() {
        let classifier = AppBundleWebAppClassifier()

        XCTAssertTrue(AppBundleWebAppClassifier.bundleIdentifierIsKnownWebBacked("com.google.Chrome"))
        XCTAssertTrue(classifier.isWebBacked(bundleIdentifier: "com.google.Chrome"))
    }

    func testNativeBundleIdentifierIsNotKnownWebBacked() {
        XCTAssertFalse(AppBundleWebAppClassifier.bundleIdentifierIsKnownWebBacked("com.apple.TextEdit"))
    }

    func testDetectsElectronFrameworkMarker() throws {
        let bundleURL = try makeTemporaryAppBundle()
        let markerURL = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        try FileManager.default.createDirectory(at: markerURL, withIntermediateDirectories: true)

        XCTAssertTrue(AppBundleWebAppClassifier.bundleContainsElectronMarkers(at: bundleURL))
    }

    func testDetectsAsarResourceMarker() throws {
        let bundleURL = try makeTemporaryAppBundle()
        let markerURL = bundleURL.appendingPathComponent("Contents/Resources/app.asar")
        try FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: markerURL.path, contents: Data())

        XCTAssertTrue(AppBundleWebAppClassifier.bundleContainsElectronMarkers(at: bundleURL))
    }

    func testNativeBundleWithoutElectronMarkersIsNotWebBacked() throws {
        let bundleURL = try makeTemporaryAppBundle()
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true
        )

        XCTAssertFalse(AppBundleWebAppClassifier.bundleContainsElectronMarkers(at: bundleURL))
    }

    private func makeTemporaryAppBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return bundleURL
    }
}
