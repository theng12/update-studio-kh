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
    public static func component(_ name: String, what: String = "name") throws -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_+@ ")
        guard !name.isEmpty, name.count <= 128,
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
        guard fileManager.createFile(atPath: temporary.path, contents: data) else {
            throw khuFail("cannot create temporary file at \(temporary.path)")
        }
        if let permissions { chmod(temporary.path, permissions) }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if rename(temporary.path, url.path) != 0 {
            try? fileManager.removeItem(at: temporary)
            throw khuFail("cannot replace \(url.path) (errno \(errno))")
        }
        let directoryDescriptor = open(directory.path, O_RDONLY)
        if directoryDescriptor >= 0 {
            fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
        return url
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
        while fileManager.fileExists(atPath: destination.path) {
            destination = destination.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent)-\(suffix)")
            suffix += 1
        }
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }
}
