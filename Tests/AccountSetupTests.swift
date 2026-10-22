import Foundation
#if os(Windows)
import ucrt
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main struct AccountSetupTests {
    static var passed = 0, failed = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw EngineError(message) }
    }
    static func test(_ name: String, _ block: () throws -> Void) {
        do { try block(); passed += 1; print("PASS \(name)") }
        catch { failed += 1; print("FAIL \(name): \(error)") }
    }
    static func rejects(_ block: () throws -> Void) throws {
        do { try block() } catch { return }
        throw EngineError("Expected rejection")
    }
    static func wait(_ wizard: RBNAccountSetup, _ id: String) throws -> [String: Any] {
        let end = Date().addingTimeInterval(30)
        while Date() < end {
            let s = try wizard.status(id)
            if !["working","cancelling","saving"].contains(s["phase"] as? String ?? "") { return s }
            Thread.sleep(forTimeInterval: 0.04)
        }
        throw EngineError("Wizard exceeded test deadline")
    }
    static func question(_ wizard: RBNAccountSetup, _ id: String) throws -> [String: Any] {
        let s = try wait(wizard, id)
        try expect(s["phase"] as? String == "question", "Expected question, got \(s)")
        return s
    }
    static func answer(_ wizard: RBNAccountSetup, _ id: String, _ value: String? = nil, useDefault: Bool = false) throws -> [String: Any] {
        let s = try question(wizard,id)
        _ = try wizard.answer(id,step:s["step"] as! Int,value:value,useDefault:useDefault)
        return try wait(wizard,id)
    }
    static func finishAlias(_ wizard: RBNAccountSetup, _ id: String, path: String) throws {
        let first = try question(wizard,id)
        try expect((first["option"] as? [String:Any])?["Name"] as? String == "remote", "Alias field missing")
        _ = try answer(wizard,id,path)
        for _ in 0..<12 {
            let s = try wait(wizard,id)
            if s["phase"] as? String == "ready" { return }
            _ = try answer(wizard,id,useDefault:true)
        }
        throw EngineError("Alias setup did not reach ready")
    }
    static func main() throws {
        guard CommandLine.arguments.count > 1, !CommandLine.arguments[1].isEmpty else { print("SKIP AccountSetupTests: supply an rclone executable"); return }
        let binary = CommandLine.arguments[1]
        let root = (CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : FileManager.default.temporaryDirectory).appendingPathComponent("accounts-"+UUID().uuidString)
        try EngineStorage.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at:root) }
        let config = root.appendingPathComponent("accounts.conf"), target = root.appendingPathComponent("資料 path")
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        let original = "[existing]\ntype = alias\nremote = \(target.path)\n"
        try Data(original.utf8).write(to:config)
        let context=RcloneTools.Context(binary:binary,arguments:["--config=\(config.path)"],environment:ProcessInfo.processInfo.environment.filter{!$0.key.uppercased().hasPrefix("RCLONE_")})
        let wizard=RBNAccountSetup()
        var savedCalls=0,cancelCalls=0
        wizard.onFinish={if $0 {savedCalls+=1}else{cancelCalls+=1}}
        func begin(_ name:String,_ mode:String="create",_ provider:String="alias")throws->String {
            let result=try wizard.begin(["name":name,"mode":mode,"provider":provider],context:context)
            return result["id"] as! String
        }
        func cancel(_ id:String)throws{_ = try wizard.cancel(id); _ = try wait(wizard,id)}
        test("installed rclone supplies providers and selected config path") {
            let catalog=try wizard.catalog(context:context)
            try expect((catalog["providers"] as? [[String:Any]] ?? []).contains{$0["name"] as? String == "drive"},"Drive missing")
            try expect((catalog["providers"] as? [[String:Any]] ?? []).contains{$0["name"] as? String == "onedrive"},"OneDrive missing")
            try expect(catalog["configPath"] as? String == config.path,"Selected config ignored")
        }
        test("create follows live JSON fields and only Save mutates the real config") {
            let id=try begin("created")
            try finishAlias(wizard,id,path:target.path)
            try expect(try String(contentsOf:config,encoding:.utf8)==original,"Changed before Save")
            _ = try wizard.commit(id)
            try expect(try String(contentsOf:config,encoding:.utf8).contains("[created]"),"Missing saved remote")
            try expect(savedCalls==1,"Save callback")
        }
        test("editing then cancelling preserves exact original bytes") {
            let baseline=try Data(contentsOf:config),id=try begin("created","edit")
            try finishAlias(wizard,id,path:root.appendingPathComponent("other").path)
            try cancel(id)
            try expect(try Data(contentsOf:config)==baseline,"Cancelled edits changed config")
        }
        test("required fields and stale answers cannot advance the protocol") {
            let id=try begin("invalid-step");let state=try question(wizard,id),step=state["step"] as! Int
            try rejects{_ = try wizard.answer(id,step:step,value:"",useDefault:false)}
            try rejects{_ = try wizard.answer(id,step:step+1,value:target.path,useDefault:false)}
            try expect((try wizard.status(id))["step"] as? Int == step,"Invalid answer consumed step")
            try cancel(id)
        }
        test("concurrent config changes refuse replacement and remain intact") {
            let id=try begin("conflict");try finishAlias(wizard,id,path:target.path)
            let modified=try Data(contentsOf:config)+Data("\n# written by another process\n".utf8)
            try modified.write(to:config)
            try rejects{_ = try wizard.commit(id)}
            try expect(try Data(contentsOf:config)==modified,"External edit overwritten")
            try cancel(id)
        }
        test("duplicate account names never overwrite existing remotes") {
            let baseline=try Data(contentsOf:config),id=try begin("existing")
            let status=try wait(wizard,id)
            try expect(status["phase"] as? String == "error","Duplicate accepted")
            try cancel(id);try expect(try Data(contentsOf:config)==baseline,"Duplicate changed config")
        }
        test("delete is staged and does not delete underlying files") {
            let file=target.appendingPathComponent("keep.txt");try Data("keep".utf8).write(to:file)
            let id=try begin("created","delete")
            try expect((try wait(wizard,id))["phase"] as? String == "ready","Delete not staged")
            try expect(try String(contentsOf:config,encoding:.utf8).contains("[created]"),"Deleted before confirmation")
            _ = try wizard.commit(id)
            try expect(!(try String(contentsOf:config,encoding:.utf8)).contains("[created]"),"Account not removed")
            try expect(try String(contentsOf:file,encoding:.utf8)=="keep","Underlying file deleted")
        }
        test("Google required own-client flow is a visible question") {
            let id=try begin("google-probe","create","drive")
            var sawClient=false,sawShared=false
            for _ in 0..<14 {
                let s=try question(wizard,id),q=s["option"] as! [String:Any],name=q["Name"] as! String
                if name=="client_id" {sawClient=true;if q["Required"] as? Bool == true {break}}
                if name.contains("shared") {sawShared=true}
                if name=="config_is_local" {break}
                _ = try answer(wizard,id,useDefault:true)
            }
            try expect(sawClient,"Google client question missing")
            if sawShared {let s=try question(wizard,id);try expect((s["option"] as? [String:Any])?["Name"] as? String == "client_id","Expected own ID")}
            try cancel(id)
        }
        test("OneDrive exposes its browser authorization question") {
            let id=try begin("microsoft-probe","create","onedrive")
            var found=false
            for _ in 0..<16 {
                let s=try question(wizard,id),q=s["option"] as! [String:Any]
                if q["Name"] as? String == "config_is_local" {found=true;break}
                _ = try answer(wizard,id,useDefault:true)
            }
            try expect(found,"Browser question missing");try cancel(id)
        }
        test("password values stay masked when an account is edited") {
            let added="\n[ftp-private]\ntype = ftp\nhost = localhost\nuser = fixture\npass = abc\n"
            let before=try Data(contentsOf:config);try (before+Data(added.utf8)).write(to:config)
            let id=try begin("ftp-private","edit","ftp")
            var masked=false
            for _ in 0..<12 {
                let s=try question(wizard,id),q=s["option"] as! [String:Any]
                if q["Name"] as? String == "pass" {
                    try expect(q["IsPassword"] as? Bool == true,"Password not masked")
                    try expect(q["Default"] as? String == "","Secret default leaked")
                    try expect(q["Value"]==nil && s["State"]==nil,"Opaque values exposed")
                    masked=true;break
                }
                _ = try answer(wizard,id,useDefault:true)
            }
            try expect(masked,"Password field missing");try cancel(id);try before.write(to:config)
        }
        test("finished and cancelled sessions remove staged files") {
            try expect(try FileManager.default.contentsOfDirectory(atPath:root.path).allSatisfy{!$0.hasPrefix(".rbn-account-")},"Staged credentials remain")
            try expect(cancelCalls>=7,"Missing release callbacks")
        }
        test("authorization links reject external and arbitrary local endpoints") {
            try expect(RBNAccountSetup.permittedAuthURL(URL(string:"http://127.0.0.1:53682/auth?state=test")!),"Valid callback rejected")
            for value in ["https://evil.example/auth","http://localhost:53682/admin","file:///tmp/key","http://user@localhost:53682/auth","http://localhost/auth"] {try expect(!RBNAccountSetup.permittedAuthURL(URL(string:value)!),"Accepted \(value)")}
        }
        print("RESULT \(passed) passed, \(failed) failed")
        if failed>0 {exit(1)}
    }
}
