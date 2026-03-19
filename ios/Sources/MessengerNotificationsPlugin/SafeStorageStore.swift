import Foundation

public enum SafeStorageStore {
    private static let rootKey = "messenger_plugin_storage"

    public static func getAll() -> [String: String] {
        guard let dict = UserDefaults.standard.dictionary(forKey: rootKey) as? [String: String] else {
            return [:]
        }
        return dict
    }

    public static func get(_ key: String) -> String? {
        return getAll()[key]
    }

    public static func set(_ key: String, value: String?) {
        var dict = getAll()
        dict[key] = value
        UserDefaults.standard.set(dict, forKey: rootKey)
    }

    public static func remove(_ key: String) {
        var dict = getAll()
        dict.removeValue(forKey: key)
        UserDefaults.standard.set(dict, forKey: rootKey)
    }
}
