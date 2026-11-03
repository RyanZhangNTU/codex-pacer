import Foundation
import PacerCore

extension ClaudeCloudReplyStreams {
    public static func lines(session: URLSession) -> Lines {
        { request in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let (bytes, response) = try await session.bytes(for: request)
                        guard let response = response as? HTTPURLResponse else { throw ClaudeCloudFailure.invalidReply }
                        if let failure = ClaudeCloudFailure(streamResponse: response, at: Date()) { throw failure }
                        var buffer = ClaudeCloudLineBuffer()
                        for try await byte in bytes {
                            if let line = try buffer.append(byte) { continuation.yield(line) }
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}
