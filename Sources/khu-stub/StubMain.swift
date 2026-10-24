import Foundation

@main
struct KHUStubMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        func usage() -> Never {
            FileHandle.standardError.write(Data("""
            usage: khu-stub --base <dir> [-- <child args...>]

              --base <dir>   the version tree: versions/<v>/khu, current, previous, heartbeat.json
            """.utf8))
            exit(64)
        }
        var basePath: String?
        var childArguments: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--base":
                index += 1
                guard index < arguments.count else { usage() }
                basePath = arguments[index]
            case "--":
                childArguments = Array(arguments[(index + 1)...])
                index = arguments.count
                continue
            case "-h", "--help":
                usage()
            default:
                usage()
            }
            index += 1
        }
        if basePath == nil, let fromEnvironment = ProcessInfo.processInfo.environment["KHU_BASE"] {
            basePath = fromEnvironment
        }
        guard let basePath else { usage() }
        let base = URL(fileURLWithPath: basePath).standardizedFileURL
        let layout = StubLayout(base: base)
        let runner = StubRunner(layout: layout, childArguments: childArguments.isEmpty ? nil : childArguments)
        exit(runner.run())
    }
}
