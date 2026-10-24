import Foundation
#if canImport(Darwin)
import Darwin
#endif

public protocol Shell: Sendable {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult
}

public struct ShellResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
    }
}

public struct FakeShell: Shell {
    public var responses: [String: ShellResult]
    public init(responses: [String: ShellResult] = [:]) {
        self.responses = responses
    }
    public func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        let key = ([executable] + arguments).joined(separator: " ")
        if let r = responses[key] { return r }
        for (k, v) in responses where key.hasPrefix(k) { return v }
        throw khuFail("fake shell: no response for \(key)")
    }
}

/// Runs a helper with a hard deadline. Both pipes are drained while it runs (a helper that fills
/// one would otherwise block forever), and on the deadline it is sent SIGTERM, then SIGKILL, and
/// reaped before this throws — so a timed-out `ditto` can never keep writing after the caller
/// has moved on to restoring the previous app.
public struct SystemShell: Shell {
    public var killGrace: TimeInterval
    public init(killGrace: TimeInterval = 5) { self.killGrace = killGrace }

    public func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe; process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw khuFail("cannot launch \(executable): \(error)") }

        let group = DispatchGroup()
        nonisolated(unsafe) var out = Data()
        nonisolated(unsafe) var err = Data()
        group.enter()
        DispatchQueue.global().async { out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let deadline = Mono.now() + timeout
        while process.isRunning && Mono.now() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            let pid = process.processIdentifier
            kill(pid, SIGTERM)
            let grace = Mono.now() + killGrace
            while process.isRunning && Mono.now() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(pid, SIGKILL) }
            process.waitUntilExit()
            _ = group.wait(timeout: .now() + 5)
            throw khuFail("timeout running \(executable) after \(Int(timeout)) s; it was stopped")
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 30)
        return ShellResult(exitCode: process.terminationStatus,
                           stdout: String(decoding: out, as: UTF8.self),
                           stderr: String(decoding: err, as: UTF8.self))
    }
}
