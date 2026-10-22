#if os(macOS)
import Foundation
@preconcurrency import AppKit

@main struct MacCompletionTests {
    static var passed=0,failed=0
    static func expect(_ condition: Bool,_ message:String)throws{if !condition{throw NSError(domain:message,code:1)}}
    static func test(_ title:String,_ action:()throws->Void){do{try action();passed+=1;print("PASS \(title)")}catch{failed+=1;print("FAIL \(title): \(error)")}}
    static func job(_ id:String,_ status:String="completed",dry:Bool=false)->[String:Any]{["id":id,"status":status,"request":["dryRun":dry]]}
    static func main(){
        _ = NSApplication.shared
        var requests=[NSApplication.RequestUserAttentionType](), cancelled=[Int]()
        let a=RBNCompletionAttention(request:{requests.append($0);return requests.count},cancel:{cancelled.append($0)})
        test("background completion uses persistent critical attention"){
            try expect(a.consume(job("one"),enabled:true,isActive:false,isTerminating:false),"completion consumed")
            try expect(requests == [.criticalRequest],"must continue until acknowledged")
        }
        test("duplicate terminal events and parallel completions do not restart the bounce"){
            try expect(!a.consume(job("one"),enabled:true,isActive:false,isTerminating:false),"duplicate event")
            _ = a.consume(job("two"),enabled:true,isActive:false,isTerminating:false)
            _ = a.consume(job("three","failed"),enabled:true,isActive:false,isTerminating:false)
            try expect(requests.count==1 && cancelled.isEmpty,"one pending request")
        }
        test("a covered or minimized window does not acknowledge completion"){
            a.reconcile(enabled:true,isWindowPresented:false)
            try expect(cancelled.isEmpty,"hidden window acknowledged")
        }
        test("menu-only activation retains pending result after AppKit clears its request"){
            a.reconcile(enabled:true,isWindowPresented:false,applicationActivated:true)
            try expect(cancelled==[1] && requests.count==2,"result must remain pending")
        }
        test("showing the main window acknowledges completion exactly once"){
            a.reconcile(enabled:true,isWindowPresented:true);a.reconcile(enabled:true,isWindowPresented:true)
            try expect(cancelled==[1,2],"cancel must be idempotent")
        }
        test("switching away after acknowledging never replays completion"){
            a.reconcile(enabled:true,isWindowPresented:false)
            try expect(requests.count==2,"old result replayed")
        }
        test("foreground visible completion remains silent"){
            _ = a.consume(job("front"),enabled:true,isActive:true,isTerminating:false,isWindowPresented:true)
            try expect(requests.count==2,"foreground request")
        }
        test("active app with hidden window retains its result"){
            _ = a.consume(job("hidden"),enabled:true,isActive:true,isTerminating:false,isWindowPresented:false)
            try expect(requests.count==3,"hidden completion lost")
            a.reconcile(enabled:true,isWindowPresented:true)
        }
        test("turning off Dock attention cancels without disabling banners"){
            _ = a.consume(job("before-off"),enabled:true,isActive:false,isTerminating:false)
            a.reconcile(enabled:false,isWindowPresented:false)
            try expect(cancelled==[1,2,3,4],"off did not cancel")
            try expect(a.consume(job("off"),enabled:false,isActive:false,isTerminating:false),"banner eligibility")
            a.reconcile(enabled:true,isWindowPresented:false)
            try expect(requests.count==4,"enabling replayed completion")
        }
        test("cancelled interrupted preview and running jobs stay silent"){
            for state in ["queued","running","cancelling","cancelled","interrupted","paused"]{try expect(!a.consume(job(state,state),enabled:true,isActive:false,isTerminating:false),state)}
            for state in ["completed","failed"]{try expect(!a.consume(job("dry-"+state,state,dry:true),enabled:true,isActive:false,isTerminating:false),"preview")}
        }
        test("terminating and malformed events create no attention"){
            try expect(!a.consume(job("quit"),enabled:true,isActive:false,isTerminating:true),"termination")
            for value:[String:Any] in [[:],job(""),["id":"missing-request","status":"completed"]]{try expect(!a.consume(value,enabled:true,isActive:false,isTerminating:false),"malformed")}
        }
        test("AppKit rejection while active is retried until acknowledgment"){
            var count=0
            let b=RBNCompletionAttention(request:{_ in count+=1;return count==1 ? -1 : 42},cancel:{_ in})
            _ = b.consume(job("wait"),enabled:true,isActive:true,isTerminating:false,isWindowPresented:false)
            b.reconcile(enabled:true,isWindowPresented:false)
            try expect(count==2,"pending result dropped")
            b.reconcile(enabled:true,isWindowPresented:true);b.reconcile(enabled:true,isWindowPresented:false)
            try expect(count==2,"replayed acknowledged result")
        }
        test("termination clears an outstanding request"){
            _ = a.consume(job("finish-quit"),enabled:true,isActive:false,isTerminating:false)
            a.cancel();a.cancel();try expect(cancelled==[1,2,3,4,5],"outstanding request")
        }
        test("real AppKit critical request and cancellation APIs execute"){
            let native=RBNCompletionAttention()
            _ = native.consume(job("native-smoke"),enabled:true,isActive:false,isTerminating:false)
            native.cancel()
            // API execution is not a visual Dock-pixel test.
        }
        print("RESULT \(passed) passed, \(failed) failed")
        if failed>0{exit(1)}
    }
}
#endif
