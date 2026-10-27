import Foundation
import CoreMedia

/// Reads and merges the shared clip payload through the current FxPlug session.
enum HeaderCustomParameterStorage {
    /// A failed read is distinct from a successfully retrieved empty parameter.
    /// Passing this value also prevents retrying failed IPC in each decoder.
    struct Snapshot {
        let dictionary: NSDictionary?
    }

    static func dictionaryValue(
        for key: String,
        using retrieval: any FxParameterRetrievalAPI_v6,
        storage: Snapshot? = nil
    ) -> NSDictionary? {
        guard let storage = (storage ?? storageDictionary(using: retrieval)).dictionary else { return nil }
        if let dictionary = storage[NSString(string: key)] as? NSDictionary {
            return dictionary
        }
        return storage[key] as? NSDictionary
    }

    @discardableResult
    static func setDictionary(
        _ dictionary: NSDictionary,
        for key: String,
        using apiManager: any PROAPIAccessing
    ) -> Bool {
        guard let settingAPI = apiManager.api(for: (any FxParameterSettingAPI_v5).self) as? any FxParameterSettingAPI_v5 else {
            return false
        }

        guard let retrieval = apiManager.api(for: (any FxParameterRetrievalAPI_v6).self) as? any FxParameterRetrievalAPI_v6,
              let existing = storageDictionary(using: retrieval).dictionary else {
            // A failed read is not an empty clip. Never discard saved assets,
            // hints or analysis while updating a different part of the payload.
            PluginLog.error("Could not read custom parameter 50. Reset All or reapply the updated effect before editing hints.")
            return false
        }
        let storage = NSMutableDictionary(dictionary: existing)
        storage[NSString(string: HeaderStorageKey.schemaVersion)] = NSNumber(value: 1)
        storage[NSString(string: key)] = dictionary

        let value = storage.copy() as? NSDictionary ?? NSDictionary()
        return settingAPI.setCustomParameterValue(
            value,
            toParameter: ParameterIdentifier.headerSummary,
            at: CMTime.zero
        )
    }

    /// Read once per state capture, then share the immutable dictionary across decoders.
    static func storageDictionary(using retrieval: any FxParameterRetrievalAPI_v6) -> Snapshot {
        var rawValue: (any NSCopying & NSObjectProtocol & NSSecureCoding)?
        let succeeded = retrieval.getCustomParameterValue(
            &rawValue,
            fromParameter: ParameterIdentifier.headerSummary,
            at: CMTime.zero
        )
        return Snapshot(dictionary: succeeded ? rawValue as? NSDictionary : nil)
    }
}
