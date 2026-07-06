import Foundation

/// `AttriaxKeyValueStore` backed by a suite-scoped `UserDefaults` (mirrors the
/// Android private `SharedPreferences` file). All device-id / queue / session /
/// first-launch state persists here. The pure engine + tests depend on the
/// `AttriaxKeyValueStore` protocol, never on this class.
///
/// The suite name namespaces the SDK's keys away from the host app's own
/// `UserDefaults.standard`, matching the Android dedicated-prefs-file behavior.
final class AttriaxUserDefaultsStore: AttriaxKeyValueStore {
    static let suiteName = "com.attriax.sdk.prefs"

    private let defaults: UserDefaults

    init() {
        // A suite-scoped UserDefaults. If (very unusually) the suite cannot be
        // created, fall back to `.standard` so persistence still works rather than
        // silently dropping state.
        defaults = UserDefaults(suiteName: Self.suiteName) ?? .standard
    }

    func getString(_ key: String) -> String? {
        defaults.string(forKey: key)
    }

    func putString(_ key: String, _ value: String?) {
        if let value = value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func remove(_ key: String) {
        defaults.removeObject(forKey: key)
    }
}
