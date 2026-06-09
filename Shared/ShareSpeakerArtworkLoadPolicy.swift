import Foundation

struct ShareSpeakerArtworkLoadPolicy: Equatable, Sendable {
    static let requestTimeoutMilliseconds: UInt64 = 2_500
    static let maxAttempts = 2
}
