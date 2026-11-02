import Foundation
import CryptoKit

@main
struct KHUMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        func usage() -> Never {
            FileHandle.standardError.write(Data("""
            khu <subcommand> ...
              keygen <dir>
              publish --feed <dir> --key <keyfile> --app <id> --version <v> --artifact <path> --changelog <repo or CHANGELOG.md> [--note "<one extra line>"] [--kind <k>] [--name <shown name>] [--tagline <t>] [--description <d>] [--feature "Title|text"]... [--accent #hex] [--main-mac-only] [--allow-same]
              enrol --state <dir> --machine <id>
              enrol-window --state <dir> --minutes <n>   (0 closes; 1...240 opens)
              remove --state <dir> --machine <id>
              serve --feed <dir> --state <dir> --key <keyfile> --bind <ip> --port <p>
              agent --config <file> [--once]
              rename-machine --state <dir> --from <device-id> --to <label>
              ssd-index --volume <path> [--feed <dir>] [--changelog <id>=<repo or CHANGELOG.md>]...   (writes <path>/apps.json)
              connect --kit <dir> --machine <id> --code <pairing code>
            """.utf8))
            exit(64)
        }
        /// The value of the flag at `index`, or `usage()`. A flag with nothing after it is a usage
        /// error: reading past the end of the line is a crash, not a diagnosis.
        func value(_ flag: String, _ index: inout Int) -> String {
            index += 1
            guard index < args.count else {
                FileHandle.standardError.write(Data("error: \(flag) needs a value\n".utf8))
                usage()
            }
            return args[index]
        }
        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("error: \(message)\n".utf8))
            exit(1)
        }
        // Opened as Studio Launcher KH.app: show the helper's window, or set the helper up first.
        if args.isEmpty, Bundle.main.bundlePath.hasSuffix(".app") { FrontDoor.run() }
        if args.first == "notify", args.count == 3, Bundle.main.bundlePath.hasSuffix(".app") { Notifier.post(title: args[1], body: args[2]) }
        if args.isEmpty { usage() }
        switch args[0] {
        case "keygen":
            guard args.count >= 2 else { usage() }
            let dir = URL(fileURLWithPath: args[1])
            let keyFile = dir.appendingPathComponent("private.key")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                // The file is created exclusively (`O_CREAT|O_EXCL`, then published by `link`), and
                // the key is printed only when it was created: the public key on screen is always
                // the public half of the private key that is stored, even if two keygens run at once.
                let key = Signing.generateKeyPair()
                try Signing.savePrivateKey(key.privateKey, to: keyFile)
                print("public key: \(key.publicKeyBase64)")
                print("private key: \(keyFile.path)")
            } catch { fail("\(error)") }
        case "publish":
            var feed: String?, key: String?, app: String?, version: String?, artifact: String?, kind: String?, changelog: String?, extra: String?, shown: String?, allowSame = false
            var words = AppWords(), wordsGiven = false, mainOnly: Bool? = nil
            var i = 1
            while i < args.count {
                switch args[i] {
                case "--feed": feed = value("--feed", &i)
                case "--key": key = value("--key", &i)
                case "--app": app = value("--app", &i)
                case "--version": version = value("--version", &i)
                case "--artifact": artifact = value("--artifact", &i)
                case "--kind": kind = value("--kind", &i)
                case "--changelog": changelog = value("--changelog", &i)
                case "--note": extra = value("--note", &i)
                case "--notes": fail("--notes is gone: the notes come from --changelog, plus one optional --note line")
                case "--allow-same": allowSame = true
                case "--name": shown = value("--name", &i)
                case "--main-mac-only": mainOnly = true
                case "--tagline": words.tagline = value("--tagline", &i); wordsGiven = true
                case "--description": words.description = value("--description", &i); wordsGiven = true
                case "--accent": words.accent = value("--accent", &i); wordsGiven = true
                case "--feature":
                    let parts = value("--feature", &i).split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    words.features = (words.features ?? []) + [AppFeature(title: parts[0], text: parts.count > 1 ? parts[1] : nil)]; wordsGiven = true
                default: usage()
                }
                i += 1
            }
            guard let f = feed, let k = key, let a = app, let v = version, let art = artifact else { usage() }
            guard let changelog else { fail("publish needs --changelog <repo or CHANGELOG.md>: the notes come from its top entry") }
            do {
                let notes = try ReleaseNotes.forRelease(changelog: URL(fileURLWithPath: changelog), version: v, extra: extra)
                try FeedPublisher.publish(feedDir: URL(fileURLWithPath: f), keyFile: URL(fileURLWithPath: k), app: a,
                                          version: v, artifact: URL(fileURLWithPath: art), kind: kind, allowSame: allowSame,
                                          notes: notes, displayName: shown, words: wordsGiven ? words : nil, mainMacOnly: mainOnly)
                print("published \(a) \(v)")
            } catch { fail("\(error)") }
        case "enrol":
            var state: String?, machine: String?
            var i = 1
            while i < args.count {
                switch args[i] {
                case "--state": state = value("--state", &i)
                case "--machine": machine = value("--machine", &i)
                default: usage()
                }
                i += 1
            }
            guard let s = state, let m = machine else { usage() }
            do { print(try Enrolment.enrol(stateDir: URL(fileURLWithPath: s), machine: m)) }
            catch { fail("\(error)") }
        case "enrol-window":
            var state: String?, minutes: String?
            var i = 1
            while i < args.count {
                switch args[i] {
                case "--state": state = value("--state", &i)
                case "--minutes": minutes = value("--minutes", &i)
                default: usage()
                }
                i += 1
            }
            guard let s = state, let m = minutes else { usage() }
            guard let n = Int(m), n == 0 || (1...EnrolPolicy.maxMinutes).contains(n) else {
                FileHandle.standardError.write(Data("error: --minutes must be 0 to close the enrolment window, or 1 to \(EnrolPolicy.maxMinutes) to open one, not \(m)\n".utf8))
                exit(2)
            }
            do {
                let dir = URL(fileURLWithPath: s)
                if n == 0 {
                    try EnrolmentWindow.close(stateDir: dir)
                    print("network enrolment is closed")
                } else {
                    let window = try EnrolmentWindow.open(stateDir: dir, minutes: n)
                    print("network enrolment is open for \(n) minutes, until \(window.until)")
                }
            } catch { fail("\(error)") }
        case "rename-machine":
            guard args.count == 7, args[1] == "--state", args[3] == "--from", args[5] == "--to" else { usage() }
            do {
                try Enrolment.rename(stateDir: URL(fileURLWithPath: args[2]), machine: args[4], to: args[6])
                print("renamed \(args[4]) to \(args[6]); its token is unchanged")
            } catch { fail("\(error)") }
        case "ssd-index":
            var volume: String?, feedDir: String?, changelogs: [String: URL] = [:]
            var i = 1
            while i < args.count {
                switch args[i] {
                case "--volume": volume = value("--volume", &i)
                case "--feed": feedDir = value("--feed", &i)
                case "--changelog":
                    let parts = value("--changelog", &i).split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { usage() }
                    changelogs[parts[0]] = URL(fileURLWithPath: parts[1])
                default: usage()
                }
                i += 1
            }
            guard let volume else { usage() }
            do {
                let feed = feedDir.flatMap { FeedPublisher.loadFeed(from: URL(fileURLWithPath: $0)) }
                let index = try SSDIndexer.index(volume: URL(fileURLWithPath: volume), feed: feed, changelogs: changelogs)
                for app in index.apps {
                    let lines = app.notes?.split(separator: "\n").count ?? 0
                    print("\(app.id) \(app.version) \(app.updatesItself ? "updates itself" : (app.file ?? "-")) · \(lines == 0 ? "NO NOTES" : "\(lines) note lines")")
                }
            } catch { fail("\(error)") }
        case "launcher-bundle":
            // Packaging: Studio Launcher KH.app around this binary, with the setup kit inside.
            guard args.count == 7, args[1] == "--out", args[3] == "--version", args[5] == "--kit" else { usage() }
            do {
                let out = URL(fileURLWithPath: args[2])
                try LauncherBundle.write(bundle: out, executable: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath(), version: args[4])
                try FileManager.default.copyItem(at: URL(fileURLWithPath: args[6]), to: out.appendingPathComponent("Contents/Resources/khu-agent"))
                print("wrote \(out.path)")
            } catch { fail("\(error)") }
        case "connect":
            var kit: String?, machine: String?, code: String?
            var i = 1
            while i < args.count {
                switch args[i] {
                case "--kit": kit = value("--kit", &i)
                case "--machine": machine = value("--machine", &i)
                case "--code": code = value("--code", &i)
                default: usage()
                }
                i += 1
            }
            guard let kit, let machine, let code else { usage() }
            do { print(try Connect.run(kit: URL(fileURLWithPath: kit), home: FileManager.default.homeDirectoryForCurrentUser, machine: machine, code: code)) }
            catch { fail("\(error)") }
        case "remove":
            var state: String?, machine: String?
            var i = 1
            while i < args.count {
                switch args[i] {
                case "--state": state = value("--state", &i)
                case "--machine": machine = value("--machine", &i)
                default: usage()
                }
                i += 1
            }
            guard let s = state, let m = machine else { usage() }
            do {
                let removal = try Enrolment.remove(stateDir: URL(fileURLWithPath: s), machine: m)
                print("removed \(removal.machine): its token and \(removal.droppedOrders.count) waiting order(s) are gone; it is kept in the removed list, and enrols again through an open window or `khu enrol`")
            } catch { fail("\(error)") }
        case "serve":
            var feed: String?, state: String?, key: String?, binds: [String] = [], port: Int = 8790
            var i = 1
            while i < args.count {
                switch args[i] {
                case "--feed": feed = value("--feed", &i)
                case "--state": state = value("--state", &i)
                case "--key": key = value("--key", &i)
                case "--bind": binds.append(value("--bind", &i))  // repeatable: loopback for the owner, the Tailscale IP for the Macs
                case "--port":
                    let text = value("--port", &i)
                    guard let number = Int(text), (1...65535).contains(number) else {
                        FileHandle.standardError.write(Data("error: --port must be a number from 1 to 65535, not \(text)\n".utf8))
                        exit(2)
                    }
                    port = number
                default: usage()
                }
                i += 1
            }
            guard let f = feed, let s = state else { usage() }
            // Orders are signed with this key, and the Macs refuse an unsigned or unverifiable one,
            // so a publisher without it can publish but never command.
            let commandKey: Curve25519.Signing.PrivateKey?
            do { commandKey = try key.map { try Signing.loadPrivateKey(from: URL(fileURLWithPath: $0)) } }
            catch { fail("\(error)") }
            if commandKey == nil {
                FileHandle.standardError.write(Data("warning: no --key given, so this publisher cannot sign orders and the Macs will refuse them\n".utf8))
            }
            do { try Enrolment.ensurePairingCode(stateDir: URL(fileURLWithPath: s)) }
            catch { FileHandle.standardError.write(Data("warning: no pairing code could be made, so new Macs cannot pair: \(error)\n".utf8)) }
            // Every address is bound before any is served, so a bad --bind fails the start.
            var servers: [(FeedServer, Int32)] = []
            for address in (binds.isEmpty ? ["127.0.0.1"] : binds) {
                let srv = FeedServer(feedDir: URL(fileURLWithPath: f), stateDir: URL(fileURLWithPath: s),
                                     bind: address, port: port, commandKey: commandKey)
                do { servers.append((srv, try srv.listen())) } catch { fail("\(error)") }
                print("serving on \(address):\(port)")
            }
            for (srv, fd) in servers {
                Thread { do { try srv.serve(on: fd) } catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) } }.start()
            }
            while true { Thread.sleep(forTimeInterval: 3600) }
        case "agent":
            var config: String?, once = false
            var i = 1
            while i < args.count {
                switch args[i] {
                case "--config": config = value("--config", &i)
                case "--once": once = true
                default: usage()
                }
                i += 1
            }
            guard let c = config else { usage() }
            let cfg: AgentConfig
            do {
                var loaded = try JSONDecoder().decode(AgentConfig.self, from: Data(contentsOf: URL(fileURLWithPath: c)))
                loaded.once = once || loaded.once
                cfg = loaded
            } catch { fail("cannot read the agent config \(c): \(error)") }
            // The stub rolls a fresh version back unless it hears from this very child within 2 minutes.
            // The beat runs on its own thread, so a long download or install never silences it.
            let mine = Agent.selfVersion(config: cfg)
            if let base = cfg.stubBase {
                let file = StubLayout(base: URL(fileURLWithPath: base)).heartbeatFile
                Thread {
                    while true {
                        do { try writeHeartbeat(to: file, at: Date(), version: mine, pid: getpid()) }
                        catch { FileHandle.standardError.write(Data("heartbeat not written: \(error)\n".utf8)) }
                        Thread.sleep(forTimeInterval: 30)
                    }
                }.start()
            }
            let menu = !cfg.once && HelperMenu.available ? HelperMenu(config: cfg, version: mine) : nil
            func loop() {
                var requested: Set<String> = []
                repeat {
                    do {
                        let r = try Agent.runOnce(config: cfg, requested: requested, installing: { menu?.installing($0) }, ssd: menu?.ssdSources ?? [])
                        print("agent run: posted=\(r.statusPosted) commands=\(r.commandsRun) updates=\(r.updates)")
                        for note in r.notes { print("note: \(note)") }
                        menu?.finished(r, error: nil)
                        if r.restartRequested { print("updater switched to a new version; exiting so the stub starts it"); exit(0) }
                    } catch {
                        FileHandle.standardError.write(Data("agent error: \(error)\n".utf8))
                        menu?.finished(nil, error: "\(error)")
                    }
                    if cfg.once { break }
                    let seconds = Double(max(1, cfg.intervalMinutes) * 60)
                    if let menu { requested = menu.waitForNextRun(seconds: seconds) } else { Thread.sleep(forTimeInterval: seconds) }
                } while true
            }
            // With a menu the main thread belongs to AppKit and the runs go on their own thread.
            if let menu { Thread { loop() }.start(); menu.start() } else { loop() }
        default:
            usage()
        }
    }
}
