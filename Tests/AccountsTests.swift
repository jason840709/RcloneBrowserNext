import Foundation
#if os(Windows)
import ucrt
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@main struct AccountsTests {
 static var passed=0, failed=0
 static func check(_ x: @autoclosure () throws -> Bool,_ m:String) throws {if try !x(){throw EngineError(m)}}
 static func rejects(_ action:()throws->Void)throws {do{try action()}catch{return};throw EngineError("Expected rejection")}
 static func test(_ title:String,_ action:()throws->Void){do{try action();passed+=1;print("PASS \(title)")}catch{failed+=1;print("FAIL \(title): \(error)")}}
 static func main()throws {
  guard CommandLine.arguments.count>1,!CommandLine.arguments[1].isEmpty else{throw EngineError("Pass the pinned rclone path")}
  let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("rbn-accounts-"+UUID().uuidString)
  try EngineStorage.privateDirectory(root);defer{try? fm.removeItem(at:root)}
  let target=root.appendingPathComponent("target"),config=root.appendingPathComponent("rclone.conf")
  try EngineStorage.privateDirectory(target)
  let original=Data("[existing]\ntype = alias\nremote = \(target.path)\n".utf8);try original.write(to:config)
  let engine=try RcloneEngine(stateDirectory:root.appendingPathComponent("state"),defaultRcloneDirectory:root);defer{engine.shutdown()}
  _=try engine.invoke("saveSettings",arguments:[["rclonePath":CommandLine.arguments[1],"configPath":config.path,"autoCheckUpdates":false]])
  func call(_ r:[String:Any])throws->[String:Any]{try engine.invoke("accountConfig",arguments:[r]) as! [String:Any]}
  func wait(_ initial:[String:Any])throws->[String:Any]{var r=initial;let deadline=Date().addingTimeInterval(20);while r["phase"] as? String == "running" && Date()<deadline{Thread.sleep(forTimeInterval:0.04);r=try call(["action":"poll","id":r["id"]!])};try check(r["phase"] as? String != "running","Worker deadline");if r["phase"] as? String == "error"{throw EngineError(r["error"] as? String ?? "Unknown")};return r}
  func answer(_ r:[String:Any],_ value:String?=nil)throws->[String:Any]{try wait(call(["action":"answer","id":r["id"]!,"step":r["step"]!,"value":value ?? "","useDefault":value==nil]))}
  func begin(_ name:String,_ mode:String="create",_ provider:String="alias")throws->[String:Any]{try wait(call(["action":"start","name":name,"mode":mode,"provider":provider]))}
  func cancel(_ r:[String:Any])throws{_=try wait(call(["action":"cancel","id":r["id"]!]))}
  func finish(_ r:[String:Any],_ path:String?=nil)throws->[String:Any]{try answer(answer(r,path),"false")}
  test("live provider schema and selected path without credential dump"){
   let r=try call(["action":"info"]);try check((r["providers"] as? [[String:Any]])?.contains{$0["name"] as? String == "drive"} == true,"Drive missing")
   guard let reportedPath=r["configPath"] as? String else{throw EngineError("Missing config path")}
   try check(EnginePlatform.absoluteLocalPath(reportedPath),"Config path is not absolute")
   // rclone uses Windows backslashes, while Foundation URL.path can use
   // forward slashes. Compare the resolved file, not its path spelling.
   try check(try EngineStorage.canonicalLocal(reportedPath)==EngineStorage.canonicalLocal(config.path),"Wrong config: \(reportedPath) (expected \(config.path))")
   try check(try Data(contentsOf:URL(fileURLWithPath:reportedPath))==original,"Selected config contents differ")
  }
  test("new account staged until explicit commit; real alias connection test"){
   let r=try begin("new-alias");try check((r["question"] as? [String:Any])?["Name"] as? String == "remote","Wrong question")
   let ready=try finish(r,target.path);try check(ready["phase"] as? String == "ready","Not ready");try check(try Data(contentsOf:config)==original,"Premature write")
   let tested=try wait(call(["action":"test","id":r["id"]!]));try check(tested["tested"] as? Bool == true,"Listing failed")
   _=try call(["action":"commit","id":r["id"]!]);try check(try String(contentsOf:config,encoding:.utf8).contains("[new-alias]"),"Missing account")
  }
  test("required answers, stale steps, parallel setup and path changes rejected"){
   let r=try begin("validation");defer{try? cancel(r)}
   try rejects{_=try call(["action":"answer","id":r["id"]!,"step":r["step"]!,"value":""])}
   try rejects{_=try call(["action":"answer","id":r["id"]!,"step":-1,"value":target.path])}
   try rejects{_=try call(["action":"start","name":"other","provider":"alias"])}
   try rejects{_=try engine.invoke("saveSettings",arguments:[["configPath":root.appendingPathComponent("other.conf").path]])}
  }
  test("cancellation preserves original bytes and removes owned staging"){
   let before=try Data(contentsOf:config),r=try begin("cancel-me");_=try finish(r,target.path);try cancel(r)
   try check(try Data(contentsOf:config)==before,"Cancel wrote original");try check(try fm.contentsOfDirectory(atPath:root.path).filter{$0.hasPrefix(".rbn-account-")}.isEmpty,"Staging remains")
  }
  test("repeated cancellation never releases another maintenance owner"){
   let r=try begin("lease");try cancel(r);try engine.setMaintenance(true);defer{try? engine.setMaintenance(false)}
   _=try call(["action":"cancel","id":r["id"]!]);try rejects{_=try engine.auxiliaryContext()}
  }
  test("edit retains defaults and unrelated accounts"){
   let r=try begin("existing","edit");try check((r["question"] as? [String:Any])?["Default"] as? String == target.path,"Default lost")
   _=try finish(r);_=try call(["action":"commit","id":r["id"]!]);let text=try String(contentsOf:config,encoding:.utf8);try check(text.contains("[new-alias]") && text.contains("[existing]"),"Account lost")
  }
  test("external edits cause conflict instead of being overwritten"){
   let before=try Data(contentsOf:config),r=try begin("conflict");defer{try? cancel(r)};_=try finish(r,target.path)
   let external=before+Data("\n# external edit\n".utf8);try external.write(to:config)
   try rejects{_=try call(["action":"commit","id":r["id"]!])};try check(try Data(contentsOf:config)==external,"External change lost")
  }
  test("account removal requires explicit commit and retains other accounts"){
   let before=try Data(contentsOf:config),r=try begin("new-alias","delete");try check(try Data(contentsOf:config)==before,"Premature delete")
   _=try call(["action":"commit","id":r["id"]!]);let text=try String(contentsOf:config,encoding:.utf8);try check(!text.contains("[new-alias]") && text.contains("[existing]"),"Deletion scope")
  }
  test("stored passwords never reach the renderer; keeping default preserves secret"){
   let secret="fixture-secret-not-real",process=Process(),pipe=Pipe();process.executableURL=URL(fileURLWithPath:CommandLine.arguments[1]);process.arguments=["obscure",secret];process.standardOutput=pipe
   try EnginePlatform.prepare(process);try process.run();process.waitUntilExit();let encoded=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
   var text=try String(contentsOf:config,encoding:.utf8);text+="\n[private-fixture]\ntype = webdav\nurl = http://127.0.0.1:9\nvendor = other\nuser = fixture\npass = \(encoded)\n";try Data(text.utf8).write(to:config)
   var r=try begin("private-fixture","edit"),saw=false;defer{try? cancel(r)}
   for _ in 0..<30{if r["phase"] as? String == "ready"{break};let q=r["question"] as? [String:Any] ?? [:],json=String(decoding:try JSONSerialization.data(withJSONObject:r),as:UTF8.self);try check(!json.contains(secret) && !json.contains(encoded),"Secret exposed");if q["Name"] as? String == "pass"{saw=true;try check(q["HasSavedValue"] as? Bool == true,"Saved marker missing")};r=try answer(r)}
   try check(saw && r["phase"] as? String == "ready","Incomplete questionnaire");_=try call(["action":"commit","id":r["id"]!]);try check(try String(contentsOf:config,encoding:.utf8).contains(encoded),"Secret changed")
  }
  test("Google shared-client warning becomes a required client ID rather than an empty loop"){
   let before=try Data(contentsOf:config);var r=try begin("google-fixture","create","drive");defer{try? cancel(r)}
   var sawShared=false,sawRequired=false
   for _ in 0..<12{
    let q=r["question"] as? [String:Any] ?? [:],name=q["Name"] as? String ?? ""
    if name=="config_shared_client_id"{sawShared=true}
    if name=="client_id" && q["Required"] as? Bool == true{sawRequired=true;try rejects{_=try answer(r,"")};break}
    r=try answer(r,name=="scope" ? "drive" : nil)
   }
   try check(sawShared && sawRequired,"Did not reach required client ID");try check(try Data(contentsOf:config)==before,"Google setup changed live file")
  }
  test("OneDrive browser decision comes from its current questionnaire"){
   var r=try begin("microsoft-fixture","create","onedrive");defer{try? cancel(r)};var browser=false
   for _ in 0..<15{
    let q=r["question"] as? [String:Any] ?? [:]
    if q["Name"] as? String == "config_is_local"{browser=true;break}
    r=try answer(r)
   }
   try check(browser,"Missing provider browser decision")
  }
  test("new config file and Unicode remote name are supported"){
   let missing=root.appendingPathComponent("new.conf");try Data().write(to:missing);_=try engine.invoke("saveSettings",arguments:[["configPath":missing.path]]);try fm.removeItem(at:missing)
   let r=try begin("測試-日本語");_=try finish(r,target.path);try check(!fm.fileExists(atPath:missing.path),"Premature file")
   _=try call(["action":"commit","id":r["id"]!]);try check(try String(contentsOf:missing,encoding:.utf8).contains("[測試-日本語]"),"Unicode lost")
  }
  test("authorization URLs restricted to local rclone OAuth endpoint"){
   for good in ["http://127.0.0.1:53682/auth?state=fixture","http://localhost:5000/auth?state=123"]{try check(RBNAccountConfiguration.allowedAuthorization(good) != nil,"Good URL rejected")}
   for bad in ["https://example.com/auth?state=x","http://127.0.0.1:80/auth?state=x","http://user@localhost:5000/auth?state=x","http://localhost:5000/admin?state=x","http://localhost:5000/auth","file:///tmp/a"]{try check(RBNAccountConfiguration.allowedAuthorization(bad)==nil,"Unsafe URL")};try rejects{_=try engine.accounts.authorizationURL()}
  }
  test("invalid account names rejected before invoking rclone"){
   for name in ["","../evil","bad:name","-option","line\nbreak","[remote]"," leading"]{try check(!RBNAccountConfiguration.validName(name),"Invalid name accepted")}
  }
  print("RESULT \(passed) passed, \(failed) failed");if failed>0{exit(1)}
 }
}
