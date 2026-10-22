import Foundation

/// Keeps one native maintenance lease through the entire browser sign-in flow.
final class RBNAccountCoordinator {
    private let engine: RcloneEngine
    private let setup = RBNAccountSetup()
    private let acquire: () throws -> Void
    private let release: (Bool) -> Void
    init(engine: RcloneEngine, acquire: @escaping () throws -> Void, release: @escaping (Bool) -> Void) {
        self.engine = engine; self.acquire = acquire; self.release = release
        setup.onFinish = { saved in
            try? engine.setMaintenance(false)
            release(saved)
        }
    }
    func handle(_ method: String, _ arguments: [Any]) throws -> Any {
        let response = try perform(method, arguments)
        if var value = response as? [String: Any], let error = value["error"] as? String, !error.isEmpty {
            let language = RBNLanguageResolver.resolve(engine.settingsSnapshot()["language"] as? String ?? "system")
            value["error"] = RBNNativeStrings.translate(error, language: language)
            return value
        }
        return response
    }
    private func perform(_ method: String, _ arguments: [Any]) throws -> Any {
        func value(_ i: Int) -> Any? { arguments.indices.contains(i) ? arguments[i] : nil }
        func id() throws -> String { try EngineJSON.text(value(0), "設定編號", maximum: 128) }
        switch method {
        case "accountCatalog":
            return try engine.withAuxiliaryOperation {
                let c = try engine.auxiliaryContext()
                return try setup.catalog(context: .init(binary: c.binary, arguments: c.arguments, environment: c.environment))
            }
        case "accountBegin":
            guard let request = value(0) as? [String: Any] else { throw EngineError("帳號設定格式不正確。") }
            try acquire()
            var maintenance = false
            do {
                let c = try engine.auxiliaryContext()
                try engine.setMaintenance(true); maintenance = true
                return try setup.begin(request, context: .init(binary: c.binary, arguments: c.arguments, environment: c.environment))
            } catch {
                if maintenance { try? engine.setMaintenance(false) }
                release(false)
                throw error
            }
        case "accountStatus": return try setup.status(id())
        case "accountAnswer":
            guard let answer = value(1) as? [String: Any] else { throw EngineError("設定答案格式不正確。") }
            return try setup.answer(id(), step: EngineJSON.integer(answer["step"], "設定步驟", 0...Int.max),
                value: answer["value"] as? String, useDefault: answer["useDefault"] as? Bool ?? false)
        case "accountCommit": return try setup.commit(id())
        case "accountCancel": return try setup.cancel(id())
        case "accountBrowserURL": return try setup.browserURL(id()).absoluteString
        default: throw EngineError("不支援的帳號操作。")
        }
    }
}
