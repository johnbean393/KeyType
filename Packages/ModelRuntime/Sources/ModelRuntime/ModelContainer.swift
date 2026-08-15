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

    /// Default GGUF: the recommended Qwen3.5 2B base build from the downloadable catalog.
    public static let defaultModelFilename = "Qwen3.5-2B-Base.i1-Q4_K_M.gguf"

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

    /// Directory containing verified MLX model bundles. Each catalog entry owns one
    /// subdirectory; incomplete staging directories are never considered installed.
    public static func mlxModelsDirectoryURL(create: Bool = false) throws -> URL {
        let dir = try modelsDirectoryURL(create: create)
            .appendingPathComponent("MLX", isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public static func mlxModelDirectoryURL(identifier: String, createParent: Bool = false) throws -> URL {
        try mlxModelsDirectoryURL(create: createParent)
            .appendingPathComponent(identifier, isDirectory: true)
    }

    public static func modelBundleExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Filename of a profile for a given tokenizer family — e.g.
    /// `"qwen3-v151936"` → `"qwen3-v151936.acpf.bin"`.
    public static func profileFilename(family: String) -> String {
        "\(family).acpf.bin"
    }

    /// URL of a token-profile binary for `family`, sitting beside the GGUF inside
    /// `<container>/Models/`. The file is never inside the repo; see ADR-009.
    public static func profileURL(family: String, create: Bool = false) throws -> URL {
        let dir = try modelsDirectoryURL(create: create)
        return dir.appendingPathComponent(profileFilename(family: family), isDirectory: false)
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
