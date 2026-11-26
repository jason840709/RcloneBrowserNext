import Foundation
import Darwin

// Exact 0.11.0 AppMain copyExport, on private synthetic fixtures only.
@main struct MacExportOracle {
    static func copyExport(source: URL, destination: URL) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".rbn-export-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else { try fm.moveItem(at: staging, to: destination) }
    }
    static func attribute(_ path: URL, _ name: String) throws -> Any {
        var buffer=[UInt8](repeating:0,count:64)
        let length=buffer.withUnsafeMutableBytes { getxattr(path.path,name,$0.baseAddress,$0.count,0,0) }
        if length<0 && (errno==ENOATTR || errno==ENOENT) { return NSNull() }
        guard length>=0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
        return String(decoding:buffer.prefix(length),as:UTF8.self)
    }
    static func setAttribute(_ path: URL, _ name: String, _ value: String) throws {
        let bytes=Array(value.utf8)
        guard bytes.withUnsafeBytes({ setxattr(path.path,name,$0.baseAddress,$0.count,0,0) })==0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
    }
    static func snapshot(_ path: URL) throws -> Any {
        var info=Darwin.stat()
        guard lstat(path.path,&info)==0 else {
            if errno==ENOENT { return NSNull() }
            throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))
        }
        let symbolic=(info.st_mode & S_IFMT)==S_IFLNK
        return ["mode":Int(info.st_mode & 0o777),"symlink":symbolic,
            "link":symbolic ? try FileManager.default.destinationOfSymbolicLink(atPath:path.path) : NSNull(),
            "contents":(try? String(contentsOf:path,encoding:.utf8)) as Any? ?? NSNull(),
            "sourceAttribute":try attribute(path,"org.rbn.export.source"),"destinationAttribute":try attribute(path,"org.rbn.export.destination")] as [String:Any]
    }
    static func main() throws {
        guard CommandLine.arguments.count==3 else { throw NSError(domain:"oracle arguments",code:1) }
        let parent=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let fm=FileManager.default
        var cases=[[String:Any]]()
        for name in ["new","existing","same","source-link","destination-link","dangling-destination","missing-source"] {
            let root=parent.appendingPathComponent("mac-export-swift-"+UUID().uuidString,isDirectory:true)
            try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            defer { try? fm.removeItem(at:root) }
            let source=root.appendingPathComponent("source"), target=root.appendingPathComponent("target")
            let destination=name=="same" ? source : root.appendingPathComponent("destination")
            try Data("Target contents".utf8).write(to:target)
            try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
            if name=="source-link" { try fm.createSymbolicLink(atPath:source.path,withDestinationPath:"target") }
            else if name != "missing-source" {
                try Data("Source contents".utf8).write(to:source)
                try fm.setAttributes([.posixPermissions:0o640],ofItemAtPath:source.path)
                try setAttribute(source,"org.rbn.export.source","source-value")
            }
            if name=="existing" || name=="missing-source" {
                try Data("Old destination".utf8).write(to:destination)
                try fm.setAttributes([.posixPermissions:0o604],ofItemAtPath:destination.path)
                try setAttribute(destination,"org.rbn.export.destination","destination-value")
            } else if name=="destination-link" || name=="dangling-destination" {
                try fm.createSymbolicLink(atPath:destination.path,withDestinationPath:name=="destination-link" ? "target" : "absent")
            }
            var error:Any=NSNull()
            do { try copyExport(source:source,destination:destination) }
            catch let failure {
                error=failure.localizedDescription.replacingOccurrences(of:root.path,with:"<ROOT>").replacingOccurrences(of:root.lastPathComponent,with:"<ROOT>").replacingOccurrences(of:"\\.rbn-export-[0-9A-Fa-f-]{36}",with:".rbn-export-<UUID>",options:.regularExpression)
            }
            cases.append(["name":name,"error":error,"source":try snapshot(source),"destination":try snapshot(destination),"target":try snapshot(target),"stagingNames":try fm.contentsOfDirectory(atPath:root.path).filter{$0.hasPrefix(".rbn-export-")}])
        }
        let data=try JSONSerialization.data(withJSONObject:["baseline":"0.11.0 AppMain.copyExport","locale":Locale.current.identifier,"cases":cases],options:[.prettyPrinted,.sortedKeys])
        try data.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
    }
}
