#if canImport(PacerMacSupport)
import PacerMacSupport
typealias TestFileSystem = MacFileSystem
#else
import PacerCore
typealias TestFileSystem = WindowsFileSystem
#endif
