import Foundation
import Darwin
import LustreCore

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
            let client = try AgentClient()
            switch command {
            case "status":
                let jobs = try await client.jobs()
                try printJSON(jobs)
            case "extract":
                guard arguments.count == 2, let url = URL(string: arguments[1]) else { throw CLIError.usage }
                let result = try await client.extract(url: url)
                try printJSON(result)
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
          lustre extract <url>
          lustre queue <url> [--quality <label>] [--destination <name>]
          lustre pause|resume|cancel|retry <job-id>
        """
    }
}
