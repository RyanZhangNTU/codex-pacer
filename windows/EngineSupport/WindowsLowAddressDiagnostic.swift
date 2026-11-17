#if os(Windows)
import Foundation

/// Checks in this process what goes wrong when a heap block lies below 2 GB:
/// `PacerEngine.exe --diagnose-low-addresses`.
///
/// Swift 6.4.2 reads one word of a string's storage as its UTF-16 length when the
/// value is at most `Int32.max`, and as a pointer otherwise (swiftlang/swift#92199).
/// A pointer below 2 GB is then taken for a length, and Foundation stops the engine
/// on the first long non-ASCII string. The desktop keeps the heap above that
/// (`EngineLaunch`); this prints where the heap is and whether lengths hold, so the
/// desktop's checks can prove it on an engine whose addresses are not randomized.
///
/// Prints `heap high` or `heap low`, then `utf16 <first> <second>` for a string of
/// 128 units read before and after its breadcrumbs exist. Exits 3 when a length is wrong.
enum WindowsLowAddressDiagnostic {
    static let flag = "--diagnose-low-addresses"

    static func run(_ arguments: [String] = CommandLine.arguments) -> Bool {
        guard arguments.contains(flag) else { return false }
        // Swift objects come from the C runtime's heap. A Swift object made here could be kept on the stack instead.
        let block = malloc(32)
        let low = UInt(bitPattern: block) <= UInt(Int32.max)
        free(block)
        print(low ? "heap low" : "heap high")
        let units = [UInt16](repeating: 0x00E9, count: 128)
        let text = String(decoding: units, as: UTF16.self)
        let first = text.utf16.count
        // An interior offset makes the standard library build the string's breadcrumbs on the heap.
        let middle = text.utf16.index(text.utf16.startIndex, offsetBy: 64)
        let second = text.utf16[middle] == units[64] ? text.utf16.count : -1
        print("utf16 \(first) \(second)")
        guard first == units.count, second == units.count else { exit(3) }
        // The same through Foundation, as the engine's file URLs reach it. A wrong length stops the process here.
        let folder = "C:\\" + String(repeating: "\u{4E2D}", count: 40)
        _ = try? URL(fileURLWithPath: folder).appendingPathComponent("codex.exe").resourceValues(forKeys: [.isRegularFileKey])
        print("foundation ok")
        return true
    }
}
#endif
