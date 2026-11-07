import Foundation
import PacerCore
import WinSDK

public enum WindowsLocalProfileOwner {
    public static func allows(_ owner: PSID, user: PSID, administrators: PSID,
                              elevated: Bool, administratorsEnabled: Bool) -> Bool {
        EqualSid(owner, user) || elevated && administratorsEnabled && EqualSid(owner, administrators)
    }

    static func validate(_ owner: PSID) throws {
        var token: HANDLE?
        guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY | TOKEN_DUPLICATE), &token), let token else {
            throw ClaudeHookInstaller.Failure.unsafePath
        }
        defer { _ = CloseHandle(token) }
        var size: DWORD = 0
        _ = GetTokenInformation(token, TokenUser, nil, 0, &size)
        guard size > 0, size <= 65536 else { throw ClaudeHookInstaller.Failure.unsafePath }
        let user = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<TOKEN_USER>.alignment)
        defer { user.deallocate() }
        guard GetTokenInformation(token, TokenUser, user, size, &size), let sid = user.assumingMemoryBound(to: TOKEN_USER.self).pointee.User.Sid else {
            throw ClaudeHookInstaller.Failure.unsafePath
        }
        if EqualSid(owner, sid) { return }
        var elevation = TOKEN_ELEVATION(), returned: DWORD = 0
        guard GetTokenInformation(token, TokenElevation, &elevation, DWORD(MemoryLayout<TOKEN_ELEVATION>.size), &returned), elevation.TokenIsElevated != 0 else {
            throw ClaudeHookInstaller.Failure.unsafePath
        }
        let admin = UnsafeMutableRawPointer.allocate(byteCount: 68, alignment: MemoryLayout<UInt64>.alignment)
        defer { admin.deallocate() }
        var adminSize: DWORD = 68, membership: HANDLE?, enabled: WindowsBool = false
        guard CreateWellKnownSid(WinBuiltinAdministratorsSid, nil, admin, &adminSize),
              DuplicateToken(token, SecurityIdentification, &membership), let membership else {
            throw ClaudeHookInstaller.Failure.unsafePath
        }
        defer { _ = CloseHandle(membership) }
        guard CheckTokenMembership(membership, admin, &enabled),
              allows(owner, user: sid, administrators: admin, elevated: true, administratorsEnabled: enabled.boolValue) else {
            throw ClaudeHookInstaller.Failure.unsafePath
        }
    }
}
