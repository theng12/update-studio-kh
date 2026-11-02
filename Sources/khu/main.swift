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
              publish --feed <dir> --key <keyfile> --app <id> --version <v> --artifact <path> [--kind <k>] [--notes "<line>\\n<line>"] [--allow-same]
              enrol --state <dir> --machine <id>
              enrol-window --state <dir> --minutes <n>   (0 closes; 1...240 opens)
              remove --state <dir> --machine <id>
              serve --feed <dir> --state <dir> --key <keyfile> --bind <ip> --port <p>
              agent --config <file> [--once]
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
            var feed: String?, key: String?, app: String?, version: String?, artifact: String?, kind: String?, notes: String?, allowSame = false
            var i = 1
            while i < args.count {
                switch args[i] {
                case "--feed": feed = value("--feed", &i)
                case "--key": key = value("--key", &i)
                case "--app": app = value("--app", &i)
                case "--version": version = value("--version", &i)
                case "--artifact": artifact = value("--artifact", &i)
                case "--kind": kind = value("--kind", &i)
                case "--notes": notes = value("--notes", &i)
                case "--allow-same": allowSame = true
                default: usage()
                }
                i += 1
            }
            guard let f = feed, let k = key, let a = app, let v = version, let art = artifact else { usage() }
            do {
                try FeedPublisher.publish(feedDir: URL(fileURLWithPath: f), keyFile: URL(fileURLWithPath: k), app: a,
                                          version: v, artifact: URL(fileURLWithPath: art), kind: kind, allowSame: allowSame,
                                          notes: notes.map { $0.replacingOccurrences(of: "\\n", with: "\n") })
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
                        let r = try Agent.runOnce(config: cfg, requested: requested, installing: { menu?.installing($0) })
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
