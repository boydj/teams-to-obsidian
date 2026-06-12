import Foundation

extension KeyedDecodingContainer {
    /// Decodes a value if present and well-formed, otherwise returns the fallback.
    /// Lets a partial (or slightly wrong) config file still load with defaults.
    func decodeOr<T: Decodable>(_ type: T.Type, _ key: Key, _ fallback: T) -> T {
        guard let decoded = try? decodeIfPresent(type, forKey: key) else { return fallback }
        return decoded ?? fallback
    }
}
