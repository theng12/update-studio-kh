import Foundation
#if canImport(Darwin)
import Darwin
import Darwin.Mach
#endif

/// TR1: the shipped client gives a session back after every transfer, on the path that succeeds.
///
/// 0.1.55 fixed the cancelled/deadline path (`invalidateAndCancel`), and the ten-minute idle suite
/// (`Tests/test_agent_idle_leak.py`) measures the agent between cycles — but neither exercises a
/// real download that *finishes*. This pins the second.
///
/// Mach ports are the metric the leak was reported in (16,904 on an idle 0.1.54 agent), and they are
/// readable from inside the process without special rights. Measured 2026-11-17 on this Mac: the
/// HTTP stack itself costs about one port and ~30-50 KB per completed task, whatever the session
/// lifetime or invalidation mode, so the guard below allows that cost and fails on anything that
/// grows faster — a session or delegate that outlives its transfer costs several ports each.
private func leakSnapshot() -> (fds: Int, threads: Int, ports: Int) {
    // `/dev/fd` lists this process's open descriptors without spawning anything.
    let fds = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-M", "-p", String(getpid())]
    let pipe = Pipe()
    ps.standardOutput = pipe
    ps.standardError = FileHandle.nullDevice
    guard (try? ps.run()) != nil else { return (fds, -1, portNames()) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    ps.waitUntilExit()
    // One header line, then one line per thread.
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").count
    return (fds, max(0, lines - 1), portNames())
}

/// This process's Mach port names. Our own task needs no `task_for_pid`, so the count the leak was
/// reported in is readable here even though `lsmp` refuses an outside process.
private func portNames() -> Int {
    var names: mach_port_name_array_t?
    var count: mach_msg_type_number_t = 0
    var types: mach_port_type_array_t?
    var typeCount: mach_msg_type_number_t = 0
    guard mach_port_names(mach_task_self_, &names, &count, &types, &typeCount) == KERN_SUCCESS,
          let names else { return -1 }
    _ = vm_deallocate(mach_task_self_, vm_address_t(bitPattern: names),
                      vm_size_t(count) * vm_size_t(MemoryLayout<mach_port_name_t>.stride))
    if let types {
        _ = vm_deallocate(mach_task_self_, vm_address_t(bitPattern: types),
                          vm_size_t(typeCount) * vm_size_t(MemoryLayout<mach_port_type_t>.stride))
    }
    return Int(count)
}

func transferLeakTests() {
    guard let server = LoopbackHTTPServer() else {
        expect(false, "TR1 the loopback fixture could not listen")
        return
    }
    let payload = Data(repeating: 0x41, count: 64 * 1024)
    server.handler = { _, _ in payload }
    Thread { server.serve() }.start()
    defer { server.stop() }
    let base = URL(string: "http://127.0.0.1:\(server.port)")!
    let client = URLSessionHTTPClient()

    // One transfer first, so the settling threads of a cold client are not counted as a leak.
    _ = try? client.get(base.appendingPathComponent("warm"), headers: [:])
    Thread.sleep(forTimeInterval: 2)
    let before = leakSnapshot()

    let files = tmpDir("transfer-leak")
    for i in 0..<25 {
        _ = try? client.get(base.appendingPathComponent("feed\(i).json"), headers: [:])
        _ = try? client.download(base.appendingPathComponent("artifact\(i)"), headers: [:],
                                 to: files.appendingPathComponent("artifact\(i)"), limit: 1 << 20)
    }
    // `finishTasksAndInvalidate` releases on the session's own queue; give it its moment to do so.
    Thread.sleep(forTimeInterval: 3)
    let after = leakSnapshot()

    expect(server.seen.count == 51, "TR1 all 51 transfers reached the socket (\(server.seen.count))")
    expect(after.fds <= before.fds + 4,
           "TR1 50 transfers do not leak descriptors (\(before.fds) -> \(after.fds))")
    expect(after.threads <= before.threads + 3,
           "TR1 50 transfers do not leak threads (\(before.threads) -> \(after.threads))")
    // The platform's own per-task cost is ~1; a session kept alive is several per transfer.
    let portGrowth = after.ports - before.ports
    expect(portGrowth <= 60,
           "TR1 50 transfers do not leak Mach ports beyond the stack's own cost (\(before.ports) -> \(after.ports), +\(portGrowth))")
}
