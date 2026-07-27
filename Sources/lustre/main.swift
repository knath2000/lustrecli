import Foundation
import Darwin
import LustreCore
import LustreAgent

@main
struct LustreCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else { throw CLIError.usage }
            if command == "token" {
                print(try KeychainTokenStore.token())
                return
            }
            if command == "cloud" {
                try await cloud(arguments: Array(arguments.dropFirst()))
                return
            }
            let client = try AgentClient()
            switch command {
            case "status":
                let jobs = try await client.jobs()
                try printJSON(jobs)
            case "auth":
                guard arguments.count == 2 else { throw CLIError.usage }
                switch arguments[1] {
                case "status": try printJSON(try await client.pornHubAuthStatus())
                case "login": try printJSON(try await client.signInWithPornHub())
                case "logout": try printJSON(try await client.signOutOfPornHub())
                default: throw CLIError.usage
                }
            case "extract":
                guard arguments.count == 2, let url = URL(string: arguments[1]) else { throw CLIError.usage }
                let result = try await client.extract(url: url)
                try printJSON(result)
            case "feed":
                guard arguments.count >= 2 else { throw CLIError.usage }
                if arguments[1] == "sites" {
                    try printJSON(try await client.feedSites())
                } else if arguments[1] == "verify",
                          option("--site", in: arguments) == FeedSiteID.allPornStream.rawValue {
                    try await client.verifyAllPornStream()
                    print("AllPornStream verification completed.")
                } else if arguments[1] == "list",
                          let rawSite = option("--site", in: arguments),
                          let site = FeedSiteID(rawValue: rawSite) {
                    let page = option("--page", in: arguments).flatMap(Int.init) ?? 1
                    try printJSON(try await client.feedPage(site: site, query: option("--query", in: arguments), page: page))
                } else {
                    throw CLIError.usage
                }
            case "queue":
                guard arguments.count >= 2, let url = URL(string: arguments[1]) else { throw CLIError.usage }
                let quality = option("--quality", in: arguments)
                let destination = option("--destination", in: arguments)
                let job = try await client.queue(CreateJobRequest(sourcePageURL: url, preferredQualityLabel: quality, destination: destination))
                try printJSON(job)
            case "pause", "resume", "cancel", "retry":
                guard arguments.count == 2, let id = UUID(uuidString: arguments[1]), let action = JobAction(rawValue: command) else { throw CLIError.usage }
                let job = try await client.apply(action, to: id)
                try printJSON(job)
            case "force-start":
                guard arguments.count == 2, let id = UUID(uuidString: arguments[1]) else { throw CLIError.usage }
                let job = try await client.apply(.forceStart, to: id)
                try printJSON(job)
            default:
                throw CLIError.usage
            }
        } catch {
            fputs("lustre: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func cloud(arguments: [String]) async throws {
        guard let command = arguments.first else { throw CLIError.usage }
        switch command {
        case "status":
            if let enrollment = try DeviceEnrollmentStore.load() { try printJSON(enrollment) } else { print("Disconnected from Lustre Cloud.") }
        case "disconnect":
            try DeviceEnrollmentStore.disconnect()
            print("Disconnected locally. This Mac remains enrolled until you revoke it in Lustre Cloud.")
        case "reset-identity":
            try DeviceEnrollmentStore.disconnect()
            try DeviceIdentity().reset()
            print("Reset this Mac's local Lustre Cloud identity. Existing cloud revocations remain in effect.")
        case "pair":
            guard arguments.count >= 2, let name = option("--name", in: arguments), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CLIError.usage }
            guard let rawOrigin = ProcessInfo.processInfo.environment[CloudDeviceProtocol.audienceEnvironment], let origin = URL(string: rawOrigin) else { throw CloudDeviceError.invalidOrigin }
            let identity = DeviceIdentity(); let client = try CloudEnrollmentClient(origin: origin)
            let challenge = try await client.beginEnrollment(code: arguments[1], publicKey: try identity.publicKey(), name: name, version: "0.1.0")
            let envelope = try CloudDeviceProtocol.envelope(purpose: "enrollment", audience: rawOrigin, subjectID: challenge.enrollmentID.uuidString.lowercased(), nonce: challenge.nonce, thumbprint: try identity.thumbprint(), expiresAt: challenge.expiresAt)
            let completed = try await client.completeEnrollment(id: challenge.enrollmentID, signature: try identity.sign(envelope))
            let enrollment = CloudEnrollmentMetadata(cloudOrigin: completed.cloudOrigin, deviceID: completed.deviceID, deviceName: name.trimmingCharacters(in: .whitespacesAndNewlines), enrolledAt: completed.enrolledAt)
            try DeviceEnrollmentStore.save(enrollment)
            print("Paired \(enrollment.deviceName) with Lustre Cloud as \(enrollment.deviceID.uuidString).")
        default: throw CLIError.usage
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}

private enum CLIError: Error, LocalizedError {
    case usage
    var errorDescription: String? {
        """
        Usage:
          lustre token
          lustre status
          lustre auth status|login|logout
          lustre cloud pair <code> --name <name>
          lustre cloud reset-identity
          lustre cloud status
          lustre cloud disconnect
          lustre extract <url>
          lustre feed sites
          lustre feed verify --site allpornstream
          lustre feed list --site allpornstream|hqporner|onlyfan420|pornhub [--query <text>] [--page <number>]
          lustre queue <url> [--quality <label>] [--destination <name>]
          lustre force-start <job-id>
          lustre pause|resume|cancel|retry <job-id>
        """
    }
}
