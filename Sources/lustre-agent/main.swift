import Foundation
import Darwin
import LustreAgent
import LustreCore

@main
struct LustreAgentMain {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "install" {
                try install(arguments: arguments)
                return
            }
            try AgentPaths.prepare()
            let service = try AgentService()
            let cloudPresence = CloudPresenceConnection(service: service)
            await cloudPresence.startIfEnrolled()
            if let token = try? KeychainTokenStore.token() {
                let server = try LoopbackServer(service: service, token: token)
                let port = try await server.start()
                guard port != 0 else { throw AgentLaunchError.noPort }
                let endpoint = try JSONEncoder().encode(AgentEndpoint(port: port))
                try endpoint.write(to: AgentPaths.endpoint, options: .atomic)
                print("Lustre Agent listening at http://127.0.0.1:\(port)")
                print("Open that address in a browser, then use `lustre token` to authenticate the panel.")
            } else {
                fputs("Lustre Agent loopback listener is unavailable until Keychain access is authorized.\n", stderr)
            }
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        } catch {
            fputs("lustre-agent: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func install(arguments: [String]) throws {
        guard arguments.count == 2, arguments[1].hasPrefix("/") else { throw AgentLaunchError.installUsage }
        let executable = URL(fileURLWithPath: arguments[1])
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw AgentLaunchError.invalidExecutable }
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appending(path: "LaunchAgents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plist = directory.appending(path: "com.pmvdl.lustre-agent.plist")
        let logs = AgentPaths.applicationSupport.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let configuration: [String: Any] = [
            "Label": "com.pmvdl.lustre-agent",
            "ProgramArguments": [executable.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "StandardOutPath": logs.appending(path: "agent.log").path,
            "StandardErrorPath": logs.appending(path: "agent-error.log").path
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: configuration, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        print("Created \(plist.path)")
        print("Load it with: launchctl bootstrap gui/$(id -u) \(plist.path)")
    }
}

private enum AgentLaunchError: Error, LocalizedError {
    case noPort
    case installUsage
    case invalidExecutable
    var errorDescription: String? {
        switch self {
        case .noPort: "The loopback listener did not receive a port."
        case .installUsage: "Usage: lustre-agent install </absolute/path/to/lustre-agent>"
        case .invalidExecutable: "The LaunchAgent executable path is not executable."
        }
    }
}
