import Foundation
import CryptoKit

public enum Signing {
    public struct KeyPair {
        public let privateKey: Curve25519.Signing.PrivateKey
        public var publicKeyBase64: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }
    }

    public static func generateKeyPair() -> KeyPair {
        KeyPair(privateKey: Curve25519.Signing.PrivateKey())
    }

    /// Creates the key file ONLY when it does not already exist, and never overwrites one: a second
    /// key stored at the same path would orphan every agent pinned to the first — and would be the
    /// key whose public half `keygen` never printed. The bytes go to a temporary file first (so no
    /// reader ever sees half a key) and are published with `link(2)`, which is atomic and fails with
    /// `EEXIST`: two `keygen`s running at once can leave only one key stored, and it is the one
    /// whose public key was printed. The mode is 0600 from creation.
    public static func savePrivateKey(_ key: Curve25519.Signing.PrivateKey, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = try AtomicFile.write(key.rawRepresentation,
                                             to: directory.appendingPathComponent(".\(url.lastPathComponent).khu-tmp-\(UUID().uuidString)"),
                                             permissions: 0o600)
        defer { _ = try? Trash.move(temporary, into: Trash.root(in: directory)) }
        guard link(temporary.path, url.path) == 0 else {
            throw khuFail(errno == EEXIST
                ? "\(url.path) already exists; a new key would orphan every agent pinned to the old one"
                : "cannot create \(url.path) (errno \(errno))")
        }
        AtomicFile.syncDirectory(directory)
    }

    public static func loadPrivateKey(from url: URL) throws -> Curve25519.Signing.PrivateKey {
        let data = try Data(contentsOf: url)
        do { return try Curve25519.Signing.PrivateKey(rawRepresentation: data) }
        catch { throw khuFail("invalid private key: \(error)") }
    }

    public static func loadPublicKey(base64: String) throws -> Curve25519.Signing.PublicKey {
        guard let data = Data(base64Encoded: base64) else { throw khuFail("bad public key base64") }
        do { return try Curve25519.Signing.PublicKey(rawRepresentation: data) }
        catch { throw khuFail("invalid public key: \(error)") }
    }

    public static func sign(_ data: Data, with key: Curve25519.Signing.PrivateKey) throws -> Data {
        do { return try key.signature(for: data) } catch { throw khuFail("signing failed: \(error)") }
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 and byte count of a file, read in 1 MiB pieces (a 1.4 GB DMG never sits in memory).
    public static func sha256Hex(fileAt url: URL) throws -> (hex: String, bytes: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        // One buffer, read into again and again. A fresh 1 MiB Data per piece left the zone holding
        // freed holes it never returns: measured 2026-11-24, a served 400 MB file left 600 MB of
        // fragmentation with 213 KB live, and the same shape is the 2026-11-17 4 GB after 1.5 GB.
        let fd = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        buffer.withUnsafeMutableBytes { raw in
            while true {
                let n = read(fd, raw.baseAddress, raw.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[0..<n]))
                total += Int64(n)
            }
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }

    public static func verify(_ data: Data, signature: Data, publicKey: Curve25519.Signing.PublicKey) -> Bool {
        publicKey.isValidSignature(signature, for: data)
    }
}

/// Versions are dotted numbers only (`1.4.355`, `0.2.197`). Anything else — `1.0.0-beta`, `v2`,
/// an empty string — is not a version KH Updater will compare, rather than one that silently
/// compares equal to its release.
public enum VersionCompare {
    public static func parse(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...6).contains(parts.count) else { return nil }
        var out: [Int] = []
        for part in parts {
            guard (1...9).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            out.append(n)
        }
        return out
    }

    public static func isValid(_ version: String) -> Bool { parse(version) != nil }

    /// True only when both are versions and `candidate` is strictly newer.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current).map { $0 > 0 } ?? false
    }

    /// -1, 0 or 1; nil when either side is not a version.
    public static func compare(_ a: String, _ b: String) -> Int? {
        guard let pa = parse(a), let pb = parse(b) else { return nil }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
