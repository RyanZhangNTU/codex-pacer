import Foundation

/// Keep synthetic helper programs and payloads out of the OS command-line budget.
struct PythonFixture {
    private let directory: URL
    static var executable: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["PACER_TEST_PYTHON"] ?? "/usr/bin/python3")
    }

    static func prepare(_ process: Process) throws -> Self {
        let arguments = process.arguments ?? []
        guard let command = arguments.firstIndex(of: "-c"), command + 1 < arguments.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-python-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let payload = directory.appendingPathComponent("input.json"), launcher = directory.appendingPathComponent("run.py")
            let value: [String: Any] = ["program": arguments[command + 1], "arguments": Array(arguments.dropFirst(command + 2))]
            try JSONSerialization.data(withJSONObject: value).write(to: payload)
            let bootstrap = """
            import json,sys
            with open(sys.argv[1],encoding='utf-8') as stream:fixture=json.load(stream)
            sys.argv=['-c']+fixture['arguments']
            exec(compile(fixture['program'],'<fixture>','exec'),globals())
            """
            try Data(bootstrap.utf8).write(to: launcher)
            process.executableURL = executable
            process.arguments = Array(arguments.prefix(command)) + [launcher.path, payload.path]
            return Self(directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
