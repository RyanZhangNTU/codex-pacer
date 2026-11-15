import Foundation
import notify

/// configd posts this whenever the primary network, an interface address or
/// DNS changes, including a VPN tunnel or Wi-Fi coming back after sleep.
public final class MacNetworkChanges {
    private var token: Int32 = NOTIFY_TOKEN_INVALID
    /// Only root may post the system name, so tests pass their own.
    public init(name: String = kNotifySCNetworkChange, queue: DispatchQueue = .main, changed: @escaping @Sendable () -> Void) {
        if notify_register_dispatch(name, &token, queue, { _ in changed() }) != NOTIFY_STATUS_OK {
            token = NOTIFY_TOKEN_INVALID
        }
    }
    deinit { if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) } }
}
