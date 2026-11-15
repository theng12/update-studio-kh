#!/usr/bin/env python3
"""Run the actual LiveControl service recipe and the recipe's stop phase against real throwaway
processes, a temporary bundle and a fake launchd.

Nothing here touches the real launchd, a real app, `osascript` or `open`: the recipe's only door to
the outside world is the injected `Shell`, and the processes it judges are temporary copies of one
tiny fixture binary living inside a temporary bundle. The Swift under test is extracted verbatim
from the worktree (the same pattern as `test_launcher_progress.py`), so these are the shipped rules,
including the `appQuit` relaunch in `Recipe`'s stop phase. Build and fixture scratch stays on this
volume under `.test-tmp` and retires into the repository's own `_trash`.
"""
from pathlib import Path
import os
import plistlib
import re
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
import uuid

REPO = Path(__file__).resolve().parents[1]
RECIPES = REPO / "Sources/KHUpdaterCore/Recipes.swift"
SHELL_SWIFT = REPO / "Sources/KHUpdaterCore/Shell.swift"
SUPPORT = REPO / "Sources/KHUStub/Support.swift"
CONFIG = REPO / "Sources/KHUpdaterCore/Config.swift"
BUNDLE_ID = "com.example.demoapp"

# The whole app, as far as the recipe can tell: a real file at a real path, a process that holds, and
# the only signal it answers to is the default SIGTERM. It forks once so the survivor is reaped by
# launchd rather than by this test, because a stopped service has to leave the process table for good
# instead of sitting as our zombie, which `proc_listallpids` would still list.
FIXTURE_C = r'''
#include <stdio.h>
#include <unistd.h>
#include <signal.h>

int main(int argc, char **argv) {
    pid_t child = fork();
    if (child < 0) return 1;
    if (child > 0) {
        // Publish before the launcher exits, so both fixture callers can read the PID immediately.
        FILE *f = argc > 1 ? fopen(argv[1], "w") : NULL;
        if (!f) { kill(child, SIGTERM); return 1; }
        int written = fprintf(f, "%d\n", child);
        int closed = fclose(f);
        if (written < 0 || closed != 0) { kill(child, SIGTERM); return 1; }
        return 0;
    }
    for (;;) pause();
    return 0;
}
'''

# The scenario runner. SERVICE_METHOD and STOP_BLOCK are replaced with the real helper's name and
# the real stop phase, read out of the worktree, so this file never re-implements either.
HARNESS = r'''
import Foundation
#if canImport(Darwin)
import Darwin
#endif

func verify(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); exit(1) }
}

nonisolated(unsafe) var rows: [(label: String, pid: Int)] = []
nonisolated(unsafe) var refused: Set<String> = []
nonisolated(unsafe) var running: [String: Int] = [:]
nonisolated(unsafe) var restored: [Int] = []
nonisolated(unsafe) var guiPid = 0
nonisolated(unsafe) var stoppedStatus = 0
nonisolated(unsafe) var dropRowsAfter = -1
nonisolated(unsafe) var listCalls = 0
nonisolated(unsafe) var calls: [String] = []
nonisolated(unsafe) var quitAsked = false
nonisolated(unsafe) var agentsURL = URL(fileURLWithPath: "/")

func alive(_ pid: Int) -> Bool { pid > 1 && kill(pid_t(pid), 0) == 0 }

func waitGone(_ pid: Int, _ seconds: Int) -> Bool {
    for _ in 0...(seconds * 2) {
        if !alive(pid) { return true }
        Thread.sleep(forTimeInterval: 0.5)
    }
    return !alive(pid)
}

/// The recipe's only door out, and a stand-in launchd. `list` is answered the way launchd answers
/// it: the job's live PID while that process runs, and `-` with its last exit status the moment it
/// does not — so a graceful stop reads `-  0` and a signal-killed one reads `-  15`. `kickstart`
/// starts the job's own bundled Program again, which is all a saved per-user job needs; nothing else
/// is accepted, so a forced or settings-changing call fails the run. `osascript` never runs: it is
/// the app being asked politely, so it stops only the one process the app itself owns and leaves
/// every service host up, exactly as a graceful quit does.
struct TestShell: Shell {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        let command = ([executable] + arguments).joined(separator: " ")
        calls.append(command)
        if executable == "/usr/bin/osascript" {
            if !quitAsked {
                quitAsked = true
                if guiPid > 1 { kill(pid_t(guiPid), SIGTERM) }
            }
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
        if executable == "/bin/launchctl", arguments == ["list"] {
            listCalls += 1
            var out = "PID\tStatus\tLabel\n"
            for row in rows {
                if dropRowsAfter >= 0, listCalls > dropRowsAfter {
                    out += "-\t0\t" + row.label + "\n"
                } else {
                    let pid = running[row.label] ?? row.pid
                    out += alive(pid) ? "\(pid)\t0\t" + row.label + "\n"
                                      : "-\t\(stoppedStatus)\t" + row.label + "\n"
                }
            }
            return ShellResult(exitCode: 0, stdout: out, stderr: "")
        }
        if executable == "/bin/launchctl", arguments.count == 2, arguments[0] == "kickstart",
           arguments[1].hasPrefix("gui/\(getuid())/") {
            respawn(String(arguments[1].split(separator: "/").last ?? ""))
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
        return ShellResult(exitCode: 127, stdout: "", stderr: "test shell refuses: " + command)
    }
}

/// Start a saved job the way launchd would: the executable its own plist names, from the temporary
/// LaunchAgents folder. The new PID is reported so the test can clean the process up.
func respawn(_ label: String) {
    guard let files = try? FileManager.default.contentsOfDirectory(at: agentsURL,
                                                                  includingPropertiesForKeys: nil) else { return }
    for file in files where file.pathExtension == "plist" {
        guard let data = try? Data(contentsOf: file),
              let job = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              job["Label"] as? String == label,
              let program = (job["Program"] as? String) ?? (job["ProgramArguments"] as? [String])?.first
        else { continue }
        let pidfile = agentsURL.appendingPathComponent("restored-" + label + ".pid")
        let starter = Process()
        starter.executableURL = URL(fileURLWithPath: program)
        starter.arguments = [pidfile.path]
        starter.standardOutput = FileHandle.nullDevice
        starter.standardError = FileHandle.nullDevice
        guard (try? starter.run()) != nil else { return }
        starter.waitUntilExit()
        guard let text = try? String(contentsOf: pidfile, encoding: .utf8),
              let pid = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        running[label] = pid
        restored.append(pid)
        return
    }
}

/// `Recipe`'s stop phase, verbatim from the worktree, with only its inputs faked.
func stopPhase(wasRunning: Bool, control: AppControl,
               paths: (staged: URL, journal: URL, trash: URL), fm: FileManager,
               refuseIfRunning: Bool = false) throws {
        // This fixture exercises the owner's stop phase, where a relaunch is allowed; the shipped
        // rule that decides it (relaunchAfterInstall/testInstance) is covered by the Swift suite.
        let mayRelaunch = true
STOP_BLOCK
}

func trashed(_ directory: URL, _ fm: FileManager) -> [String] {
    guard let buckets = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
    return buckets.flatMap { (try? fm.contentsOfDirectory(atPath: directory.appendingPathComponent($0).path)) ?? [] }
}

let arg = CommandLine.arguments
guard arg.count >= 6, let wait = Double(arg[4]), let status = Int(arg[5]) else {
    print("FAIL: usage MODE BUNDLE WORKDIR QUITWAIT STOPPED_STATUS [label=pid ...]")
    exit(1)
}
let mode = arg[1]
let bundle = arg[2]
agentsURL = URL(fileURLWithPath: arg[3])
stoppedStatus = status
for spec in arg.dropFirst(6) {
    let pair = spec.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard pair.count == 2, let pid = Int(pair[1]) else {
        print("FAIL: bad job spec " + spec); exit(1)
    }
    if pair[0] == "gui" { guiPid = pid; continue }
    let marked = pair[0].hasPrefix("!")
    let label = String(marked ? pair[0].dropFirst() : pair[0])
    if marked { refused.insert(label) }
    rows.append((label, pid))
}

let shell = TestShell()
let owned = LiveControl.SERVICE_METHOD(bundle, shell: shell, agents: agentsURL)

// Which saved jobs the recipe claims as this app's own services: a plainly named row must be
// claimed with its live PID (or 0 when the job is loaded but not running — a pending restart stays
// subject to the stop check), and a row marked `!` must never be claimed at all.
for row in rows where !refused.contains(row.label) {
    let want = pid_t(row.pid < 1 ? 0 : row.pid)
    verify(owned[row.label] == want,
           "the saved job \(row.label) must be claimed as this app's service (wanted \(want), got \(String(describing: owned[row.label])))")
}
for label in refused {
    verify(owned[label] == nil, "\(label) must never become a stop target (got \(String(describing: owned[label])))")
}

let control = LiveControl.appDmg(bundle, shell: shell, agentsDirectory: agentsURL, quitWait: wait)
let work = URL(fileURLWithPath: arg[3])
switch mode {
case "owned":
    verify(control.healthy("1.0.0"), "healthy must find the app up on its own version")
    verify(control.serviceLabels().sorted() == rows.map { $0.label }.sorted(),
           "the running services must be named for the journal before anything is stopped")
    verify(control.quit(), "a graceful quit must clear the app while its own service host is still up")
    // The base behaviour, from the same extracted source: with no `gone` rule a quit waits for
    // every process of the bundle, so it stays stuck on the host that outlives the app and the
    // recipe refuses to replace anything. If this ever reads true, the fix is not what the cases
    // below prove, and this test has to be revisited rather than relaxed.
    verify(!LiveControl.quit(bundle, shell: TestShell(), wait: 0),
           "BASE: the generic quit must still refuse while an owned service host is running")
    // `quit` captured the app's original labels. With launchd no longer reporting them live — while
    // the bundle's own processes still run — healthy must refuse on that alone.
    dropRowsAfter = listCalls
    verify(control.isRunning() == true, "the service hosts are still up inside the bundle")
    verify(!control.healthy("1.0.0"), "a bundle missing its original services is not healthy, even while it runs")
    dropRowsAfter = -1
    verify(control.healthy("1.0.0"), "healthy must take the bundle again once its original services are live")
    verify(control.stopService(), "stopService must SIGTERM each owned service and see each one stopped")
    verify(LiveControl.processes(inBundle: bundle)?.isEmpty == true, "no process of the bundle may be left")
case "refuse":
    verify(!control.quit(), "processes the saved jobs do not claim mean the app never really quit")
    verify(!control.stopService(), "an unclaimed process of the bundle is never a stop target")
    verify(control.isRunning() == true, "everything of the bundle must still be up: nothing was replaced")
case "noidentity":
    verify(LiveControl.isRunning(bundle) == true, "a bundle with no readable Info.plist still shows its process")
    verify(!control.quit(), "a bundle with no identity is never reported as quit")
    verify(!control.stopService(), "with no identity no job can be claimed, so nothing may be stopped")
    verify(!control.healthy("1.0.0"), "a bundle that cannot name its version is not healthy")
    verify(control.isRunning() == true, "the bundle must still be up: nothing was replaced")
case "unknown":
    verify(!control.quit(), "an extra process inside the bundle is not its service")
    verify(!control.stopService(), "one unknown process of the bundle refuses the stop for the owned service too")
    verify(control.isRunning() == true, "the owned service must still be up: nothing was replaced")
    for row in rows { verify(alive(row.pid), "a refused stop must leave \(row.label) running and untouched") }
case "stale":
    verify(control.quit(), "the app counts as gone once only its claimed service host is left")
    dropRowsAfter = listCalls          // the job disappears between the claim and the signal
    verify(!control.stopService(), "a job whose PID vanished before the signal must be refused")
    verify(listCalls > dropRowsAfter, "ownership must be rechecked immediately before signalling")
    verify(control.isRunning() == true, "the bundle must still be up: nothing was replaced")
    for row in rows { verify(alive(row.pid), "an old job PID must never be signalled (\(row.label))") }
case "signalexit":
    // A stop only ever signals a label the recipe captured while quitting, so ask in recipe order.
    verify(control.quit(), "the app counts as gone once only its claimed service host is left")
    verify(!control.stopService(), "a service launchd reports as signal-killed is not a stopped service")
    for row in rows { verify(waitGone(row.pid, 5), "\(row.label) must have been SIGTERMned, and only that") }
case "recovered":
    verify(control.quit(), "the app must quit while its owned host is up")
    let saved = control.serviceLabels()
    verify(saved == rows.map { $0.label }, "the journal must carry the label of the service it stopped")
    verify(control.stopService(), "the owned host must stop on SIGTERM")
    // The recipe rebuilds a control after a crash, so it captures nothing itself: the saved labels
    // are all that can bring the service back (`Recipe.recover` seeds exactly this call).
    let rebuilt = LiveControl.appDmg(bundle, shell: shell, agentsDirectory: agentsURL, quitWait: wait)
    verify(rebuilt.serviceLabels().isEmpty, "a rebuilt control has captured no live service of its own")
    rebuilt.restoreServices(saved)
    rebuilt.launch()
    verify(!restored.isEmpty, "the saved job must be started again before the app is opened")
    let kick = calls.firstIndex(where: { $0.hasPrefix("/bin/launchctl kickstart") }) ?? -1
    let opened = calls.firstIndex(where: { $0.hasPrefix("/usr/bin/open") }) ?? -1
    verify(kick >= 0 && opened > kick, "the captured job is kickstarted first, then the app is opened")
    verify(rebuilt.healthy("1.0.0"), "the rebuilt control must read healthy with its saved service running")
case "caller-partial", "caller-refused", "caller-dead":
    // The recipe's own stop phase, with only the world around it faked.
    var launched = 0
    let staged = work.appendingPathComponent("staged.app")
    let journal = work.appendingPathComponent("journal.json")
    let trash = work.appendingPathComponent("trash")
    let fm = FileManager.default
    try? fm.createDirectory(at: staged, withIntermediateDirectories: true)
    fm.createFile(atPath: journal.path, contents: Data("{}".utf8))
    let gate = AppControl(
        isRunning: { mode != "caller-dead" },       // a host is still up in the partial/refused case
        quit: { mode == "caller-partial" },
        launch: { launched += 1 },
        stopService: { mode != "caller-partial" },
        healthy: { _ in false })
    var reason = ""
    do {
        try stopPhase(wasRunning: true, control: gate,
                      paths: (staged: staged, journal: journal, trash: trash), fm: fm)
        verify(false, mode + ": the stop phase must refuse, not go on to promote")
    } catch let error as KHUError {
        reason = error.description
    }
    verify(reason.contains("the installed app was kept"),
           "a refusal must say the installed bundle was kept: " + reason)
    verify(!fm.fileExists(atPath: staged.path) && !fm.fileExists(atPath: journal.path),
           "the staged bundle and its journal must be out of the way, never left to promote")
    verify(trashed(trash, fm).sorted() == ["journal.json", "staged.app"],
           "both must still be in the trash, restorable")
    switch mode {
    case "caller-partial":
        // The gap this fix closes: the app quit gracefully, its service refused to stop, and another
        // process of the bundle is still up — the old guard saw `isRunning == true` and left the
        // owner with neither the app nor the update.
        verify(launched == 1, "a quit app whose service refused to stop must be reopened once, got \(launched)")
    case "caller-refused":
        verify(launched == 0, "an app that is still up must never be opened a second time")
    default:
        verify(launched == 1, "an app that died before quitting must be reopened")
    }
default:
    verify(false, "unknown mode " + mode)
}

// Every outside call is a question, never a command: no `launchctl stop`/`kill`/`bootout`, no forced
// or settings-changing `kickstart`, and `open` only where the recipe is entitled to relaunch.
for call in calls {
    verify(call == "/bin/launchctl list" || call.hasPrefix("/usr/bin/osascript")
           || call.hasPrefix("/bin/launchctl kickstart gui/\(getuid())/")
           || call == "/usr/bin/open -g -j " + bundle, "the only outside calls are asking: saw " + call)
}
for row in rows where refused.contains(row.label) {
    verify(alive(row.pid), "the refused job \(row.label) must not have been signalled")
}
for pid in restored { print("RESTORED \(pid)") }
print("PASS \(mode)")
'''

STUBS = """
/// Stub, not under test: a file hash the service rules never read. The extracted `BundleInfo` only
/// mentions it in `executableSha256`, which no case here calls.
enum Signing {
    static func sha256Hex(fileAt url: URL) throws -> (hex: String, bytes: Int64) { ("", 0) }
}
"""

GRACEFUL = {"KeepAlive": {"SuccessfulExit": False}}


def top_block(source, marker: str) -> str:
    """One whole top-level declaration, verbatim: from the line starting with `marker` to the next
    line that is just `}` — every declaration in these files closes at column zero."""
    lines = (source.read_text() if isinstance(source, Path) else source).splitlines(keepends=True)
    start = next(i for i, line in enumerate(lines) if line.startswith(marker))
    end = next(i for i in range(start, len(lines)) if lines[i] == "}\n")
    return "".join(lines[start:end + 1])


def stop_block(recipes: str) -> str:
    """The stop phase of `Recipe`'s install, verbatim: from the `appQuit` flag through the guard that
    refuses when a service will not stop. Nothing below it may run, so the throw is the proof."""
    start = recipes.index("        var appQuit = false")
    end = recipes.index("\n        // 4. Promote.", start)
    block = recipes[start:end]
    assert "control.launch()" in block and "guard control.stopService()" in block, "the stop phase no longer looks like this"
    return block


def strip_imports(text: str) -> str:
    return "".join(line for line in text.splitlines(keepends=True)
                   if not line.startswith(("import ", "#if", "#endif")))


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def scratch(kind: str) -> Path:
    root = REPO / ".test-tmp"
    root.mkdir(exist_ok=True)
    return Path(tempfile.mkdtemp(prefix="app-services-" + kind + "-", dir=str(root)))


class Bundle:
    """A temporary bundle of fixture copies, a temporary LaunchAgents folder, and its processes."""

    def __init__(self, check: Path, fixture: Path, work: Path, identity=True):
        self.check, self.fixture, self.work = check, fixture, work
        self.app = work / "Demo.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Helpers").mkdir(parents=True)
        (work / "outside").mkdir()
        self.agents = work / "LaunchAgents"
        self.agents.mkdir()
        self.pids = []
        self.executable = self.app / "Contents/MacOS/DemoApp"
        shutil.copy(fixture, self.executable)
        shutil.copy(fixture, work / "outside/svc")
        if identity:
            with (self.app / "Contents/Info.plist").open("wb") as handle:
                plistlib.dump({"CFBundleIdentifier": BUNDLE_ID, "CFBundleExecutable": "DemoApp",
                               "CFBundleShortVersionString": "1.0.0"}, handle, fmt=plistlib.FMT_XML)

    def helper(self, name: str) -> Path:
        path = self.app / "Contents/Helpers" / name
        shutil.copy(self.fixture, path)
        return path

    def job(self, label: str, program: Path, **policy) -> str:
        """One saved per-user job, the way launchd would find it."""
        spec = {"Label": label, "Program": str(program)}
        spec.update(policy)
        with (self.agents / (label + ".plist")).open("wb") as handle:
            plistlib.dump(spec, handle, fmt=plistlib.FMT_XML)
        return label

    def start(self, program: Path) -> int:
        pidfile = self.work / ("pid-%d" % len(self.pids))
        subprocess.run([str(program), str(pidfile)], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=True)
        pid = int(pidfile.read_text())
        self.pids.append(pid)
        return pid

    def drive(self, mode: str, rows=(), quit_wait=10, stopped_status=0, gui=None) -> str:
        argv = [str(self.check), mode, str(self.app), str(self.agents),
                str(quit_wait), str(stopped_status)]
        if gui is not None:
            argv.append("gui=%d" % gui)
        result = subprocess.run(argv + list(rows), capture_output=True, text=True, timeout=300)
        if result.returncode != 0:
            raise AssertionError(mode + ":\n" + result.stdout + result.stderr)
        if "PASS " + mode not in result.stdout:
            raise AssertionError(mode + ": no verdict\n" + result.stdout)
        for line in result.stdout.splitlines():
            if line.startswith("RESTORED "):
                self.pids.append(int(line.split()[1]))
        return result.stdout

    def stop_all(self):
        """Cleanup is SIGTERM only, and it has to work: a fixture that survived it is a loud failure."""
        for pid in self.pids:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.time() + 15
        while time.time() < deadline and any(alive(pid) for pid in self.pids):
            time.sleep(0.1)
        left = [pid for pid in self.pids if alive(pid)]
        if left:
            raise AssertionError("fixture processes ignored SIGTERM: %s" % left)


class AppServiceRecipeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = scratch("build")
        fixture_c = cls.build / "fixture.c"
        fixture_c.write_text(FIXTURE_C)
        cls.fixture = cls.build / "fixture"
        built = subprocess.run(["cc", "-o", str(cls.fixture), str(fixture_c)],
                               capture_output=True, text=True)
        assert built.returncode == 0, built.stderr
        recipes = RECIPES.read_text()
        live = top_block(recipes, "public enum LiveControl {")
        method = re.search(r"static func (serviceProcesses)\(", live)
        assert method, "LiveControl has no `static func serviceProcesses` helper to test"
        core = ("import Foundation\n#if canImport(Darwin)\nimport Darwin\n#endif\n" + STUBS
                + strip_imports(SHELL_SWIFT.read_text())
                + top_block(recipes, "public struct ServiceResume")
                + top_block(recipes, "public struct AppControl")
                + top_block(recipes, "public struct BundleInfo")
                + live
                + top_block(SUPPORT, "public struct KHUError")
                + top_block(SUPPORT, "public func khuFail")
                + top_block(SUPPORT, "public enum RealPath")
                + top_block(SUPPORT, "public enum Mono")
                + top_block(SUPPORT, "public enum ISO")
                + top_block(SUPPORT, "public enum Trash")
                + top_block(CONFIG, "public enum ReportPolicy"))
        (cls.build / "core.swift").write_text(core)
        harness = HARNESS.replace("SERVICE_METHOD", method.group(1))
        harness = harness.replace("STOP_BLOCK", stop_block(recipes))
        (cls.build / "main.swift").write_text(harness)
        cls.check = cls.build / "app-services-check"
        compiled = subprocess.run(["swiftc", str(cls.build / "core.swift"),
                                   str(cls.build / "main.swift"), "-o", str(cls.check)],
                                  capture_output=True, text=True)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr

    @classmethod
    def tearDownClass(cls):
        cls._trash(cls.build)

    def setUp(self):
        self.work = scratch("run")
        self.bundles = []

    def tearDown(self):
        for bundle in self.bundles:
            bundle.stop_all()
        type(self)._trash(self.work)

    @staticmethod
    def _trash(directory: Path):
        trash = REPO / "_trash" / "test-tmp"
        trash.mkdir(parents=True, exist_ok=True)
        directory.rename(trash / (directory.name + "." + uuid.uuid4().hex))

    def bundle(self, identity=True) -> Bundle:
        made = Bundle(self.check, self.fixture, self.work / ("b%d" % len(self.bundles)), identity)
        self.bundles.append(made)
        return made

    # --- the fix: a desktop app whose own host outlives it ---------------------------------

    def test_graceful_quit_leaves_the_owned_host_then_stop_terminates_it(self):
        bundle = self.bundle()
        service, second = bundle.helper("demosvc"), bundle.helper("demosvc2")
        bundle.job("com.example.demosvc", service, **GRACEFUL)
        bundle.job("com.example.demosvc2", second, **GRACEFUL)
        gui = bundle.start(bundle.executable)
        one, two = bundle.start(service), bundle.start(second)
        bundle.drive("owned", ["com.example.demosvc=%d" % one, "com.example.demosvc2=%d" % two],
                     quit_wait=20, gui=gui)
        for pid in (gui, one, two):
            self.assertFalse(alive(pid), "the quit and the two SIGTERMs must leave nothing up")

    def test_rebuilt_control_restores_the_saved_label_then_reads_healthy(self):
        bundle = self.bundle()
        service = bundle.helper("demosvc")
        label = bundle.job("com.example.demosvc", service, **GRACEFUL)
        gui = bundle.start(bundle.executable)
        host = bundle.start(service)
        out = bundle.drive("recovered", ["%s=%d" % (label, host)], quit_wait=20, gui=gui)
        started = [int(line.split()[1]) for line in out.splitlines() if line.startswith("RESTORED ")]
        self.assertEqual(len(started), 1, "the one saved job must be started exactly once")
        self.assertTrue(alive(started[0]), "the restored host must be running again on this Mac")

    # --- the recipe's own stop phase -------------------------------------------------------

    def test_the_stop_phase_reopens_a_quit_app_whose_service_refused(self):
        for mode in ("caller-partial", "caller-refused", "caller-dead"):
            bundle = self.bundle()
            bundle.drive(mode, quit_wait=1)

    # --- the refusals ----------------------------------------------------------------------

    def test_every_unclaimable_job_is_a_blocker_and_never_a_target(self):
        bundle = self.bundle()
        keep, keepsuccess, plain, keepfalse = (bundle.helper(n) for n in
                                               ("keep", "keepsuccess", "plain", "keepfalse"))
        scheduled, socketed, idle, ghost = (bundle.helper(n) for n in ("sched", "sock", "idle", "evil"))
        desktop, outside = bundle.executable, bundle.work / "outside/svc"
        pids = {name: bundle.start(prog) for name, prog in
                (("keep", keep), ("keepsuccess", keepsuccess), ("plain", plain),
                 ("keepfalse", keepfalse), ("sched", scheduled), ("sock", socketed),
                 ("desk", desktop), ("evil", ghost))}
        pids["outside"] = bundle.start(outside)
        bundle.job("com.example.nokeepalive", plain)                       # no stated restart rule
        bundle.job("com.example.keeptrue", keep, KeepAlive=True)            # launchd restarts it
        bundle.job("com.example.keepfalse", keepfalse, KeepAlive=False)     # crash-only rule
        bundle.job("com.example.keepsuccess", keepsuccess,
                   KeepAlive={"SuccessfulExit": True})
        bundle.job("com.example.scheduled", scheduled, StartInterval=60, **GRACEFUL)
        bundle.job("com.example.socketed", socketed, **GRACEFUL,
                   Sockets={"ListenerSocket": {"SockServiceName": "https"}})
        bundle.job("com.example.desktop", desktop, **GRACEFUL)
        bundle.job("com.example.outside", outside, **GRACEFUL)
        bundle.job("com.example.reused", idle, **GRACEFUL)                  # PID runs something else
        bundle.job("evil;rm -rf", ghost, **GRACEFUL)                        # never an identifier
        bundle.job("com.example.idle", idle, **GRACEFUL)                    # saved, loaded, not up
        rows = ["!com.example.nokeepalive=%d" % pids["plain"],
                # Since 0.1.36 an unconditional keep-alive job is claimed: it is stopped by
                # launchctl bootout (never a signal) and put back with bootstrap.
                "com.example.keeptrue=%d" % pids["keep"],
                "!com.example.keepfalse=%d" % pids["keepfalse"],
                "!com.example.keepsuccess=%d" % pids["keepsuccess"],
                "!com.example.scheduled=%d" % pids["sched"],
                "!com.example.socketed=%d" % pids["sock"],
                "!com.example.desktop=%d" % pids["desk"],
                "!com.example.outside=%d" % pids["outside"],
                "!com.example.reused=%d" % pids["outside"],
                "!evil;rm -rf=%d" % pids["evil"],
                "com.example.idle=-1"]
        bundle.drive("refuse", rows, quit_wait=1)
        self.assertTrue(alive(pids["plain"]), "a plain job without the graceful rule stays untouched")

    def test_a_bundle_without_identity_can_have_no_service(self):
        bundle = self.bundle(identity=False)
        service = bundle.helper("demosvc")
        bundle.job("com.example.demosvc", service, **GRACEFUL)
        pid = bundle.start(service)
        bundle.drive("noidentity", ["!com.example.demosvc=%d" % pid], quit_wait=1)
        self.assertTrue(alive(pid), "a bundle with no identity must never be signalled")

    def test_one_unknown_process_refuses_the_stop_for_the_owned_service(self):
        bundle = self.bundle()
        service, ghost = bundle.helper("demosvc"), bundle.helper("ghost")
        bundle.job("com.example.demosvc", service, **GRACEFUL)
        pid, extra = bundle.start(service), bundle.start(ghost)
        bundle.drive("unknown", ["com.example.demosvc=%d" % pid], quit_wait=1)
        for live in (pid, extra):
            self.assertTrue(alive(live), "a refused stop must signal nothing at all")

    def test_a_job_that_vanishes_between_claim_and_signal_is_never_signalled(self):
        bundle = self.bundle()
        service = bundle.helper("demosvc")
        bundle.job("com.example.demosvc", service, **GRACEFUL)
        pid = bundle.start(service)
        bundle.drive("stale", ["com.example.demosvc=%d" % pid], quit_wait=1)
        self.assertTrue(alive(pid), "the old job PID must have been left alone, not killed")

    def test_a_service_launchd_reports_as_signal_killed_is_not_stopped(self):
        bundle = self.bundle()
        service = bundle.helper("demosvc")
        bundle.job("com.example.demosvc", service, **GRACEFUL)
        pid = bundle.start(service)
        bundle.drive("signalexit", ["com.example.demosvc=%d" % pid], quit_wait=5,
                     stopped_status=15)
        self.assertFalse(alive(pid), "the owned service was SIGTERMned; only its exit status refuses")


if __name__ == "__main__":
    unittest.main()
