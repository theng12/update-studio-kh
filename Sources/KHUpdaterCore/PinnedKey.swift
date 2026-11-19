import Foundation

/// The fleet's Ed25519 public key, compiled into the signed app and the signed helper.
///
/// It is not a secret — every kit already ships it — but it is the one input to trust that a
/// same-user process cannot rewrite: the saved config is an ordinary file next to the agent, so a
/// process that can write it could otherwise name its own key and have every signature "verify".
/// Every runtime check therefore verifies against this constant, and the config's `publicKey` is
/// only compared with it, never used as the verification key.
public enum PinnedKey {
    #if KHU_TESTS
    /// The test build: a fixture names the key its own feed signs with (`KHU_TEST_KEY`, or a test
    /// setting `test`). Nil keeps the pre-pin behaviour for the suites that predate it. This branch
    /// is not compiled into a release.
    public static var test: String? = ProcessInfo.processInfo.environment["KHU_TEST_KEY"]
    public static var base64: String? { test }
    #else
    /// The fleet key. `Tests/test_packaging.py` refuses a build whose constant is not a 32-byte key.
    public static let base64: String? = "BXtuZrRgTVcM+MkDukuS725aV2i22hVQIoxG2EIQyn0="
    #endif

    /// The key a verification uses: the pinned one, or — only in a test build with no key named —
    /// the one the saved config carries.
    public static func trusted(_ saved: String) -> String { base64 ?? saved }

    /// A short, comparable name for a key, for the refusal line. Both sides are shown in it, so a
    /// person can see at a glance that the Mac and this copy disagree.
    public static func fingerprint(_ base64: String) -> String {
        String(Signing.sha256Hex(Data(base64Encoded: base64) ?? Data(base64.utf8)).prefix(16))
    }

    /// Refuse before anything is fetched, sent or installed when this Mac's saved trust is not the
    /// key inside this build. Never rewrites the file: a mismatch is the owner's to resolve.
    public static func require(_ saved: String) throws {
        guard let pinned = base64, saved != pinned else { return }
        throw khuFail("This Mac's saved publisher key (\(fingerprint(saved))) is not the key inside this copy "
            + "(\(fingerprint(pinned))). Nothing was changed. This Mac was set up with another copy of Studio Launcher KH: "
            + "open it and choose Connect with the current kit.")
    }

    /// The same refusal for a setup kit that names another publisher than this build was sealed for.
    public static func requireKit(_ kitKey: String) throws {
        guard let pinned = base64, kitKey != pinned else { return }
        throw khuFail("This setup kit's publisher key (\(fingerprint(kitKey))) is not the key inside this copy "
            + "(\(fingerprint(pinned))). Nothing was sent. Use the kit that came with this copy of Studio Launcher KH.")
    }
}
