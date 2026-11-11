import AppKit

/// A display as Pacer remembers it. The screen number can change when a
/// display is plugged in again or the Mac restarts; the display's UUID, made
/// from its vendor, model and serial, stays the same.
enum DisplayIdentity {
    /// The chosen display's UUID, saved beside its number (`displayID`).
    static let defaultsKey = "displayUUID"
    private static let twinIndexKey = "displayTwinIndex"

    struct Display: Equatable {
        let number: Int
        let uuid: String?
    }

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
        let twins = ordered(screens).filter { self.uuid($0) == uuid }
        guard twins.count > 1, let index = twins.firstIndex(of: screen), index > 0 else { return uuid }
        return uuid + "#\(index)"
    }

    private static func ordered(_ screens: [NSScreen]) -> [NSScreen] {
        screens.sorted { ($0.frame.minX, $0.frame.minY, number($0)) < ($1.frame.minX, $1.frame.minY, number($1)) }
    }

    /// Use the number when it still belongs to this UUID. After renumbering,
    /// the saved position in the group distinguishes displays with identical UUIDs.
    static func select(number: Int, uuid: String?, twinIndex: Int?, among displays: [Display]) -> Int? {
        guard number != 0 else { return nil }
        guard let uuid else { return displays.firstIndex { $0.number == number } }
        let matches = displays.indices.filter { displays[$0].uuid == uuid }
        if let exact = matches.first(where: { displays[$0].number == number }) { return exact }
        guard let twinIndex else { return matches.first }
        // A single remaining twin might be the other display. Leave the
        // saved choice in place until both displays can be distinguished.
        return matches.count > 1 && matches.indices.contains(twinIndex) ? matches[twinIndex] : nil
    }

    static func selected(in defaults: UserDefaults, among screens: [NSScreen]) -> NSScreen? {
        let chosen = defaults.integer(forKey: "displayID")
        guard chosen != 0 else { return nil }
        let savedUUID = defaults.string(forKey: defaultsKey)
        if let exact = screens.first(where: { number($0) == chosen }), savedUUID == nil || uuid(exact) == savedUUID { return exact }
        let sorted = ordered(screens)
        let index = select(number: chosen, uuid: savedUUID,
            twinIndex: defaults.object(forKey: twinIndexKey) as? Int,
            among: sorted.map { Display(number: number($0), uuid: uuid($0)) })
        return index.map { sorted[$0] }
    }

    /// A verified display can gain a UUID or a new number without changing the saved choice.
    @discardableResult
    static func sync(_ screen: NSScreen, in defaults: UserDefaults, among screens: [NSScreen]) -> Bool {
        guard let uuid = uuid(screen) else { return false }
        let current = number(screen)
        let renumbered = defaults.integer(forKey: "displayID") != current
        if renumbered { defaults.set(current, forKey: "displayID") }
        if defaults.string(forKey: defaultsKey) == nil { defaults.set(uuid, forKey: defaultsKey) }
        if defaults.object(forKey: twinIndexKey) == nil { rememberTwin(screen, uuid: uuid, in: defaults, among: screens) }
        return renumbered
    }

    /// Saves the chosen display by number and UUID; zero follows the main display.
    static func choose(_ number: Int, in defaults: UserDefaults) {
        defaults.set(number, forKey: "displayID")
        if number == 0 {
            defaults.removeObject(forKey: defaultsKey)
            defaults.removeObject(forKey: twinIndexKey)
            return
        }
        // A display that is gone keeps the UUID saved for it.
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { self.number($0) == number }) else { return }
        if let uuid = uuid(screen) {
            defaults.set(uuid, forKey: defaultsKey)
            rememberTwin(screen, uuid: uuid, in: defaults, among: screens)
        } else {
            defaults.removeObject(forKey: defaultsKey)
            defaults.removeObject(forKey: twinIndexKey)
        }
    }

    private static func rememberTwin(_ screen: NSScreen, uuid: String, in defaults: UserDefaults, among screens: [NSScreen]) {
        let twins = ordered(screens).filter { self.uuid($0) == uuid }
        if twins.count > 1, let index = twins.firstIndex(of: screen) {
            defaults.set(index, forKey: twinIndexKey)
        } else if defaults.object(forKey: twinIndexKey) != nil {
            defaults.removeObject(forKey: twinIndexKey)
        }
    }
}
