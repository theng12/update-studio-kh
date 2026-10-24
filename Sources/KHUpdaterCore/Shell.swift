import Foundation

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
    public var calls: [String]
    public init(responses: [String: ShellResult] = [:]) {
        self.responses = responses; self.calls = []
    }
    public func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        let key = ([executable] + arguments).joined(separator: " ")
        if let r = responses[key] { return r }
        // prefix match
        for (k, v) in responses where key.hasPrefix(k) { return v }
        throw khuFail("fake shell: no response for \(key)")
    }
}

public struct SystemShell: Shell {
    public init() {}
    public func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe; process.standardError = errPipe
        do { try process.run() } catch { throw khuFail("cannot launch \(executable): \(error)") }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate(); throw khuFail("timeout running \(executable)") }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ShellResult(exitCode: process.terminationStatus, stdout: out, stderr: err)
    }
}
