// TEST ONLY: exact 0.11.0 settings fixture, not product policy.
import Foundation
extension RcloneEngine {
    static func defaultSettings(directory: URL) -> [String: Any] {
        ["rclonePath": "", "rcloneDirectory": directory.path, "configPath": "", "language": "system", "theme": "purple-auto", "interfaceScale": 100,
         "autoCheckUpdates": true, "skippedRcloneVersion": "", "settingsRevision": 0, "settingsSchemaVersion": 7,
         "paneColumnWidths": [String: Any](), "defaultTransferOptions": EngineTransferOptions.defaults,
         "hiddenBuiltinPresets": [String](),
         "maxConcurrentJobs": 0, EngineRetryScope.settingKey: EngineRetryScope.defaultValue, "proxyMode": "system", "httpProxy": "", "httpsProxy": "", "noProxy": "",
         "networkOptions": EngineNetworkOptions.defaults,
         "defaultRcloneOptions": [String](), "showStatusItem": false, "notifyOnCompletion": false, "bounceDockOnCompletion": true,
         "showHiddenFiles": true, "showFolderIcons": true, "showFileIcons": true, "alternatingRows": true,
         "streamPlayerPath": "", "streamPlayerArguments": ["-"], "initialLocations": [String: Any](), "savedWorkspace": NSNull()] as [String: Any]
    }
}
