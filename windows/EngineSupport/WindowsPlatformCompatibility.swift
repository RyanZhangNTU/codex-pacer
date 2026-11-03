import Foundation
import PacerCore

public enum WindowsPlatformCompatibility {
    public static let minimumBuild = 19041
    public static func supports(_ version: OperatingSystemVersion) -> Bool {
        version.majorVersion >= 10 && version.patchVersion >= minimumBuild
    }
}
