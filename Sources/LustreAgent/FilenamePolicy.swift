import Foundation

enum FilenamePolicy {
    static let maximumFilenameUTF8Length = 180

    static func uniqueLocalURL(directory: URL, title: String?, mediaURL: URL) -> URL {
        let fileExtension = safeExtension(mediaURL.pathExtension, fallback: "mp4")
        return uniqueURL(directory: directory, base: sanitizedBase(title, fallback: "Lustre-video"), suffix: nil, fileExtension: fileExtension)
    }

    static func remoteFilename(title: String?, mediaURL: URL) -> String {
        let fileExtension = safeExtension(mediaURL.pathExtension, fallback: "mp4")
        return filename(base: sanitizedBase(title, fallback: "Lustre-video"), suffix: UUID().uuidString.prefix(8).lowercased(), fileExtension: fileExtension)
    }

    static func uniquePornHubURL(directory: URL, title: String?, source: URL, fileExtension: String) -> URL {
        let viewKey = PornHubURL.viewKey(source) ?? "pornhub"
        return uniqueURL(
            directory: directory,
            base: sanitizedBase(title, fallback: "Lustre-PornHub"),
            suffix: viewKey,
            fileExtension: safeExtension(fileExtension, fallback: "mp4")
        )
    }

    static func sanitizedBase(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let allowed = CharacterSet.alphanumerics
        let normalized = trimmed.unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
        let collapsed = normalized.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let result = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".- "))
        return result.isEmpty ? fallback : result
    }

    private static func uniqueURL(directory: URL, base: String, suffix: String?, fileExtension: String) -> URL {
        var index = 0
        while true {
            let collisionSuffix = index == 0 ? nil : String(index)
            let suffixParts = [suffix, collisionSuffix].compactMap { $0 }
            let candidate = directory.appendingPathComponent(filename(base: base, suffix: suffixParts.isEmpty ? nil : suffixParts.joined(separator: "-"), fileExtension: fileExtension))
            if !FileManager.default.fileExists(atPath: candidate.path) && !FileManager.default.fileExists(atPath: candidate.appendingPathExtension("part").path) {
                return candidate
            }
            index += 1
        }
    }

    private static func filename(base: String, suffix: String?, fileExtension: String) -> String {
        let suffixPart = suffix.map { "-\($0)" } ?? ""
        let maximumBaseBytes = max(1, maximumFilenameUTF8Length - suffixPart.lengthOfBytes(using: .utf8) - fileExtension.lengthOfBytes(using: .utf8) - 1)
        return "\(truncateUTF8(base, to: maximumBaseBytes))\(suffixPart).\(fileExtension)"
    }

    private static func truncateUTF8(_ value: String, to maximumBytes: Int) -> String {
        var result = ""
        for character in value {
            guard (result + String(character)).decomposedStringWithCanonicalMapping.lengthOfBytes(using: .utf8) <= maximumBytes else { break }
            result.append(character)
        }
        return result
    }

    private static func safeExtension(_ value: String, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let result = value.unicodeScalars.filter(allowed.contains).map(String.init).joined().lowercased()
        return result.isEmpty ? fallback : result
    }
}
