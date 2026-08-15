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
            let browserCapture = AllPornStreamCaptureCoordinator()
            try await browserCapture.start()
            let pornHubCookieStore = KeychainPornHubCookieStore()
            let pornHubAuth = PornHubAuthService(
                store: pornHubCookieStore,
                helper: BrowserPornHubAuthHelper(capture: browserCapture, store: pornHubCookieStore)
            )
            let service = try AgentService(
                pornHubAuth: pornHubAuth,
                allPornStreamCapture: browserCapture,
                allPornStreamHTML: { url in try await browserCapture.capturePost(url: url) }
            )
            let cloudPresence = CloudPresenceConnection(service: service)
            let loopbackServer: LoopbackServer?
            if let token = try? KeychainTokenStore.token() {
                let server = try LoopbackServer(service: service, token: token)
                let port = try await server.start()
                guard port != 0 else { throw AgentLaunchError.noPort }
                let endpoint = try JSONEncoder().encode(AgentEndpoint(port: port))
                try endpoint.write(to: AgentPaths.endpoint, options: .atomic)
                print("Lustre Agent listening at http://127.0.0.1:\(port)")
                print("Open that address in a browser, then use `lustre token` to authenticate the panel.")
                loopbackServer = server
            } else {
                fputs("Lustre Agent loopback listener is unavailable until Keychain access is authorized.\n", stderr)
                loopbackServer = nil
            }
            defer { loopbackServer?.cancel() }
            defer { Task { await browserCapture.stop() } }
            Task { await cloudPresence.startIfEnrolled() }
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        } catch {
            fputs("lustre-agent: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func install(arguments: [String]) throws {
        guard arguments.count == 2, arguments[1].hasPrefix("/") else { throw AgentLaunchError.installUsage }
        let executable = URL(fileURLWithPath: arguments[1]).resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw AgentLaunchError.invalidExecutable }
        let runtimeDirectory = executable.deletingLastPathComponent()
        for companion in ["lustre-auth-helper", "lustre-browser-bridge"] {
            guard FileManager.default.isExecutableFile(atPath: runtimeDirectory.appending(path: companion).path) else {
                throw AgentLaunchError.missingCompanion(companion)
            }
        }
        guard FileManager.default.fileExists(atPath: runtimeDirectory.appending(path: "LustreAgent_LustreAgent.bundle").path) else {
            throw AgentLaunchError.missingResources
        }
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
        if executable.path.hasPrefix("/Volumes/") {
            print("External runtime: the containing volume must be mounted at this exact path before login.")
        }
        print("Load it with: launchctl bootstrap gui/$(id -u) \(plist.path)")
    }
}

private enum AgentLaunchError: Error, LocalizedError {
    case noPort
    case installUsage
    case invalidExecutable
    case missingCompanion(String)
    case missingResources
    var errorDescription: String? {
        switch self {
        case .noPort: "The loopback listener did not receive a port."
        case .installUsage: "Usage: lustre-agent install </absolute/path/to/lustre-agent>"
        case .invalidExecutable: "The LaunchAgent executable path is not executable."
        case .missingCompanion(let name): "The release runtime is incomplete: \(name) must be executable beside lustre-agent."
        case .missingResources: "The release runtime is incomplete: LustreAgent_LustreAgent.bundle must be beside lustre-agent."
        }
    }
}
