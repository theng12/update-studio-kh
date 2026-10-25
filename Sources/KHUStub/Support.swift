import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The one error type used across KH Updater. Messages are meant to be shown to the owner.
public struct KHUError: Error, CustomStringConvertible, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public func khuFail(_ message: String) -> KHUError { KHUError(message) }

/// Names that come off the wire (artifact file names, machine ids, app ids) are never used as
/// path components before passing through here. No separators, no leading dot, no "..".
public enum SafeName {
    /// The cap is in BYTES, not characters — a file system entry holds 255 (`ENAMETOOLONG`) and a
    /// name's *characters* say nothing about its bytes. It is derived from the longest name anything
    /// builds out of one of these: the publisher's `artifacts/<sha12-><name>` (13) written through
    /// the atomic writer's `.<sha12-><name>.khu-tmp-<36-char uuid>` (46 more), and the agent's
    /// `…<name>.part` (5). 196 + 59 = 255, so every derived name fits.
    public static let maxBytes = 196

    public static func component(_ name: String, what: String = "name") throws -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_+@ ")
        guard !name.isEmpty, name.utf8.count <= maxBytes,
              name != ".", name != "..",
              !name.hasPrefix("."),
              !name.hasPrefix(" "), !name.hasSuffix(" "),
              name.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            throw khuFail("refused unsafe \(what): \(name)")
        }
        return name
    }
}

/// The kernel's own spelling of a path (`realpath(3)`), which is what `proc_pidpath` reports about
/// a process. Foundation's `resolvingSymlinksInPath` drops `/private`, so it would never match —
/// and anything that has to decide "is this the same file" by what a process says about itself
/// needs this one.
public enum RealPath {
    public static func of(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

public enum ISO {
    public static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    public static func date(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

/// Seconds on a clock that neither sleep nor a clock correction moves backwards or jumps.
/// Every live wait (health, stop, shell, poll) is measured on this, never on `Date`.
public enum Mono {
    public static func now() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }
}

/// State files are written temp + fsync + rename so a reader never sees a half-written file.
public enum AtomicFile {
    @discardableResult
    public static func write(_ data: Data,
                             to url: URL,
                             permissions: mode_t? = nil,
                             fileManager: FileManager = .default) throws -> URL {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).khu-tmp-\(UUID().uuidString)")
        // Created with its final mode: a private key must never exist, even for an instant, readable by others.
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, permissions ?? 0o644)
        guard fd >= 0 else { throw khuFail("cannot create temporary file at \(temporary.path) (errno \(errno))") }
        if let permissions { fchmod(fd, permissions) }  // the umask may have narrowed or widened the open() mode
        var ok = true
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = Darwin.write(fd, base + sent, data.count - sent)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { ok = false; return }
                sent += n
            }
        }
        if ok && fsync(fd) != 0 { ok = false }
        close(fd)
        guard ok else {
            _ = try? Trash.move(temporary, into: Trash.root(in: directory), fileManager: fileManager)
            throw khuFail("cannot write \(url.path) (errno \(errno))")
        }
        if rename(temporary.path, url.path) != 0 {
            let code = errno
            _ = try? Trash.move(temporary, into: Trash.root(in: directory), fileManager: fileManager)
            throw khuFail("cannot replace \(url.path) (errno \(code))")
        }
        syncDirectory(directory)
        return url
    }

    public static func syncDirectory(_ directory: URL) {
        let descriptor = open(directory.path, O_RDONLY)
        if descriptor >= 0 {
            fsync(descriptor)
            close(descriptor)
        }
    }

    public static func writeJSON<T: Encodable>(_ value: T,
                                               to url: URL,
                                               permissions: mode_t? = nil,
                                               fileManager: FileManager = .default) throws {
        try write(JSON.encode(value), to: url, permissions: permissions, fileManager: fileManager)
    }

    /// Returns nil when the file is absent; throws when it exists but cannot be read or decoded.
    public static func readJSON<T: Decodable>(_ type: T.Type,
                                              from url: URL,
                                              fileManager: FileManager = .default) throws -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try JSON.decode(type, from: data)
        } catch {
            throw khuFail("cannot read \(url.path): \(error)")
        }
    }
}

/// An exclusive lock shared by every process on this Mac (flock on a file), held for the length
/// of `body`. Two agents, an agent and `--once`, or `serve` and `enrol` can then never interleave
/// a read-modify-write or an install. The kernel drops it if the holder dies.
public enum FileLock {
    public static func withExclusive<T>(_ url: URL, wait: Bool = true, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw khuFail("cannot open lock \(url.path) (errno \(errno))") }
        defer { close(fd) }
        var result: Int32
        repeat { result = flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB)) } while result != 0 && errno == EINTR
        guard result == 0 else {
            throw khuFail(errno == EWOULDBLOCK ? "another KH Updater process holds \(url.lastPathComponent)"
                                               : "cannot lock \(url.path) (errno \(errno))")
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

public enum JSON {
    public static func encode<T: Encodable>(_ value: T, pretty: Bool = true) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
                                          : [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw khuFail("malformed JSON: \(error)")
        }
    }
}

/// Nothing in KH Updater deletes a file. Anything unwanted is moved here instead, and the owner
/// empties it when he feels like it.
public enum Trash {
    public static func root(in base: URL) -> URL { base.appendingPathComponent("_trash", isDirectory: true) }

    public static func bucket(in base: URL, at date: Date) -> URL {
        let stamp = ISO.string(date).replacingOccurrences(of: ":", with: "-")
        return root(in: base).appendingPathComponent(stamp, isDirectory: true)
    }

    @discardableResult
    public static func move(_ url: URL,
                            into trashRoot: URL,
                            at date: Date = Date(),
                            fileManager: FileManager = .default) throws -> URL {
        guard fileManager.fileExists(atPath: url.path)
                || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
        else { return url }
        var destination = trashRoot
            .appendingPathComponent(ISO.string(date).replacingOccurrences(of: ":", with: "-"), isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        var suffix = 1
        while fileManager.fileExists(atPath: destination.path)
                || (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            destination = destination.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent)-\(suffix)")
            suffix += 1
        }
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }
}
