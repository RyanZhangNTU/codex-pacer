#if os(Windows)
import Foundation
import ucrt
import WinSDK

/// Starts a thread for blocking work, such as waiting on one WinHTTP request.
///
/// Foundation's `Thread` on Windows keeps the handle that `_beginthreadex`
/// returns and never closes it, so every finished thread left a handle to an
/// exited thread behind: about a dozen a minute while Claude was followed in
/// the cloud. These threads close their handle as soon as they start.
enum WindowsThread {
    private final class Work: @unchecked Sendable {
        let body: @Sendable () -> Void
        init(_ body: @escaping @Sendable () -> Void) { self.body = body }
    }

    /// Returns false, without running `body`, when no thread could start.
    @discardableResult
    static func start(name: String, _ body: @escaping @Sendable () -> Void) -> Bool {
        let context = Unmanaged.passRetained(Work(body)).toOpaque()
        let value = _beginthreadex(nil, 0, { context in
            Unmanaged<Work>.fromOpaque(context!).takeRetainedValue().body()
            return 0
        }, context, 0, nil)
        guard value != 0, let thread = HANDLE(bitPattern: value) else {
            Unmanaged<Work>.fromOpaque(context).release()
            return false
        }
        _ = name.withCString(encodedAs: UTF16.self) { SetThreadDescription(thread, $0) }
        CloseHandle(thread)
        return true
    }
}
#endif
