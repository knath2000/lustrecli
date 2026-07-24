import Foundation
import LustreCore

enum YtDlpProgressEventBufferError: Error, Equatable { case capacityExceeded }

struct YtDlpProgressEventBuffer {
    private let capacity: Int
    private var samples: [YtDlpProgressSample] = []

    init(capacity: Int) { self.capacity = max(2, capacity) }
    var count: Int { samples.count }
    var isEmpty: Bool { samples.isEmpty }

    mutating func offer(_ sample: YtDlpProgressSample) throws {
        guard let last = samples.last else { samples.append(sample); return }
        if category(last) == category(sample) {
            if samples.count == 1 {
                guard samples.count < capacity else { throw YtDlpProgressEventBufferError.capacityExceeded }
                samples.append(sample)
            } else {
                samples[samples.count - 1] = sample
            }
            return
        }
        guard samples.count < capacity else { throw YtDlpProgressEventBufferError.capacityExceeded }
        samples.append(sample)
    }

    mutating func popFirst() -> YtDlpProgressSample? {
        samples.isEmpty ? nil : samples.removeFirst()
    }

    mutating func removeAll() { samples.removeAll(keepingCapacity: true) }

    private func category(_ sample: YtDlpProgressSample) -> (TransferPhase, YtDlpProgressStatus, YtDlpProgressComponent) {
        (sample.phase, sample.status, sample.component)
    }
}
