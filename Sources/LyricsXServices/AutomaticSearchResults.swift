import Foundation
import LyricsXCore

/// Show a reliable early result while discovery continues. Only the session's
/// final winner is cached; slow sources may still improve word/translation quality.
actor AutomaticSearchResults {
    let continuation: AsyncThrowingStream<LyricCandidate, Error>.Continuation
    private var values: [UUID: LyricCandidate] = [:]
    private var emitted: [UUID: Double] = [:]
    private var displayedScore = -Double.infinity
    private var mayDisplay = false
    private var finished = false

    init(_ continuation: AsyncThrowingStream<LyricCandidate, Error>.Continuation) { self.continuation = continuation }

    func add(_ value: LyricCandidate) {
        guard !finished, value.score > 0 else { return }
        values[value.id] = value
        publishReliableBest()
    }
    func allowEarlyDisplay() { mayDisplay = true; publishReliableBest() }

    private func publishReliableBest() {
        guard !finished, mayDisplay, let best = values.values.max(by: { $0.score < $1.score }),
              best.score >= 60, best.score >= displayedScore + 9 else { return }
        // Source or feature improvements are meaningful. Sub-point duration
        // differences can wait until completion instead of causing flicker.
        emit(best)
    }
    private func emit(_ value: LyricCandidate) {
        guard emitted[value.id] != value.score else { return }
        emitted[value.id] = value.score
        displayedScore = max(displayedScore, value.score)
        continuation.yield(value)
    }
    func finish(error: Error?) {
        guard !finished else { return }; finished = true
        for value in values.values.sorted(by: { $0.score > $1.score }) { emit(value) }
        if values.isEmpty, let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
    }
}
