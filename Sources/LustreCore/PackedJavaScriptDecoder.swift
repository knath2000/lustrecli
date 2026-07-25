import Foundation

public enum PackedJavaScriptDecoder {
    public static func decodeFirst(in source: String) -> String? {
        decodeAll(in: source).first
    }

    public static func decodeAll(in source: String) -> [String] {
        var decoded: [String] = []
        var searchRange = source.startIndex..<source.endIndex
        while let evalRange = source.range(of: "eval(", options: [], range: searchRange) {
            let start = source.index(evalRange.lowerBound, offsetBy: "eval(".count)
            if let end = matchingParenthesis(in: source, from: start),
               let value = decode(String(source[start..<end])) {
                decoded.append(value)
            }
            searchRange = source.index(after: evalRange.lowerBound)..<source.endIndex
        }
        return decoded
    }

    private static func matchingParenthesis(in source: String, from start: String.Index) -> String.Index? {
        var depth = 1
        var quote: Character?
        var escaped = false
        var index = start
        while index < source.endIndex {
            let character = source[index]
            if let activeQuote = quote {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == activeQuote { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func decode(_ packed: String) -> String? {
        guard let function = packed.range(of: "function"),
              let bodyEnd = matchingBrace(in: packed, from: function.lowerBound) else {
            return nil
        }
        return parseArguments(String(packed[packed.index(after: bodyEnd)...]))
    }

    private static func matchingBrace(in source: String, from start: String.Index) -> String.Index? {
        guard let open = source[start...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var quote: Character?
        var escaped = false
        var index = open
        while index < source.endIndex {
            let character = source[index]
            if let activeQuote = quote {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == activeQuote { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func parseArguments(_ suffix: String) -> String? {
        guard let open = suffix.firstIndex(of: "("), let close = matchingParenthesis(in: suffix, from: suffix.index(after: open)) else {
            return nil
        }
        let parts = splitArguments(String(suffix[suffix.index(after: open)..<close]))
        guard parts.count >= 4,
              let payload = stringLiteral(parts[0]),
              let radix = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
              let count = Int(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)),
              radix >= 2, radix <= 62, count >= 0,
              let dictionary = stringLiteral(parts[3]) else {
            return nil
        }
        return unpack(payload: decodeEscapes(payload), radix: radix, count: count, dictionary: dictionary)
    }

    private static func splitArguments(_ source: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in source {
            if let activeQuote = quote {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == activeQuote { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "(" { depth += 1 }
            else if character == ")" { depth -= 1 }
            else if character == ",", depth == 0 {
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        parts.append(current)
        return parts
    }

    private static func stringLiteral(_ source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quote = trimmed.first, quote == "'" || quote == "\"" else { return nil }
        var escaped = false
        var index = trimmed.index(after: trimmed.startIndex)
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == quote { return String(trimmed[trimmed.index(after: trimmed.startIndex)..<index]) }
            index = trimmed.index(after: index)
        }
        return nil
    }

    private static func decodeEscapes(_ source: String) -> String {
        source
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\'", with: "'")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func unpack(payload: String, radix: Int, count: Int, dictionary: String) -> String {
        let words = dictionary.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let pattern = "[0-9A-Za-z]+"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return payload }
        var output = payload
        let matches = expression.matches(in: output, range: NSRange(output.startIndex..., in: output))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output),
                  let value = integerValue(of: output[range], radix: radix),
                  value < count, value < words.count,
                  !words[value].isEmpty else { continue }
            output.replaceSubrange(range, with: words[value])
        }
        return output
    }

    private static func integerValue(of token: Substring, radix: Int) -> Int? {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var value = 0
        for character in token {
            guard let digit = alphabet.firstIndex(of: character), digit < radix else { return nil }
            let (multiplied, overflow) = value.multipliedReportingOverflow(by: radix)
            let (next, additionOverflow) = multiplied.addingReportingOverflow(digit)
            guard !overflow, !additionOverflow else { return nil }
            value = next
        }
        return value
    }
}
