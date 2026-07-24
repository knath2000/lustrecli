import Foundation
import LustreCore

enum YtDlpProgressParseError: Error, Equatable { case invalidEncoding, lineTooLong, invalidPrefix, invalidFieldCount, invalidStatus, invalidNumber, invalidControlCharacter }
enum YtDlpProgressStatus: Equatable { case downloading, finished, postProcessing }
enum YtDlpProgressComponent: Equatable { case video, audio, media }

struct YtDlpProgressSample: Equatable {
    let status: YtDlpProgressStatus
    let component: YtDlpProgressComponent
    let phase: TransferPhase
    let message: String
    let progress: DownloadProgress
}

enum YtDlpProgressParser {
    static let prefix = "LUSTRE_PROGRESS:v1"
    static let maximumLineBytes = 1024

    static func parse(_ data: Data) throws -> YtDlpProgressSample {
        guard data.count <= maximumLineBytes else { throw YtDlpProgressParseError.lineTooLong }
        guard let line = String(data: data, encoding: .utf8) else { throw YtDlpProgressParseError.invalidEncoding }
        guard !line.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 9) || (127...159).contains($0.value) }) else { throw YtDlpProgressParseError.invalidControlCharacter }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 10 else { throw YtDlpProgressParseError.invalidFieldCount }
        guard fields[0] == prefix else { throw YtDlpProgressParseError.invalidPrefix }
        let status: YtDlpProgressStatus
        switch fields[1] { case "downloading": status = .downloading; case "finished": status = .finished; case "postprocessing": status = .postProcessing; default: throw YtDlpProgressParseError.invalidStatus }
        func integer(_ value: String, positive: Bool = false) throws -> Int64? {
            if value == "NA" { return nil }
            guard let result = Int64(value), result >= 0, !positive || result > 0 else { throw YtDlpProgressParseError.invalidNumber }
            return result
        }
        func number(_ value: String) throws -> Double? {
            if value == "NA" { return nil }
            guard let result = Double(value), result.isFinite, result >= 0, result <= 1_000_000_000_000 else { throw YtDlpProgressParseError.invalidNumber }
            return result
        }
        let downloaded = try integer(fields[2])
        let exact = try integer(fields[3], positive: true)
        let estimated = try integer(fields[4], positive: true)
        let speed = try number(fields[5])
        let eta = try integer(fields[6])
        if let eta, eta > 31_536_000 { throw YtDlpProgressParseError.invalidNumber }
        let index = try integer(fields[7])
        let count = try integer(fields[8])
        if let index, let count, (count == 0 && index > 0) || (count > 0 && index > count) { throw YtDlpProgressParseError.invalidNumber }
        let component: YtDlpProgressComponent = fields[9] == "video" ? .video : fields[9] == "audio" ? .audio : .media
        if fields[9] != "video" && fields[9] != "audio" && fields[9] != "NA" && fields[9] != "media" { throw YtDlpProgressParseError.invalidNumber }
        if status == .finished && (downloaded == nil || (exact ?? estimated) == nil) { throw YtDlpProgressParseError.invalidNumber }
        let phase: TransferPhase = status == .postProcessing ? .postProcessing : .materializing
        let message = status == .postProcessing ? "Merging video and audio…" : component == .video ? "Downloading video…" : component == .audio ? "Downloading audio…" : "Materializing media…"
        return YtDlpProgressSample(status: status, component: component, phase: phase, message: message, progress: DownloadProgress(bytesWritten: downloaded ?? 0, totalBytes: exact ?? estimated, phase: phase, totalIsEstimated: exact == nil && estimated != nil, bytesPerSecond: speed, etaSeconds: eta.map(Int.init)))
    }
}
