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
  func wait(_ initial:[String:Any],allowingError:Bool=false)throws->[String:Any]{var r=initial;let deadline=Date().addingTimeInterval(30);while r["phase"] as? String == "running" && Date()<deadline{Thread.sleep(forTimeInterval:0.04);r=try call(["action":"poll","id":r["id"]!])};try check(r["phase"] as? String != "running","Worker deadline");if r["phase"] as? String == "error" && !allowingError{let message=r["error"] as? String ?? "Unknown";_=try? call(["action":"cancel","id":r["id"]!]);throw EngineError(message)};return r}
  func answer(_ r:[String:Any],_ value:String?=nil)throws->[String:Any]{try wait(call(["action":"answer","id":r["id"]!,"step":r["step"]!,"value":value ?? "","useDefault":value==nil]))}
  func begin(_ name:String,_ mode:String="create",_ provider:String="alias")throws->[String:Any]{try wait(call(["action":"start","name":name,"mode":mode,"provider":provider]))}
  func cancel(_ r:[String:Any])throws{_=try wait(call(["action":"cancel","id":r["id"]!]))}
  func finish(_ r:[String:Any],_ path:String?=nil)throws->[String:Any]{try answer(answer(r,path),"false")}
  func batch(_ name:String,_ provider:String="alias",setup:String="quick",mode:String="create",fields:[String:String]=[:],autoSave:Bool=false,useSharedClient:Bool=true)throws->[String:Any]{try wait(call(["action":"start","name":name,"mode":mode,"provider":provider,"setup":setup,"fields":fields,"autoSave":autoSave,"useSharedClient":useSharedClient]))}
  func waitForBrowser(_ initial:[String:Any])throws->[String:Any]{var r=initial;let deadline=Date().addingTimeInterval(30);while r["phase"] as? String == "running" && r["canOpenBrowser"] as? Bool != true && Date()<deadline{Thread.sleep(forTimeInterval:0.04);r=try call(["action":"poll","id":r["id"]!])};try check(r["phase"] as? String == "running" && r["canOpenBrowser"] as? Bool == true,"Did not reach native OAuth URL: \(r["phase"] ?? "missing") / \((r["question"] as? [String:Any])?["Name"] ?? "") / \(r["error"] ?? "")");return r}
  func serialized(_ value:[String:Any])throws->String{String(decoding:try JSONSerialization.data(withJSONObject:value),as:UTF8.self)}
  func runFixture(_ args:[String],input:Data?=nil,environment:[String:String]=[:])throws->String{
   let p=Process(),output=Pipe(),stdin=input == nil ? nil:Pipe();p.executableURL=URL(fileURLWithPath:CommandLine.arguments[1]);p.arguments=args
   p.environment=ProcessInfo.processInfo.environment.filter{!$0.key.uppercased().hasPrefix("RCLONE_")}.merging(environment){_,new in new}
   p.standardInput=stdin as Any? ?? FileHandle.nullDevice;p.standardOutput=output;p.standardError=FileHandle.nullDevice
   try EnginePlatform.prepare(p);try p.run();try? output.fileHandleForWriting.close()
   if let stdin=stdin,let input=input{try? stdin.fileHandleForReading.close();try stdin.fileHandleForWriting.write(contentsOf:input);try stdin.fileHandleForWriting.close()}
   let data=output.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();try check(p.terminationStatus==0,"Fixture rclone failed");return String(decoding:data,as:UTF8.self)
  }
  test("live provider schema and selected path without credential dump"){
   let r=try call(["action":"info"]);try check((r["providers"] as? [[String:Any]])?.contains{$0["name"] as? String == "drive"} == true,"Drive missing")
   guard let reportedPath=r["configPath"] as? String else{throw EngineError("Missing config path")}
   try check(EnginePlatform.absoluteLocalPath(reportedPath),"Config path is not absolute")
   // rclone uses Windows backslashes, while Foundation URL.path can use
   // forward slashes. Compare the resolved file, not its path spelling.
   try check(try EngineStorage.canonicalLocal(reportedPath)==EngineStorage.canonicalLocal(config.path),"Wrong config: \(reportedPath) (expected \(config.path))")
   try check(try Data(contentsOf:URL(fileURLWithPath:reportedPath))==original,"Selected config contents differ")
   try check(r["requiresUnlock"] as? Bool == false,"Plain config offered unlock")
   let providers=r["providers"] as? [[String:Any]] ?? [],drive=providers.first{$0["name"] as? String == "drive"} ?? [:]
   try check(drive["quickSetup"] as? Bool == true,"Quick profile missing")
   let options=drive["options"] as? [[String:Any]] ?? [];try check(options.contains{$0["Name"] as? String == "client_id"},"Form schema missing")
   try check(options.allSatisfy{$0["Value"] == nil && $0["ValueStr"] == nil},"Schema exposes runtime values")
   try check(options.filter{RBNAccountConfiguration.secret($0)}.allSatisfy{RBNAccountConfiguration.string($0["Default"]).isEmpty && RBNAccountConfiguration.string($0["DefaultStr"]).isEmpty},"Schema exposes sensitive defaults")
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
   let secret="fixture-secret-not-real",encoded=try runFixture(["obscure","-"],input:Data(secret.utf8)).trimmingCharacters(in:.whitespacesAndNewlines)
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
  test("detailed form applies basic and advanced fields without repeated questions"){
   let before=try Data(contentsOf:config),r=try batch("form-alias",setup:"detailed",fields:["remote":target.path,"description":"Form description"]);defer{try? cancel(r)}
   try check(r["phase"] as? String == "ready","Detailed form did not complete")
   try check(r["provider"] as? String == "alias" && r["setup"] as? String == "detailed","Missing form snapshot")
   try check(try Data(contentsOf:config)==before,"Detailed form saved prematurely")
   _=try call(["action":"commit","id":r["id"]!]);let saved=try String(contentsOf:config,encoding:.utf8)
   try check(saved.contains("[form-alias]") && saved.contains("Form description"),"Advanced form value was not saved")
  }
  test("quick form supports schema providers and auto-saves only new accounts"){
   let r=try batch("auto-alias",fields:["remote":target.path],autoSave:true)
   try check(r["phase"] as? String == "committed" && r["autoSave"] as? Bool == true,"New account not committed")
   try check(r["authorizationStarted"] as? Bool == false && r["canOpenBrowser"] as? Bool == false,"Non-OAuth account has authorization state")
   let before=try Data(contentsOf:config),edit=try batch("auto-alias",setup:"detailed",mode:"edit",fields:["description":"Changed later"],autoSave:true);defer{try? cancel(edit)}
   try check(edit["phase"] as? String == "ready" && edit["autoSave"] as? Bool == false,"Edit auto-saved")
   try check(try Data(contentsOf:config)==before,"Edit wrote live config before Save")
   _=try call(["action":"commit","id":edit["id"]!]);let saved=try String(contentsOf:config,encoding:.utf8)
   try check(saved.contains("Changed later") && saved.contains(target.path),"Edit did not preserve current basic default")
  }
  test("unknown form keys and invalid rclone types cannot be persisted"){
   let before=try Data(contentsOf:config)
   try rejects{_=try batch("unknown-field",fields:["remote":target.path,"not_a_provider_option":"value"])}
   try rejects{_=try batch("bad-port","sftp",fields:["host":"127.0.0.1","port":"not-an-integer"])}
   try rejects{_=try batch("bad-bool","sftp",setup:"detailed",fields:["host":"127.0.0.1","set_modtime":"not-a-boolean"])}
   try rejects{_=try batch("bad-password","webdav",fields:["url":"http://127.0.0.1:9","pass":"first\nsecond"])}
   try check(try Data(contentsOf:config)==before,"Invalid form changed live config")
  }
  test("unknown required input pauses safely; auto-save still checks original-file conflicts"){
   let before=try Data(contentsOf:config),r=try batch("auto-conflict",autoSave:true);defer{try? cancel(r)}
   try check(r["phase"] as? String == "question" && r["needsInputReason"] as? String == "additional-input","Missing required field was invented")
   try check((r["question"] as? [String:Any])?["Name"] as? String == "remote","Unexpected required question")
   try rejects{_=try answer(r,"")}
   let external=before+Data("\n# concurrent form edit\n".utf8);try external.write(to:config)
   let failed=try wait(call(["action":"answer","id":r["id"]!,"step":r["step"]!,"value":target.path]),allowingError:true)
   try check(failed["phase"] as? String == "error","Automatic Save bypassed conflict check")
   try check(try Data(contentsOf:config)==external,"Automatic Save overwrote concurrent edit")
  }
  for provider in ["drive","onedrive","dropbox"]{
   test("quick \(provider) reaches native browser OAuth without optional questions"){
    let before=try Data(contentsOf:config),initial=try call(["action":"start","name":"quick-"+provider,"provider":provider,"setup":"quick","fields":[String:String](),"useSharedClient":true,"autoSave":true]);defer{try? cancel(initial)}
    let r=try waitForBrowser(initial),url=try engine.accounts.authorizationURL()
    try check(r["authorizationStarted"] as? Bool == true,"Authorization flag missing")
    try check(RBNAccountConfiguration.allowedAuthorization(url.absoluteString) != nil,"Invalid native authorization URL")
    try check(!(try serialized(r)).contains(url.absoluteString),"OAuth state URL escaped to renderer")
    try check(try Data(contentsOf:config)==before,"Login started with premature live write")
    try cancel(r);let stopped=try call(["action":"poll","id":r["id"]!])
    try check(stopped["phase"] as? String == "cancelled" && stopped["canOpenBrowser"] as? Bool == false,"Cancelled OAuth remains openable")
    try rejects{_=try engine.accounts.authorizationURL()}
   }
  }
  test("Google custom credentials share the form and remain native through OAuth"){
   let id="synthetic-client-id.apps.googleusercontent.com",secret="synthetic-oauth-secret-not-real"
   let initial=try call(["action":"start","name":"custom-google","provider":"drive","setup":"quick","fields":["client_id":id,"client_secret":secret],"useSharedClient":false]);defer{try? cancel(initial)}
   let r=try waitForBrowser(initial),json=try serialized(r)
   try check(!json.contains(id) && !json.contains(secret),"Custom credentials escaped to renderer")
  }
  test("Google custom login without credentials pauses on the real required client ID"){
   let r=try batch("missing-client","drive",useSharedClient:false);defer{try? cancel(r)}
   let q=r["question"] as? [String:Any] ?? [:]
   try check(r["phase"] as? String == "question" && q["Name"] as? String == "client_id" && q["Required"] as? Bool == true,"Required custom client ID was bypassed")
   try rejects{_=try answer(r,"")}
  }
  test("unknown dynamic questions and repeated states stop automatic progress"){
   let unknown:[String:Any]=["Name":"future_required_option","Required":true,"DefaultStr":""]
   if case .pause("additional-input")=AccountSetupPolicy.decision(option:unknown,provider:"drive",setup:"quick",fields:[:],options:[:],useSharedClient:true,advancedVisited:false){}else{throw EngineError("Unknown question was answered automatically")}
   var progress=AccountSetupPolicy.AutomaticProgress()
   try check(progress.permit(state:"opaque-state",name:"same",answer:"true",limit:8),"First state rejected")
   try check(!progress.permit(state:"opaque-state",name:"same",answer:"true",limit:8),"Repeated state was allowed to loop")
   let schema:[String:[String:Any]]=["description":["Advanced":true]]
   let advanced:[String:Any]=["Name":"config_fs_advanced","DefaultStr":"false","Type":"bool"]
   if case .answer("true")=AccountSetupPolicy.decision(option:advanced,provider:"alias",setup:"detailed",fields:["description":"text"],options:schema,useSharedClient:false,advancedVisited:false){}else{throw EngineError("Advanced form fields skipped")}
   if case .answer("false")=AccountSetupPolicy.decision(option:advanced,provider:"alias",setup:"detailed",fields:["description":"text"],options:schema,useSharedClient:false,advancedVisited:true){}else{throw EngineError("Advanced questionnaire re-entered")}
  }
  test("OneDrive quick profile preserves account choice and uses real confirmation names"){
   func decide(_ option:[String:Any])->AccountSetupPolicy.Decision{AccountSetupPolicy.decision(option:option,provider:"onedrive",setup:"quick",fields:[:],options:[:],useSharedClient:true,advancedVisited:false)}
   if case .answer("onedrive")=decide(["Name":"config_type","Examples":[["Value":"onedrive"],["Value":"sharepoint"]]]){}else{throw EngineError("Normal OneDrive profile missing")}
   if case .pause=decide(["Name":"config_driveid","Examples":[["Value":"one"],["Value":"two"]]]){}else{throw EngineError("Multiple drives were guessed")}
   if case .answer("only")=decide(["Name":"config_driveid","Examples":[["Value":"only"]]]){}else{throw EngineError("Single offered drive not selected")}
   if case .answer("true")=decide(["Name":"config_drive_ok","DefaultStr":"true"]){}else{throw EngineError("Drive confirmation name is wrong")}
  }
  test("new WebDAV password is obscured and rclone reveals it for authenticated access"){
   let password="synthetic-webdav-password-秘密",log=root.appendingPathComponent("webdav-fixture.log"),server=Process()
   server.executableURL=URL(fileURLWithPath:CommandLine.arguments[1]);server.arguments=["--config",config.path,"serve","webdav",target.path,"--addr","127.0.0.1:0","--read-only","--log-level","INFO","--log-file",log.path]
   server.environment=ProcessInfo.processInfo.environment.filter{!$0.key.uppercased().hasPrefix("RCLONE_")}.merging(["RCLONE_USER":"fixture","RCLONE_PASS":password]){_,new in new}
   server.standardInput=FileHandle.nullDevice;server.standardOutput=FileHandle.nullDevice;server.standardError=FileHandle.nullDevice
   try EnginePlatform.prepare(server);try server.run();defer{if server.isRunning{server.terminate();server.waitUntilExit()}}
   var url="";let deadline=Date().addingTimeInterval(10),regex=try NSRegularExpression(pattern:#"http://127\.0\.0\.1:[0-9]+/"#)
   while url.isEmpty && server.isRunning && Date()<deadline{let text=(try? String(contentsOf:log,encoding:.utf8)) ?? "";if let match=regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),let range=Range(match.range,in:text){url=String(text[range])}else{Thread.sleep(forTimeInterval:0.04)}}
   try check(!url.isEmpty,"WebDAV fixture did not bind loopback")
   let ready=try batch("password-form","webdav",fields:["url":url,"vendor":"other","user":"fixture","pass":password]);defer{try? cancel(ready)}
   try check(ready["phase"] as? String == "ready","WebDAV form did not complete")
   try check(!(try serialized(ready)).contains(password),"New password exposed")
   let tested=try wait(call(["action":"test","id":ready["id"]!]));try check(tested["tested"] as? Bool == true,"Password did not reveal to the original HTTP credential")
   _=try call(["action":"commit","id":ready["id"]!]);let saved=try String(contentsOf:config,encoding:.utf8)
   try check(!saved.contains(password),"Plaintext password stored")
   let dump=try runFixture(["--config",config.path,"config","dump"])
   let remotes=try JSONSerialization.jsonObject(with:Data(dump.utf8)) as! [String:[String:Any]],encoded=remotes["password-form"]?["pass"] as? String ?? ""
   try check(!encoded.isEmpty && encoded != password,"Obscured password missing")
   let edit=try batch("password-form","webdav",setup:"detailed",mode:"edit",fields:["description":"Keep password"]);defer{try? cancel(edit)}
   try check(!(try serialized(edit)).contains(encoded),"Saved password escaped to renderer")
   let retested=try wait(call(["action":"test","id":edit["id"]!]));try check(retested["tested"] as? Bool == true,"Existing password was obscured twice")
   _=try call(["action":"commit","id":edit["id"]!]);try check(try String(contentsOf:config,encoding:.utf8).contains(encoded),"Unchanged secret was rewritten")
  }
  test("encrypted configs request unlock only while locked and retain encryption on save"){
   let encrypted=root.appendingPathComponent("encrypted.conf"),password="synthetic-config-key-not-real"
   try original.write(to:encrypted);_=try engine.invoke("saveSettings",arguments:[["configPath":encrypted.path]])
   defer{_=try? engine.invoke("saveSettings",arguments:[["configPath":config.path]])}
   _=try runFixture(["--config",encrypted.path,"config","encryption","set"],input:Data((password+"\n"+password+"\n").utf8))
   let locked=try call(["action":"info"]);try check(locked["requiresUnlock"] as? Bool == true,"Encrypted file did not request unlock")
   _=try engine.invoke("unlockConfig",arguments:[password]);let unlocked=try call(["action":"info"])
   try check(unlocked["requiresUnlock"] as? Bool == false,"Unlocked file asks for password again")
   let committed=try batch("encrypted-new",fields:["remote":target.path],autoSave:true);try check(committed["phase"] as? String == "committed","Encrypted automatic save failed")
   let saved=try String(contentsOf:encrypted,encoding:.utf8);try check(saved.contains("RCLONE_ENCRYPT_V0:") && !saved.contains("[encrypted-new]"),"Save removed encryption")
   try check((try call(["action":"info"])["remotes"] as? [[String:Any]])?.contains{$0["name"] as? String == "encrypted-new"} == true,"Encrypted account missing")
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
