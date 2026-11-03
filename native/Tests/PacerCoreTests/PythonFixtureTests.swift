import XCTest

final class PythonFixtureTests: XCTestCase {
    func testLargeProgramsAndArgumentsRunWithoutUsingTheCommandLineBudget() throws {
        let process = Process(), output = Pipe(), errors = Pipe()
        let program = "#" + String(repeating: "x", count: 100_000) + "\nimport sys\nprint(len(sys.argv[1]))"
        process.arguments = ["-u", "-c", program, String(repeating: "y", count: 100_000)]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        let fixture = try PythonFixture.prepare(process)
        defer { fixture.remove() }
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "100000")
    }
}
