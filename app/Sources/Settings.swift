import Foundation

enum Settings {
    private static let defaults = UserDefaults.standard

    /// Route through the proxy automatically.
    static var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    /// Engage only when the Bluetooth output reports at least this much latency; 0 = always.
    static var thresholdMs: Double {
        get { defaults.object(forKey: "thresholdMs") as? Double ?? 500 }
        set { defaults.set(newValue, forKey: "thresholdMs") }
    }

    /// Latency the proxy reports to players (how long they delay the picture).
    static var latencyMs: Double {
        get { defaults.object(forKey: "latencyMs") as? Double ?? 250 }
        set { defaults.set(max(0, min(1000, newValue)), forKey: "latencyMs") }
    }
}
