import Foundation
import PacerCore

@_cdecl("pacer_host_window_activate")
public func pacerHostWindowActivate(_ pid: UInt32, _ started: UInt64) -> Int32 {
#if os(Windows)
    return WindowsHostWindow.activate(pid: pid, started: started) ? 1 : 0
#else
    return 0
#endif
}

@_cdecl("pacer_task_row_hover_duration")
public func pacerTaskRowHoverDuration() -> Double { TaskRowInteraction.hoverDuration }
@_cdecl("pacer_task_row_hover_value")
public func pacerTaskRowHoverValue(_ fraction: Double) -> Double { TaskRowInteraction.hoverProgress(fraction) }
@_cdecl("pacer_task_navigation_error_duration")
public func pacerTaskNavigationErrorDuration() -> Double { TaskRowInteraction.navigationErrorDuration }

@_cdecl("pacer_harness_application_find")
public func pacerHarnessFind(_ output: UnsafeMutablePointer<UInt16>?, _ capacity: Int32) -> Int32 {
#if os(Windows)
    guard let output, capacity > 0, capacity <= 32768,
          let url = WindowsDeepSeekApplication.find() else { return 0 }
    let text = url.withUnsafeFileSystemRepresentation { String(cString: $0!) }
    let wide = Array(text.utf16)
    guard wide.count < Int(capacity) else { return 0 }
    for (index, value) in wide.enumerated() { output[index] = value }; output[wide.count] = 0
    return Int32(wide.count)
#else
    return 0
#endif
}

@_cdecl("pacer_harness_application_validate")
public func pacerHarnessValidate(_ path: UnsafePointer<UInt16>?, _ count: Int32) -> Int32 {
#if os(Windows)
    guard let path, count > 0, count < 32768 else { return 0 }
    let text = String(decoding: UnsafeBufferPointer(start: path, count: Int(count)), as: UTF16.self)
    return WindowsDeepSeekApplication.isApplication(URL(fileURLWithPath: text)) ? 1 : 0
#else
    return 0
#endif
}
