import Foundation

/// Decisions for the single-page forms. Provider state strings remain opaque;
/// only options advertised by this rclone and named, reviewed OAuth questions
/// can be answered automatically.
enum AccountSetupPolicy {
    static let oauthProviders: Set<String> = ["drive", "onedrive", "dropbox"]

    enum Decision {
        case answer(String)
        case pause(String)
    }

    struct AutomaticProgress {
        private var answered = Set<String>()
        private var count = 0
        mutating func permit(state: String, name: String, answer: String, limit: Int) -> Bool {
            // Secrets remain in native memory and are discarded with the session.
            let key = state + "\u{0}" + name + "\u{0}" + answer
            guard count < limit, answered.insert(key).inserted else { return false }
            count += 1
            return true
        }
        mutating func reset() { answered.removeAll(); count = 0 }
    }

    static func visibleOptions(_ provider: [String: Any]) -> [[String: Any]] {
        (provider["Options"] as? [[String: Any]] ?? []).filter {
            guard let name = $0["Name"] as? String, !name.isEmpty else { return false }
            // rclone's OptionHideConfigurator bit is 2; command-line-only
            // options must not become an undocumented form input.
            return (number($0["Hide"]) & 2) == 0
        }
    }

    static func sanitizedOption(_ option: [String: Any]) -> [String: Any] {
        var value = option
        value.removeValue(forKey: "Value")
        value.removeValue(forKey: "ValueStr")
        if RBNAccountConfiguration.secret(option) {
            value["Default"] = ""
            value["DefaultStr"] = ""
            value["Sensitive"] = true
        }
        return value
    }

    static func validateFields(_ fields: [String: String], options: [String: [String: Any]]) throws {
        guard fields.count <= 512,
              fields.values.reduce(0, { $0 + $1.utf8.count }) <= 512 * 1024 else {
            throw EngineError("There are too many account fields. Use a credential file for large credentials.")
        }
        for (key, value) in fields {
            guard options[key] != nil else {
                throw EngineError("An account field is not supported by the selected rclone provider. Reload the account form.")
            }
            guard value.utf8.count <= 16384, !value.utf8.contains(0) else {
                throw EngineError("An account field is too long. Use a credential file for large credentials.")
            }
            if options[key]?["IsPassword"] as? Bool == true, value.contains("\n") || value.contains("\r") {
                throw EngineError("This password contains a line break. Use a credential file or the terminal config tool.")
            }
        }
    }

    static func decision(option: [String: Any], provider: String, setup: String,
                         fields: [String: String], options: [String: [String: Any]],
                         useSharedClient: Bool, advancedVisited: Bool) -> Decision {
        let name = RBNAccountConfiguration.string(option["Name"])
        let fallback = option["DefaultStr"] as? String ?? RBNAccountConfiguration.string(option["Default"])
        let required = option["Required"] as? Bool == true

        if name == "config_fs_advanced" {
            let requested = fields.keys.contains { options[$0]?["Advanced"] as? Bool == true }
            return checked(!advancedVisited && requested ? "true" : "false", option: option)
        }

        if let schema = options[name] {
            if let supplied = fields[name] {
                return checked(supplied, option: option)
            }
            if setup == "quick", provider == "drive", name == "scope", fallback.isEmpty {
                return advertised("drive", option: option)
            }
            // Required schema inputs with no current value need user input.
            // Optional inputs keep rclone's current default, including saved
            // passwords, rather than a stale copy from the renderer.
            if required && fallback.isEmpty { return .pause("additional-input") }
            if schema["Advanced"] as? Bool == true && !advancedVisited {
                return .pause("provider-changed")
            }
            return checked(fallback, option: option)
        }

        guard oauthProviders.contains(provider) else { return .pause("additional-input") }
        switch name {
        case "config_shared_client_id" where provider == "drive":
            // A user-selected built-in login must not accept rclone's `false`
            // default: that deliberately switches to required custom clients.
            return checked(useSharedClient ? "true" : "false", option: option)
        case "config_is_local":
            return checked("true", option: option)
        case "config_change_team_drive" where provider == "drive" && setup == "quick":
            return checked("false", option: option)
        case "config_type" where provider == "onedrive" && setup == "quick":
            return advertised("onedrive", option: option)
        case "config_driveid" where provider == "onedrive" && setup == "quick":
            let choices = option["Examples"] as? [[String: Any]] ?? []
            guard choices.count == 1 else { return .pause("additional-input") }
            return checked(RBNAccountConfiguration.string(choices[0]["Value"]), option: option)
        case "config_drive_ok" where provider == "onedrive" && setup == "quick":
            return checked("true", option: option)
        default:
            return .pause("additional-input")
        }
    }

    private static func advertised(_ value: String, option: [String: Any]) -> Decision {
        guard let choices = option["Examples"] as? [[String: Any]],
              choices.contains(where: { RBNAccountConfiguration.string($0["Value"]) == value }) else {
            return .pause("provider-changed")
        }
        return checked(value, option: option)
    }

    private static func checked(_ value: String, option: [String: Any]) -> Decision {
        if option["Required"] as? Bool == true && value.isEmpty { return .pause("additional-input") }
        if option["Exclusive"] as? Bool == true,
           let choices = option["Examples"] as? [[String: Any]], !choices.isEmpty,
           !choices.contains(where: { RBNAccountConfiguration.string($0["Value"]) == value }) {
            return .pause("provider-changed")
        }
        return .answer(value)
    }

    private static func number(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}
