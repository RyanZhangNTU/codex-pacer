import Foundation

public enum CodexApplicationResolver {
    public static func locations(userHome: URL, catalog: any ApplicationCatalog) -> [URL] {
        catalog.locations(for: .codex, userHome: userHome)
    }
    public static func find(applicationURLs: [URL]? = nil, userHome: URL,
                            catalog: any ApplicationCatalog) -> URL? {
        (applicationURLs ?? locations(userHome: userHome, catalog: catalog)).first { catalog.isApplication($0, provider: .codex) }
    }
}
