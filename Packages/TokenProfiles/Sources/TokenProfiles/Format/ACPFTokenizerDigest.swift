import AutocompleteCore
import CryptoKit
import Foundation

/// 128-bit tokenizer-identity digest stamped into the header (`tokenizer_hash_lo/hi`) and
/// recomputed by the reader before accepting a profile. The format is the **low 128 bits
/// of SHA-256 over the canonicalised vocab**, packed little-endian.
///
/// Canonical input:
///
///     LE(vocabSize: UInt32) || foreach id in 0..<vocabSize: LE(bytesLen: UInt32) || bytes
///
/// This pins the file to one specific tokenizer (vocab size + raw token bytes per id),
/// independent of the file format itself. Using only the low 128 bits cuts the on-disk
/// hash storage to 16 bytes; the 128-bit second-preimage cost is still astronomically
/// out of reach for non-adversarial drift detection.
public struct ACPFTokenizerDigestValue: Equatable, Hashable, CustomStringConvertible {
    public let lo: UInt64
    public let hi: UInt64

    public init(lo: UInt64, hi: UInt64) {
        self.lo = lo
        self.hi = hi
    }

    /// First 16 hex characters of the digest (the high 8 bytes), suitable for logging.
    public var hexPrefix: String {
        var s = ""
        s.reserveCapacity(16)
        for i in (0..<8).reversed() {
            let b = UInt8((hi >> (UInt64(i) * 8)) & 0xff)
            s += String(format: "%02x", b)
        }
        return s
    }

    /// All 16 stored digest bytes, in canonical SHA-256 byte order. Use this for manifest
    /// pinning; `hexPrefix` is deliberately only suitable for human-facing diagnostics.
    public var hex: String {
        var s = ""
        s.reserveCapacity(32)
        for value in [lo, hi] {
            for i in 0..<8 {
                let b = UInt8((value >> (UInt64(i) * 8)) & 0xff)
                s += String(format: "%02x", b)
            }
        }
        return s
    }

    public var description: String { hexPrefix }
}

public enum ACPFTokenizerDigest {
    /// Compute the canonical digest from a vocab introspector closure. `bytesFor` is
    /// called once per token id in ascending order.
    public static func digest(
        vocabSize: Int,
        bytesFor: (TokenID) throws -> [UInt8]
    ) rethrows -> ACPFTokenizerDigestValue {
        precondition(vocabSize >= 0)
        var hasher = SHA256()
        var lenBuf = UInt32(vocabSize).littleEndian
        Swift.withUnsafeBytes(of: &lenBuf) { hasher.update(bufferPointer: $0) }
        for id in 0..<vocabSize {
            let bytes = try bytesFor(TokenID(id))
            var byteLen = UInt32(bytes.count).littleEndian
            Swift.withUnsafeBytes(of: &byteLen) { hasher.update(bufferPointer: $0) }
            bytes.withUnsafeBufferPointer { ptr in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(ptr))
            }
        }
        let digest = hasher.finalize()
        // Take the low 128 bits, packed little-endian. SHA256.Digest is a sequence of
        // 32 bytes; bytes 0..7 -> lo (LE), bytes 8..15 -> hi (LE).
        var digestBytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in digest.prefix(16).enumerated() {
            digestBytes[i] = b
        }
        let lo = digestBytes.withUnsafeBufferPointer {
            UInt64(littleEndian: UnsafeRawBufferPointer($0).loadUnaligned(fromByteOffset: 0, as: UInt64.self))
        }
        let hi = digestBytes.withUnsafeBufferPointer {
            UInt64(littleEndian: UnsafeRawBufferPointer($0).loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        }
        return ACPFTokenizerDigestValue(lo: lo, hi: hi)
    }
}
