import Foundation
import LyricsXCore

/// Display and checkpoint reliable results while discovery continues. A cached
/// checkpoint remains replaceable; only a completed or manual choice is final.
actor AutomaticSearchResults {
    let continuation: AsyncThrowingStream<LyricCandidate, Error>.Continuation
    private let checkpoint: @Sendable (LyricCandidate) async -> Void
    private var values: [UUID: LyricCandidate] = [:]
    private struct Emission: Equatable { var score: Double; var provisional: Bool }
    private var emitted: [UUID: Emission] = [:]
    private var displayedScore = -Double.infinity
    private var checkpointedScore = -Double.infinity
    private var checkpointTask: Task<Void, Never>?
    private var mayDisplay = false
    private var finished = false

    init(_ continuation: AsyncThrowingStream<LyricCandidate, Error>.Continuation,
         checkpoint: @escaping @Sendable (LyricCandidate) async -> Void = { _ in }) {
        self.continuation = continuation; self.checkpoint = checkpoint
    }
    func restore(_ value: LyricCandidate) {
        values[value.id] = value
        displayedScore = value.score
        checkpointedScore = value.score
        emitted[value.id] = .init(score: value.score, provisional: true)
        continuation.yield(value)
    }
    func add(_ value: LyricCandidate) async {
        guard !finished, value.score > 0 else { return }
        values[value.id] = value
        await checkpointIfBetter(value)
        await publishReliableBest()
    }
    func allowEarlyDisplay() async { mayDisplay = true; await publishReliableBest() }

    private func publishReliableBest() async {
        guard !finished, mayDisplay, var best = values.values.max(by: { $0.score < $1.score }),
              best.score >= 60, best.score >= displayedScore + 9 else { return }
        best.isProvisional = true
        displayedScore = best.score
        // Persist before exposing it, so an immediate song change cannot lose it.
        await checkpointIfBetter(best)
        guard !finished, !Task.isCancelled, best.score >= displayedScore else { return }
        emit(best)
    }
    private func checkpointIfBetter(_ value: LyricCandidate) async {
        if value.score >= 60, value.score >= checkpointedScore + 9 {
            checkpointedScore = value.score
            let previous = checkpointTask
            checkpointTask = Task { [checkpoint] in
                await previous?.value
                await checkpoint(value)
            }
        }
        await checkpointTask?.value
    }
    private func emit(_ value: LyricCandidate) {
        let state = Emission(score: value.score, provisional: value.isProvisional)
        guard emitted[value.id] != state else { return }
        emitted[value.id] = state
        displayedScore = max(displayedScore, value.score)
        continuation.yield(value)
    }
    func finish(error: Error?) {
        guard !finished else { return }; finished = true
        for var value in values.values.sorted(by: { $0.score > $1.score }) {
            value.isProvisional = error != nil
            emit(value)
        }
        if values.isEmpty, let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
    }
}
