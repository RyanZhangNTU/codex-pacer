import Foundation

/// Where the island sits on each display, when each display keeps its own
/// place (`islandPositionPerDisplay`, on by default). A place is the display
/// mode with the Free Move spot and the older corner, the three preferences
/// the island reads; they always hold the current display's place, and this
/// memory keeps a copy per display, keyed by a stable display identifier
/// (the display's UUID on the Mac). Size, material and the bar's components
/// stay shared. Windows stores the same values.
public struct IslandScreenMemory: Equatable, Sendable {
    public static let enabledKey = "islandPositionPerDisplay"
    public static let defaultsKey = "islandDisplayPlaces"
    /// Displays kept; the one used longest ago is forgotten first.
    public static let limit = 12
    /// Larger saved text is damaged.
    public static let byteLimit = 16_384

    /// One display's place, as the three island preferences hold it.
    public struct Place: Equatable, Sendable {
        public var mode: IslandDisplayMode
        public var position: IslandPosition?
        public var placement: IslandPlacement?
        public init(mode: IslandDisplayMode, position: IslandPosition? = nil, placement: IslandPlacement? = nil) {
            self.mode = mode; self.position = position; self.placement = placement
        }
        /// The place the island preferences hold now.
        public static func current(in defaults: UserDefaults) -> Self {
            Self(mode: .load(from: defaults), position: IslandPosition.saved(in: defaults), placement: IslandPlacement.load(from: defaults))
        }
        public func apply(to defaults: UserDefaults) {
            mode.save(to: defaults)
            if let position { position.save(to: defaults) } else { defaults.removeObject(forKey: IslandPosition.defaultsKey) }
            if let placement { placement.save(to: defaults) } else { IslandPlacement.clear(from: defaults) }
        }
    }

    public struct Entry: Equatable, Sendable {
        public var place: Place
        /// The display's name when it was last used, for reading the data.
        public var name: String
        public var used: Date
    }

    public private(set) var entries: [String: Entry] = [:]
    public init() {}

    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    public func place(for display: String) -> Place? { entries[display]?.place }

    public mutating func remember(_ place: Place, for display: String, name: String, at date: Date) {
        entries[display] = Entry(place: place, name: name, used: date)
        while entries.count > Self.limit, let oldest = entries.min(by: { $0.value.used == $1.value.used ? $0.key < $1.key : $0.value.used < $1.value.used }) {
            entries[oldest.key] = nil
        }
    }

    /// The island arrives on `display`. It takes the place that display
    /// remembers. A display without one starts from the current place, so
    /// turning the memory on or a first launch moves nothing; one reached by
    /// switching displays takes the notch if it has one, keeping the current
    /// Free Move spot for later. Returns true when the island preferences changed.
    @discardableResult
    public static func arrive(at display: String, name: String, hasNotch: Bool, switched: Bool,
                              defaults: UserDefaults, now: Date = Date()) -> Bool {
        var memory = load(from: defaults)
        let current = Place.current(in: defaults)
        var target = memory.place(for: display) ?? current
        if memory.place(for: display) == nil, switched, hasNotch { target.mode = .notch }
        memory.remember(target, for: display, name: name, at: now)
        memory.save(to: defaults)
        guard target != current else { return false }
        target.apply(to: defaults)
        return true
    }

    /// Keeps the current place for the display the island is on.
    public static func rememberCurrent(for display: String, name: String, defaults: UserDefaults, now: Date = Date()) {
        var memory = load(from: defaults)
        let current = Place.current(in: defaults)
        guard memory.place(for: display) != current else { return }
        memory.remember(current, for: display, name: name, at: now)
        memory.save(to: defaults)
    }

    // MARK: Storage

    private struct Stored: Codable {
        var version = 1
        var displays: [String: StoredEntry]
    }
    private struct StoredEntry: Codable {
        var mode: String?
        var position: String?
        var edge: String?
        var x: Double?
        var y: Double?
        var name: String?
        var used: Double?
    }

    /// Versioned JSON. An entry that cannot be read is dropped on its own;
    /// damaged or oversized data reads as empty.
    public static func load(from defaults: UserDefaults) -> Self {
        var memory = Self()
        guard let data = defaults.data(forKey: defaultsKey), data.count <= byteLimit,
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return memory }
        for (display, entry) in stored.displays where !display.isEmpty {
            guard let mode = entry.mode.flatMap(IslandDisplayMode.init(rawValue:)) else { continue }
            var placement: IslandPlacement?
            if let edge = entry.edge.flatMap(IslandPlacement.Edge.init(rawValue:)), let x = entry.x, let y = entry.y {
                let value = IslandPlacement(edge: edge, x: x, y: y)
                placement = value.isValid ? value : nil
            }
            let place = Place(mode: mode, position: entry.position.flatMap(IslandPosition.init(rawValue:)), placement: placement)
            memory.entries[display] = Entry(place: place, name: entry.name ?? "",
                used: Date(timeIntervalSince1970: entry.used.flatMap { $0.isFinite ? $0 : nil } ?? 0))
        }
        while memory.entries.count > limit, let oldest = memory.entries.min(by: { $0.value.used < $1.value.used }) {
            memory.entries[oldest.key] = nil
        }
        return memory
    }

    public func save(to defaults: UserDefaults) {
        let displays = entries.mapValues { entry in
            StoredEntry(mode: entry.place.mode.rawValue, position: entry.place.position?.rawValue,
                edge: entry.place.placement?.edge.rawValue, x: entry.place.placement?.x, y: entry.place.placement?.y,
                name: String(entry.name.prefix(80)), used: entry.used.timeIntervalSince1970)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(Stored(displays: displays)) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
