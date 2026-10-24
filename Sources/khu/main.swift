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
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let key = Signing.generateKeyPair()
            let keyFile = dir.appendingPathComponent("private.key")
            try? Signing.savePrivateKey(key.privateKey, to: keyFile)
            print("public key: \(key.publicKeyBase64)")
            print("private key: \(keyFile.path)")
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
            for address in (binds.isEmpty ? ["127.0.0.1"] : binds) {
                let srv = FeedServer(feedDir: URL(fileURLWithPath: f), stateDir: URL(fileURLWithPath: s), bind: address, port: port)
                Thread { do { try srv.serve() } catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) } }.start()
                print("serving on \(address):\(port)")
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
            // The stub rolls a fresh version back unless it hears a heartbeat within 2 minutes, so beat every 30 s.
            let heartbeat = cfg.stubBase.map { StubLayout(base: URL(fileURLWithPath: $0)).heartbeatFile }
            func beat() { if let h = heartbeat { try? writeHeartbeat(to: h, at: Date(), version: cfg.updaterVersion, pid: getpid()) } }
            repeat {
                beat()
                do {
                    let r = try Agent.runOnce(config: cfg, http: URLSessionHTTPClient(), shell: SystemShell())
                    print("agent run: posted=\(r.statusPosted) commands=\(r.commandsRun) updates=\(r.updates)")
                    if r.restartRequested { print("updater switched to a new version; exiting so the stub starts it"); exit(0) }
                } catch {
                    FileHandle.standardError.write(Data("agent error: \(error)\n".utf8))
                }
                if cfg.once { break }
                let until = Date().addingTimeInterval(Double(max(1, cfg.intervalMinutes) * 60))
                while Date() < until { beat(); Thread.sleep(forTimeInterval: 30) }
            } while true
        default:
            usage()
        }
    }
}
