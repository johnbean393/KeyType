import Foundation

/// Resolves on-disk paths inside KeyType's per-user Application Support container.
///
/// Layout:
///
///     ~/Library/Application Support/KeyType/
///         Models/<file>.gguf
///         …
///
/// Nothing here downloads or fetches; we assume the user has already placed the model file
/// at the expected location (see ADR-007). The container is intentionally outside the git
/// repo and the Xcode project so model weights and other large local-only assets never get
/// committed by accident.
public enum ModelContainer {
    /// Bundle-style identifier used to namespace the Application Support directory.
    public static let directoryName = "KeyType"

    /// Default GGUF currently being used for on-device tests.
    public static let defaultModelFilename = "Qwen3.5-2B-Base-Q4_K_M.gguf"

    /// `~/Library/Application Support/KeyType` (creating it lazily on demand).
    public static func containerURL(create: Bool = false) throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
        let dir = support.appendingPathComponent(directoryName, isDirectory: true)
        if create {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// `<container>/Models` directory.
    public static func modelsDirectoryURL(create: Bool = false) throws -> URL {
        let dir = try containerURL(create: create).appendingPathComponent("Models", isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// URL of a model file inside `<container>/Models/`.
    public static func modelURL(filename: String = defaultModelFilename) throws -> URL {
        try modelsDirectoryURL().appendingPathComponent(filename, isDirectory: false)
    }

    /// `true` iff the default model is present on disk and looks like a non-empty file.
    public static func defaultModelExists() -> Bool {
        guard let url = try? modelURL() else { return false }
        return modelExists(at: url)
    }

    public static func modelExists(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard exists, !isDir.boolValue else { return false }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber {
            return size.intValue > 0
        }
        return true
    }
}
