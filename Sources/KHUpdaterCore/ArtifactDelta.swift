import Foundation
import CryptoKit

/// A signed description of an incremental artifact: the patch that turns one exact, verified full
/// artifact into the next one. It rides along as an optional field of the signed feed, so a Mac
/// built before it existed reads the feed exactly as it did and downloads the whole artifact.
public struct ArtifactDelta: Codable, Sendable, Equatable {
    /// The patch file, stored beside the artifacts under its own hash.
    public var file: String
    /// The patch's own SHA-256 and size: its bytes are checked before a single one is used.
    public var sha256: String
    public var bytes: Int64
    /// The exact full artifact the patch applies to, and its size.
    public var baseSHA256: String
    public var baseBytes: Int64

    public init(file: String, sha256: String, bytes: Int64, baseSHA256: String, baseBytes: Int64) {
        self.file = file; self.sha256 = sha256; self.bytes = bytes
        self.baseSHA256 = baseSHA256; self.baseBytes = baseBytes
    }

    public func validated() throws -> ArtifactDelta {
        _ = try SafeName.component(file, what: "delta name")
        guard sha256.count == 64, bytes > 0 else { throw khuFail("delta has no usable sha256 or size") }
        guard baseSHA256.count == 64, baseBytes > 0 else { throw khuFail("delta has no usable base hash or size") }
        return self
    }
}

/// The patch file itself: a small header and a list of copy/literal operations.
///
///     "KHUD1"  baseBytes  targetBytes  blockSize
///     0x01 length bytes…              — bytes carried in the patch
///     0x02 offset length              — bytes copied from the base
///
/// Every length, offset and operation count is checked against the signed sizes before a byte is
/// written, so a patch can never make a Mac write more than the artifact it was signed for, and
/// never makes it allocate a buffer bigger than one piece of the transfer.
public enum ArtifactDeltaPatch {
    static let magic = Data("KHUD1".utf8)
    /// The block both sides match on.
    public static let blockSize = 64 * 1024
    /// Bounds a patch may not cross.
    static let maxOperations = 4_000_000
    static let maxLiteral = 8 * 1024 * 1024
    static let flushAt = 4 * 1024 * 1024
    static let literalOp: UInt8 = 0x01
    static let copyOp: UInt8 = 0x02

    /// The patch that turns `base` into `target`, written to `output`. Blocks of `blockSize` that
    /// appear in both are copied from the base; everything else is carried literally.
    public static func build(base: URL, target: URL, to output: URL, blockSize: Int = ArtifactDeltaPatch.blockSize) throws -> Int64 {
        guard blockSize > 0, blockSize <= (1 << 20) else { throw khuFail("invalid patch block size") }
        let fm = FileManager.default
        let baseSize = try size(of: base), targetSize = try size(of: target)
        // Which blocks of the base are worth copying: one offset per distinct block.
        var index: [Data: (offset: Int64, length: Int)] = [:]
        let baseHandle = try FileHandle(forReadingFrom: base)
        defer { try? baseHandle.close() }
        var offset: Int64 = 0
        while let block = try baseHandle.read(upToCount: blockSize), !block.isEmpty {
            let digest = Data(SHA256.hash(data: block))
            if index[digest] == nil { index[digest] = (offset, block.count) }
            offset += Int64(block.count)
        }
        let targetHandle = try FileHandle(forReadingFrom: target)
        defer { try? targetHandle.close() }
        guard fm.createFile(atPath: output.path, contents: nil) else { throw khuFail("cannot write \(output.path)") }
        let out = try FileHandle(forWritingTo: output)
        defer { try? out.close() }
        try out.write(contentsOf: magic)
        try write(UInt64(baseSize), to: out)
        try write(UInt64(targetSize), to: out)
        try write(UInt32(blockSize), to: out)
        var literal = Data()
        func flush() throws {
            guard !literal.isEmpty else { return }
            try out.write(contentsOf: [literalOp])
            try write(UInt32(literal.count), to: out)
            try out.write(contentsOf: literal)
            literal.removeAll(keepingCapacity: true)
        }
        while let block = try targetHandle.read(upToCount: blockSize), !block.isEmpty {
            let digest = Data(SHA256.hash(data: block))
            if let hit = index[digest], hit.length == block.count {
                try flush()
                try out.write(contentsOf: [copyOp])
                try write(UInt64(hit.offset), to: out)
                try write(UInt64(block.count), to: out)
            } else {
                literal.append(block)
                if literal.count >= flushAt { try flush() }
            }
        }
        try flush()
        try out.close()
        return try size(of: output)
    }

    /// Rebuild the artifact from `base` and `patch`, writing it to `output`. The patch's own hash
    /// is checked by the caller before this runs; everything the patch claims about the base and
    /// the target is checked here.
    public static func apply(base: URL, patch: URL, to output: URL, baseBytes: Int64, targetBytes: Int64) throws {
        guard baseBytes > 0, targetBytes > 0 else { throw khuFail("invalid signed patch sizes") }
        guard !DownloadControl.cancelled else { throw khuFail("cancelled on this Mac; nothing was changed") }
        let fm = FileManager.default
        guard try size(of: base) == baseBytes else { throw khuFail("the patch base is not the signed size") }
        let patchHandle = try FileHandle(forReadingFrom: patch)
        defer { try? patchHandle.close() }
        guard try read(patchHandle, magic.count) == magic else { throw khuFail("this file is not a KH Updater patch") }
        let declaredBase = try readUInt64(patchHandle)
        let declaredTarget = try readUInt64(patchHandle)
        let block = try readUInt32(patchHandle)
        guard declaredBase == UInt64(baseBytes) else { throw khuFail("the patch was built for a different base") }
        guard declaredTarget == UInt64(targetBytes) else { throw khuFail("the patch does not build the signed artifact") }
        guard block > 0, block <= (1 << 20) else { throw khuFail("the patch names an impossible block size") }
        guard fm.createFile(atPath: output.path, contents: nil) else { throw khuFail("cannot write \(output.path)") }
        let out = try FileHandle(forWritingTo: output)
        defer { try? out.close() }
        let baseHandle = try FileHandle(forReadingFrom: base)
        defer { try? baseHandle.close() }
        var written: Int64 = 0
        var operations = 0
        while let op = try patchHandle.read(upToCount: 1), !op.isEmpty {
            operations += 1
            guard operations <= maxOperations else { throw khuFail("the patch has too many operations") }
            switch op[0] {
            case literalOp:
                let length = Int64(try readUInt32(patchHandle))
                guard length > 0, length <= maxLiteral, length <= targetBytes - written else {
                    throw khuFail("the patch writes past the signed artifact")
                }
                var remaining = length
                while remaining > 0 {
                    guard !DownloadControl.cancelled else { throw khuFail("cancelled on this Mac; nothing was changed") }
                    let want = Int(min(remaining, 1 << 20))
                    guard let piece = try patchHandle.read(upToCount: want), piece.count == want else {
                        throw khuFail("the patch ended early")
                    }
                    try out.write(contentsOf: piece)
                    remaining -= Int64(piece.count)
                }
                written += length
            case copyOp:
                let from = try readUInt64(patchHandle)
                let length = try readUInt64(patchHandle)
                guard length > 0, from <= UInt64(baseBytes), length <= UInt64(baseBytes) - from else {
                    throw khuFail("the patch copies outside its base")
                }
                guard Int64(length) <= targetBytes - written else { throw khuFail("the patch writes past the signed artifact") }
                try baseHandle.seek(toOffset: from)
                var remaining = length
                while remaining > 0 {
                    guard !DownloadControl.cancelled else { throw khuFail("cancelled on this Mac; nothing was changed") }
                    let want = Int(min(remaining, 1 << 20))
                    guard let piece = try baseHandle.read(upToCount: want), piece.count == want else {
                        throw khuFail("the patch base ended early")
                    }
                    try out.write(contentsOf: piece)
                    remaining -= UInt64(piece.count)
                }
                written += Int64(length)
            default:
                throw khuFail("the patch has an unknown operation")
            }
            guard !DownloadControl.cancelled else { throw khuFail("cancelled on this Mac; nothing was changed") }
        }
        guard written == targetBytes else { throw khuFail("the patch does not build the signed artifact") }
    }

    // MARK: - bytes

    static func size(of url: URL) throws -> Int64 {
        guard let number = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            throw khuFail("cannot read the size of \(url.path)")
        }
        return number.int64Value
    }

    private static func write(_ value: UInt32, to handle: FileHandle) throws {
        var v = value.littleEndian
        try withUnsafeBytes(of: &v) { try handle.write(contentsOf: $0) }
    }

    private static func write(_ value: UInt64, to handle: FileHandle) throws {
        var v = value.littleEndian
        try withUnsafeBytes(of: &v) { try handle.write(contentsOf: $0) }
    }

    private static func read(_ handle: FileHandle, _ count: Int) throws -> Data {
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw khuFail("the patch ended early")
        }
        return data
    }

    private static func readUInt32(_ handle: FileHandle) throws -> UInt32 {
        let data = try read(handle, 4)
        return UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
    }

    private static func readUInt64(_ handle: FileHandle) throws -> UInt64 {
        let data = try read(handle, 8)
        var value: UInt64 = 0
        for i in stride(from: 7, through: 0, by: -1) { value = (value << 8) | UInt64(data[i]) }
        return value
    }
}
