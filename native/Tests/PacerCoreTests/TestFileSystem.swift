#if canImport(PacerMacSupport)
import PacerMacSupport
typealias TestFileSystem = MacFileSystem
#else
import PacerCore
import PacerEngineSupport
typealias TestFileSystem = WindowsFileSystem
#endif
