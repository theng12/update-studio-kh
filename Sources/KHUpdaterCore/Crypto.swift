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

    public static func savePrivateKey(_ key: Curve25519.Signing.PrivateKey, to url: URL) throws {
        let data = key.rawRepresentation
        try AtomicFile.write(data, to: url, permissions: 0o600)
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

    public static func sign(_ data: Data, with key: Curve25519.Signing.PrivateKey) -> Data {
        (try? key.signature(for: data)) ?? Data()
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ data: Data, signature: Data, publicKey: Curve25519.Signing.PublicKey) -> Bool {
        publicKey.isValidSignature(signature, for: data)
    }
}

public enum VersionCompare {
    /// Returns true if `candidate` is strictly newer than `current`.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) > 0
    }

    public static func compare(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
