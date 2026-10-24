import Foundation

@main
struct KHUMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        func usage() -> Never {
            FileHandle.standardError.write(Data("""
            khu <subcommand> ...
              keygen <dir>
              publish --feed <dir> --key <keyfile> --app <id> --version <v> --artifact <path> [--kind <k>] [--allow-same]
              enrol --state <dir> --machine <id>
              serve --feed <dir> --state <dir> --bind <ip> --port <p>
              agent --config <file> [--once]
            """.utf8))
            exit(64)
        }
        if args.isEmpty { usage() }
        switch args[0] {
        case "keygen":
            guard args.count >= 2 else { usage() }
            let dir = URL(fileURLWithPath: args[1])
            let keyFile = dir.appendingPathComponent("private.key")
            do {
                guard !FileManager.default.fileExists(atPath: keyFile.path) else {
                    throw khuFail("\(keyFile.path) already exists; a new key would orphan every agent pinned to the old one")
                }
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let key = Signing.generateKeyPair()
                try Signing.savePrivateKey(key.privateKey, to: keyFile)
                print("public key: \(key.publicKeyBase64)")
                print("private key: \(keyFile.path)")
            } catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }
        case "publish":
            var feed: String?, key: String?, app: String?, version: String?, artifact: String?, kind: String?, allowSame = false
            var i = 1
            while i < args.count {
                switch args[i] {
                case "--feed": i+=1; feed=args[i]
                case "--key": i+=1; key=args[i]
                case "--app": i+=1; app=args[i]
                case "--version": i+=1; version=args[i]
                case "--artifact": i+=1; artifact=args[i]
                case "--kind": i+=1; kind=args[i]
                case "--allow-same": allowSame=true
                default: usage()
                }
                i+=1
            }
            guard let f=feed, let k=key, let a=app, let v=version, let art=artifact else { usage() }
            do {
                try FeedPublisher.publish(feedDir: URL(fileURLWithPath: f), keyFile: URL(fileURLWithPath: k), app: a, version: v, artifact: URL(fileURLWithPath: art), kind: kind, allowSame: allowSame)
                print("published \(a) \(v)")
            } catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }
        case "enrol":
            var state: String?, machine: String?
            var i=1
            while i < args.count {
                switch args[i] {
                case "--state": i+=1; state=args[i]
                case "--machine": i+=1; machine=args[i]
                default: usage()
                }
                i+=1
            }
            guard let s=state, let m=machine else { usage() }
            do {
                let tok = try Enrolment.enrol(stateDir: URL(fileURLWithPath: s), machine: m)
                print(tok)
            } catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }
        case "serve":
            var feed: String?, state: String?, binds: [String] = [], port: Int = 8790
            var i=1
            while i < args.count {
                switch args[i] {
                case "--feed": i+=1; feed=args[i]
                case "--state": i+=1; state=args[i]
                case "--bind": i+=1; binds.append(args[i])  // repeatable: loopback for the owner, the Tailscale IP for the Macs
                case "--port": i+=1; port=Int(args[i]) ?? 8080
                default: usage()
                }
                i+=1
            }
            guard let f=feed, let s=state else { usage() }
            // Every address is bound before any is served, so a bad --bind fails the start.
            var servers: [(FeedServer, Int32)] = []
            for address in (binds.isEmpty ? ["127.0.0.1"] : binds) {
                let srv = FeedServer(feedDir: URL(fileURLWithPath: f), stateDir: URL(fileURLWithPath: s), bind: address, port: port)
                do { servers.append((srv, try srv.listen())) }
                catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }
                print("serving on \(address):\(port)")
            }
            for (srv, fd) in servers {
                Thread { do { try srv.serve(on: fd) } catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) } }.start()
            }
            while true { Thread.sleep(forTimeInterval: 3600) }
        case "agent":
            var config: String?, once = false
            var i=1
            while i < args.count {
                switch args[i] {
                case "--config": i+=1; config=args[i]
                case "--once": once=true
                default: usage()
                }
                i+=1
            }
            guard let c=config else { usage() }
            let cfg: AgentConfig
            do {
                var loaded = try JSONDecoder().decode(AgentConfig.self, from: Data(contentsOf: URL(fileURLWithPath: c)))
                loaded.once = once || loaded.once
                cfg = loaded
            } catch { FileHandle.standardError.write(Data("cannot read the agent config \(c): \(error)\n".utf8)); exit(1) }
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
            repeat {
                do {
                    let r = try Agent.runOnce(config: cfg)
                    print("agent run: posted=\(r.statusPosted) commands=\(r.commandsRun) updates=\(r.updates)")
                    for note in r.notes { print("note: \(note)") }
                    if r.restartRequested { print("updater switched to a new version; exiting so the stub starts it"); exit(0) }
                } catch {
                    FileHandle.standardError.write(Data("agent error: \(error)\n".utf8))
                }
                if cfg.once { break }
                Thread.sleep(forTimeInterval: Double(max(1, cfg.intervalMinutes) * 60))
            } while true
        default:
            usage()
        }
    }
}
