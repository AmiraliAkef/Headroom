import Foundation
import HeadroomCore

/// Display preferences in UserDefaults. Launch-at-login state is never stored here;
/// it is read live from SMAppService (see LoginItem).
enum Settings {
    private static let defaults = UserDefaults.standard
    static let refreshChoices: [TimeInterval] = [1, 2, 5]

    static var displayMode: DisplayMode {
        get { defaults.string(forKey: "displayMode").flatMap(DisplayMode.init(rawValue:)) ?? .full }
        set { defaults.set(newValue.rawValue, forKey: "displayMode") }
    }

    /// Adds an available-RAM segment to the menu bar label, in the current mode's style.
    static var showAvailable: Bool {
        get { defaults.bool(forKey: "showAvailable") }
        set { defaults.set(newValue, forKey: "showAvailable") }
    }

    static var refreshInterval: TimeInterval {
        get {
            let v = defaults.double(forKey: "refreshInterval")
            return refreshChoices.contains(v) ? v : 2
        }
        set { defaults.set(newValue, forKey: "refreshInterval") }
    }
}
