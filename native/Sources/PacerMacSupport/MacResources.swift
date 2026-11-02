import Foundation
import PacerCore

public enum MacResources {
    public static var bundle: Bundle {
        if let url = Bundle.main.url(forResource: "CodexPacerIsland_PacerCore", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return L10n.sharedResourceBundle
    }
}
