import Foundation

// Custom error type for more specific error handling
public enum LyricsProviderError: Error, LocalizedError {
    case serviceResponse(code: Int)
    case invalidURL(urlString: String)
    case networkError(underlyingError: Error)
    case decodingError(underlyingError: Error)
    case processingFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .serviceResponse(let code):
            return "Service response code: \(code)"
        case .invalidURL(let urlString):
            return "The provided URL is invalid: \(urlString)"
        case .networkError(let underlyingError):
            return "A network error occurred: \(underlyingError.localizedDescription)"
        case .decodingError(let underlyingError):
            return "Failed to decode the server response: \(underlyingError.localizedDescription)"
        case .processingFailed(let reason):
            return "Failed to process the lyrics data: \(reason)"
        }
    }
}
