import Foundation

/// One ordered stdout consumer, with backpressure through its async callback.
/// Closing sends stdin EOF before the host's bounded termination escalation.
public protocol HelperProcessLauncher: Sendable {
    func launch(_ request: ChildProcessRequest, output: @escaping @Sendable (Data) async -> Void,
                ended: @escaping @Sendable () async -> Void) throws -> any ChildProcessConnection
}
