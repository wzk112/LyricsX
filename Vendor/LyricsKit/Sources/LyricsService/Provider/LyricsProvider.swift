import Foundation
import LyricsCore
import FoundationToolbox

public enum LyricsProviders {}

public protocol LyricsProvider: Sendable {
    func lyrics(for request: LyricsSearchRequest) -> AsyncThrowingStream<Lyrics, Error>
}

protocol _LyricsProvider: LyricsProvider {
    associatedtype LyricsToken

    static var service: String { get }

    func search(for request: LyricsSearchRequest) async throws -> [LyricsToken]

    func fetch(with token: LyricsToken) async throws -> Lyrics
}

@Loggable
private enum LyricsProviderLog {
    static func fetchTaskFailed(_ error: any Error) {
        #log(.error, "A fetch task failed, skipping. Error: \(error)")
    }
}

extension _LyricsProvider {
    func lyrics(for request: LyricsSearchRequest) -> AsyncThrowingStream<Lyrics, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let tokens = try await self.search(for: request)
                    let limitedTokens = Array(tokens.prefix(request.limit))
                    // Consume completion order, not token order. One stalled
                    // download must not hide every version behind it.
                    let failure = await withTaskGroup(of: Result<Lyrics, Error>.self) { group in
                        var next = 0
                        var received = 0
                        var firstFailure: Error?
                        func enqueue() {
                            guard next < limitedTokens.count, !Task.isCancelled else { return }
                            let token = limitedTokens[next]; next += 1
                            group.addTask {
                                do {
                                    try Task.checkCancellation()
                                    let lyrics = try await self.fetch(with: token)
                                    lyrics.metadata.request = request
                                    lyrics.metadata.service = Self.service
                                    return .success(lyrics)
                                } catch { return .failure(error) }
                            }
                        }
                        for _ in 0..<min(4, limitedTokens.count) { enqueue() }
                        for await result in group {
                            guard !Task.isCancelled else { group.cancelAll(); break }
                            switch result {
                            case .success(let lyrics): received += 1; continuation.yield(lyrics)
                            case .failure(let error):
                                if firstFailure == nil { firstFailure = error }
                                LyricsProviderLog.fetchTaskFailed(error)
                            }
                            enqueue()
                        }
                        return received == 0 ? firstFailure : nil
                    }
                    if let failure { throw failure }
                    try Task.checkCancellation()

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
