import Foundation
import LustreCore

public enum DeviceEnrollmentStore {
    private static var url: URL { AgentPaths.applicationSupport.appending(path: "cloud-enrollment.json") }
    public static func load() throws -> CloudEnrollmentMetadata? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder.cloud.decode(CloudEnrollmentMetadata.self, from: Data(contentsOf: url))
    }
    public static func save(_ metadata: CloudEnrollmentMetadata) throws { try AgentPaths.prepare(); try JSONEncoder.cloud.encode(metadata).write(to: url, options: .atomic) }
    public static func disconnect() throws { guard FileManager.default.fileExists(atPath: url.path) else { return }; try FileManager.default.removeItem(at: url) }
}

extension JSONDecoder {
    static let cloud: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO-8601 timestamp.") }
            return date
        }
        return decoder
    }()
}
extension JSONEncoder { static let cloud: JSONEncoder = { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }() }
