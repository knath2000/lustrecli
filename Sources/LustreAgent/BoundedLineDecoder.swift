import Foundation

enum BoundedLineDecoderError: Error, Equatable { case lineTooLong, failed }

struct BoundedLineDecoder {
    private let maximumLineBytes: Int
    private var buffer = Data()
    private var pendingCR = false
    private var failed = false

    init(maximumLineBytes: Int) { self.maximumLineBytes = max(1, maximumLineBytes) }

    mutating func append(_ data: Data) throws -> [Data] {
        guard !failed else { throw BoundedLineDecoderError.failed }
        var lines: [Data] = []
        for byte in data {
            if pendingCR {
                pendingCR = false
                if byte == 10 { continue }
            }
            if byte == 10 || byte == 13 {
                if !buffer.isEmpty { lines.append(buffer); buffer.removeAll(keepingCapacity: true) }
                pendingCR = byte == 13
            } else {
                buffer.append(byte)
                if buffer.count > maximumLineBytes { failed = true; buffer.removeAll(); throw BoundedLineDecoderError.lineTooLong }
            }
        }
        return lines
    }

    mutating func finish() throws -> [Data] {
        guard !failed else { throw BoundedLineDecoderError.failed }
        pendingCR = false
        defer { buffer.removeAll(keepingCapacity: false) }
        return buffer.isEmpty ? [] : [buffer]
    }
}
