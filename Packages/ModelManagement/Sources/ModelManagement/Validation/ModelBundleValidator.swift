import Foundation
import ModelRuntime

/// Validates a completed MLX bundle before it can be selected. This deliberately has no network
/// policy: callers may stage downloads however they choose, but readiness always uses this same
/// exact size-and-digest check.
public enum ModelBundleValidator {
    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case missingFile(String)
        case pathEscapesBundle(String)

        public var description: String {
            switch self {
            case let .missingFile(path): return "Missing required MLX model file: \(path)"
            case let .pathEscapesBundle(path): return "Invalid MLX model file path: \(path)"
            }
        }
    }

    public static func validate(
        directory: URL,
        manifest: SupportedMLXModel,
        verifyDigests: Bool = true
    ) throws {
        guard ModelContainer.modelBundleExists(at: directory) else {
            throw ValidationError.missingFile(directory.path)
        }
        for file in manifest.requiredFiles {
            guard !file.relativePath.hasPrefix("/"),
                  !file.relativePath.split(separator: "/").contains("..") else {
                throw ValidationError.pathEscapesBundle(file.relativePath)
            }
            let url = directory.appendingPathComponent(file.relativePath, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError.missingFile(file.relativePath)
            }
            try ModelFileValidator.validateSize(of: url, expectedBytes: file.expectedSizeBytes)
            if verifyDigests {
                try ModelFileValidator.validateSHA256(of: url, expectedSHA256: file.sha256)
            }
        }
    }
}
