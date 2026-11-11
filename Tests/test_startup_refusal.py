#!/usr/bin/env python3
"""Compile the actual startup method with mock Shell, never launchctl or an app.

This focused lane does not typecheck the rest of Connect or replace the release gate.
Output and fixture homes are retained at --output for source-bound review.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--source-file', type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
source = args.source_file or root / 'Sources/KHUpdaterCore/Connect.swift'
text = source.read_text()
start = text.index('    public static func startInstalledAgent(')
end = text.index('    // MARK: staying connected', start)
method = text[start:end]
assert method.count('public static func startInstalledAgent(') == 1
setup_start = text.index('    public static func isSetUp(')
setup_end = text.index('    /// The name this Mac proposes', setup_start)
setup = text[setup_start:setup_end]
shell_text = (root / 'Sources/KHUpdaterCore/Shell.swift').read_text()
interfaces = shell_text[shell_text.index('public protocol Shell:'):shell_text.index('public struct FakeShell:')]
args.output.mkdir(parents=True, exist_ok=False)
harness = r'''
import Foundation
func khuFail(_ text: String) -> NSError { NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
'''+interfaces+r'''
struct SystemShell: Shell {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        fatalError("A real shell must never run in this fixture")
    }
}
enum Connect {
'''+setup+method+r'''
}
final class Script: Shell, @unchecked Sendable {
    var calls: [[String]] = []
    var replies: [ShellResult?]
    init(_ replies: [ShellResult?]) { self.replies = replies }
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        guard executable == "/bin/launchctl" else { fatalError("Unexpected executable") }
        calls.append(arguments)
        guard !replies.isEmpty else { throw khuFail("Unexpected mock call") }
        guard let next = replies.removeFirst() else { throw khuFail("TOKEN-SENTINEL https://private.invalid/private") }
        return next
    }
}
let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1])
var passed = 0, failed = 0
func result(_ code: Int32, _ out: String = "", _ err: String = "") -> ShellResult {
    ShellResult(exitCode: code, stdout: out, stderr: err)
}
let absent = result(113, "", "Could not find service \"com.khupdater.agent\" in domain for user gui: 501")
let enabled = result(0, "disabled services = {\n}\n")
let poison = "TOKEN-SENTINEL https://private.invalid/private /Users/private/path"
func snapshot(_ home: URL) -> [String: Data] {
    var saved: [String: Data] = [:]
    if let paths = fm.enumerator(at: home, includingPropertiesForKeys: nil) {
        for case let p as URL in paths { if let d = try? Data(contentsOf: p) { saved[p.path] = d } }
    }
    return saved
}
func check(_ name: String, _ replies: [ShellResult?], _ phases: [String], contains: String? = nil, layout: String = "valid") {
    let home = root.appendingPathComponent(name)
    let library = home.appendingPathComponent("Library")
    let config = library.appendingPathComponent("KHUpdater/base/config.json")
    try! fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data("{\"machine\":\"legacy-005\",\"token\":\"fixture-identity\",\"feedURL\":\"https://old.invalid/release.json\",\"publicKey\":\"fixture-pin\"}".utf8).write(to: config)
    let stub = library.appendingPathComponent("KHUpdater/bin/khu-stub")
    try! fm.createDirectory(at: stub.deletingLastPathComponent(), withIntermediateDirectories: true)
    if layout != "missing-executable" {
        fm.createFile(atPath: stub.path, contents: Data("fixture, never executed".utf8), attributes: [.posixPermissions: 0o755])
    }
    let plist = library.appendingPathComponent("LaunchAgents/com.khupdater.agent.plist")
    try! fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
    if layout != "missing-plist" {
        let job: [String: Any] = ["Label": layout == "wrong-label" ? "other.job" : "com.khupdater.agent", "ProgramArguments": [stub.path, "--base", config.deletingLastPathComponent().path], "RunAtLoad": true, "KeepAlive": true]
        let bytes = layout == "malformed-plist" ? Data("not a plist".utf8) : try! PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        try! bytes.write(to: plist)
    }
    let before = snapshot(home)
    let shell = Script(replies)
    var error: String?
    do { try Connect.startInstalledAgent(home: home, shell: shell) }
    catch let e { error = (e as NSError).localizedDescription }
    let expected = contains.map { error?.contains($0) == true } ?? (error == nil)
    let safe = !(error ?? "").contains("TOKEN-SENTINEL") && !(error ?? "").contains("private.invalid") && !(error ?? "").contains("/Users/private")
    let ok = expected && safe && shell.calls.map { $0[0] } == phases && snapshot(home) == before && Connect.isSetUp(home: home)
    if ok { passed += 1 } else { failed += 1; print("FAIL \(name): phases=\(shell.calls.map { $0[0] }), expected=\(expected), sanitized=\(safe)") }
}
check("loaded", [result(0)], ["print"])
check("legacy005-registration", [absent, enabled, result(0)], ["print", "print-disabled", "bootstrap"])
check("disabled", [absent, result(0, "disabled services = {\n  \"com.khupdater.agent\" => true\n}\n")], ["print", "print-disabled"], contains: "disabled in macOS")
check("explicit-enabled", [absent, result(0, "disabled services = {\n \"com.khupdater.agent\" => false\n}\n"), result(0)], ["print", "print-disabled", "bootstrap"])
check("unrelated-disabled", [absent, result(0, "disabled services = {\n \"other.job\" => true\n}\n"), result(0)], ["print", "print-disabled", "bootstrap"])
check("unknown-print", [result(1, poison, poison)], ["print"], contains: "print exit 1")
check("print-throws", [nil], ["print"], contains: "could not be confirmed (print)")
check("disabled-query-refused", [absent, result(5, poison, poison)], ["print", "print-disabled"], contains: "print-disabled exit 5")
check("disabled-query-malformed", [absent, result(0, "unknown output")], ["print", "print-disabled"], contains: "could not confirm")
check("disabled-entry-ambiguous", [absent, result(0, "disabled services = {\n \"com.khupdater.agent\" => true\n \"com.khupdater.agent\" => false\n}\n")], ["print", "print-disabled"], contains: "could not be read safely")
check("disabled-entry-unknown", [absent, result(0, "disabled services = {\n \"com.khupdater.agent\" => unknown\n}\n")], ["print", "print-disabled"], contains: "could not be read safely")
check("missing-plist", [absent, enabled], ["print", "print-disabled"], contains: "missing or unreadable", layout: "missing-plist")
check("malformed-plist", [absent, enabled], ["print", "print-disabled"], contains: "incomplete", layout: "malformed-plist")
check("wrong-label", [absent, enabled], ["print", "print-disabled"], contains: "incomplete", layout: "wrong-label")
check("missing-executable", [absent, enabled], ["print", "print-disabled"], contains: "incomplete", layout: "missing-executable")
check("bootstrap-refused", [absent, enabled, result(5, poison, poison), absent], ["print", "print-disabled", "bootstrap", "print"], contains: "bootstrap exit 5")
check("bootstrap-race", [absent, enabled, result(5), result(0)], ["print", "print-disabled", "bootstrap", "print"])
check("bootstrap-throws", [absent, enabled, nil], ["print", "print-disabled", "bootstrap"], contains: "could not be confirmed (bootstrap)")
print("STARTUP FIXTURES: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
'''
swift = args.output / 'main.swift'
swift.write_text(harness)
compile_run = subprocess.run(['swiftc', str(swift), '-o', str(args.output / 'startup-tests')], capture_output=True, text=True, timeout=90)
run = None
if compile_run.returncode == 0:
    run = subprocess.run([str(args.output / 'startup-tests'), str(args.output / 'homes')], capture_output=True, text=True, timeout=30)
receipt = {'sourceFile': str(source), 'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest(), 'extractedStartupSHA256': hashlib.sha256(method.encode()).hexdigest(), 'shellInterfaceSHA256': hashlib.sha256(interfaces.encode()).hexdigest(), 'harnessSHA256': hashlib.sha256(swift.read_bytes()).hexdigest(), 'compileExit': compile_run.returncode, 'compileOutput': compile_run.stdout + compile_run.stderr, 'testExit': run.returncode if run else None, 'testOutput': run.stdout + run.stderr if run else None, 'liveShellOrNetwork': False, 'scope': 'Actual startup method + isSetUp + Shell interfaces; full Connect/module/app build not tested'}
(args.output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt, indent=2))
raise SystemExit(compile_run.returncode or (run.returncode if run else 1))
