import AppKit

/// A display as Pacer remembers it. The screen number can change when a
/// display is plugged in again or the Mac restarts; the display's UUID, made
/// from its vendor, model and serial, stays the same.
enum DisplayIdentity {
    /// The chosen display's UUID, saved beside its number (`displayID`).
    static let defaultsKey = "displayUUID"

    static func number(_ screen: NSScreen) -> Int {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }

    static func uuid(_ screen: NSScreen) -> String? {
        guard let id = CGDirectDisplayID(exactly: number(screen)), let uuid = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String?
    }

    /// The per-display memory's key: the UUID, told apart by arrangement when
    /// two connected displays report the same one.
    static func key(_ screen: NSScreen, among screens: [NSScreen] = NSScreen.screens) -> String {
        guard let uuid = uuid(screen) else { return "display-\(number(screen))" }
        let twins = screens.filter { self.uuid($0) == uuid }
            .sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        guard twins.count > 1, let index = twins.firstIndex(of: screen), index > 0 else { return uuid }
        return uuid + "#\(index)"
    }

    /// Saves the chosen display by number and UUID; zero follows the main display.
    static func choose(_ number: Int, in defaults: UserDefaults) {
        defaults.set(number, forKey: "displayID")
        if number == 0 { defaults.removeObject(forKey: defaultsKey); return }
        // A display that is gone keeps the UUID saved for it.
        if let screen = NSScreen.screens.first(where: { self.number($0) == number }), let uuid = uuid(screen) {
            defaults.set(uuid, forKey: defaultsKey)
        }
    }
}
