import Foundation
import PacerCore

/// Host locations and process IO; route identity and discovery stay in Core.
struct WindowsSSHServices: Sendable {
    let ssh: URL
    let userHome: URL
    let desktopFile: URL
    let discovery: ClaudeSSHDiscovery
    let environment: [String: String]?
    var processes: WindowsSSHProcessLauncher { .init(ssh: ssh, environment: environment) }
    init(ssh: URL = WindowsExecutables.ssh,
         userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
         desktopFile: URL? = nil, environment: [String: String]? = nil,
         resolve: (@Sendable (String, Int?) async -> ClaudeSSHRoute?)? = nil) {
        self.ssh = ssh; self.userHome = userHome
        self.environment = environment
        let environment = environment ?? ProcessInfo.processInfo.environment
        let appData = WindowsEnvironment.value("APPDATA", in: environment).map { URL(fileURLWithPath: $0) }
            ?? userHome.appendingPathComponent("AppData/Roaming")
        let candidates = Self.desktopLocations(environment: environment)
        self.desktopFile = desktopFile ?? candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? appData.appendingPathComponent("Claude/ssh_configs.json")
        let programData = WindowsEnvironment.value("PROGRAMDATA", in: environment) ?? "C:/ProgramData"
        discovery = ClaudeSSHDiscovery(resolve: resolve ?? { await ClaudeSSHRouteResolver.resolve(host: $0, port: $1, executable: ssh) },
            validDestination: { ClaudeSSHRouteResolver.validDestination($0) }, validIdentityFile: { Self.validIdentity($0) },
            sshConfigFiles: [userHome.appendingPathComponent(".ssh/config"), URL(fileURLWithPath: programData).appendingPathComponent("ssh/ssh_config")])
    }
    func codexTargets(home: URL) async -> [RemoteActivityTarget] {
        await discovery.configuredCodex(home: home, userHome: userHome)
    }
    static func desktopLocations(environment: [String: String]) -> [URL] {
        WindowsClaudeAccountBinding.locations(environment: environment).map { $0.deletingLastPathComponent().appendingPathComponent("ssh_configs.json") }
    }
    func claudeTargets(codexHome: URL, claudeHome: URL) async -> [RemoteActivityTarget] {
        await discovery.configured(codexHome: codexHome, claudeHome: claudeHome, userHome: userHome, desktopFile: desktopFile)
    }
    static func validIdentity(_ path: String) -> Bool {
        path.utf8.count <= 4096 && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
            (path.hasPrefix("~/") || WindowsCodexExecutableDiscovery.absolute(path))
    }
    static func arguments(_ target: RemoteActivityTarget, terminal: Bool = false) -> [String]? {
        guard let args = target.sshArguments(terminal: terminal, validDestination: { ClaudeSSHRouteResolver.validDestination($0) },
            validIdentityFile: validIdentity) else { return nil }
        return harden(args)
    }
    static func harden(_ arguments: [String]) -> [String] {
        // Existing known hosts may be used, but OpenSSH must never update them.
        ["-o", "UpdateHostKeys=no", "-o", "NumberOfPasswordPrompts=0", "-o", "PermitLocalCommand=no",
         "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no"] + arguments
    }
}

struct WindowsSSHProcessLauncher: HelperProcessLauncher {
    let ssh: URL
    var environment: [String: String]? = nil
    func launch(_ request: ChildProcessRequest, output: @escaping @Sendable (Data) async -> Void,
                ended: @escaping @Sendable () async -> Void) throws -> any ChildProcessConnection {
        guard request.executable.standardizedFileURL == ssh.standardizedFileURL else {
            return try WindowsHelperProcessLauncher().launch(request, output: output, ended: ended)
        }
        let invocation = try WindowsSSHInvocation(arguments: request.arguments)
        return try WindowsHelperProcess(.init(executable: request.executable, arguments: invocation.arguments,
            environment: environment ?? request.environment), initialInput: invocation.input, privateErrors: true, output: output, ended: ended)
    }
}

/// Windows has a 32K command line. Send the unchanged shared command through
/// stdin before exposing the connection; subsequent bytes and EOF keep order.
struct WindowsSSHInvocation {
    let arguments: [String]
    let input: Data
    init(arguments: [String]) throws {
        guard let boundary = arguments.firstIndex(of: "--"), arguments.count == boundary + 3,
              arguments.contains("BatchMode=yes"), arguments.contains("StrictHostKeyChecking=yes"),
              ClaudeSSHRouteResolver.validDestination(arguments[boundary + 1]),
              let command = arguments.last, !command.isEmpty, !command.contains("\0"),
              command.utf8.count <= 1024 * 1024 else { throw CodexClientError.invalidResponse }
        self.arguments = WindowsSSHServices.harden(Array(arguments.dropLast())) + [Self.bootstrapCommand]
        input = Data((String(command.utf8.count) + "\n" + command).utf8)
    }
    static let bootstrap = #"""
    import os
    def exact(n):
        result=b""
        while len(result)<n:
            part=os.read(0,n-len(result))
            if not part:raise SystemExit(2)
            result+=part
        return result
    digits=b""
    while True:
        byte=exact(1)
        if byte==b"\n":break
        if byte<b"0" or byte>b"9" or len(digits)>=7:raise SystemExit(2)
        digits+=byte
    size=int(digits)
    if not 0<size<=1048576:raise SystemExit(2)
    command=exact(size).decode("utf-8")
    os.execv("/bin/sh",["sh","-c",command])
    """#
    static var bootstrapCommand: String {
        "python3 -u -c 'import base64;exec(base64.b64decode(\"" + Data(bootstrap.utf8).base64EncodedString() + "\"))'"
    }
}
