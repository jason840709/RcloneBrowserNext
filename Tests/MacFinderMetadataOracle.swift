import Foundation
import Darwin

/// Exact metadata read from 0.11.0 FinderDrop.swift, on synthetic objects only.
@main struct MacFinderMetadataOracle {
    static func main() throws {
        guard CommandLine.arguments.count==3 else { throw NSError(domain:"oracle arguments",code:1) }
        let fm=FileManager.default
        let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).appendingPathComponent("mac-finder-metadata-"+UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? fm.removeItem(at:root) }
        let file=root.appendingPathComponent("regular.txt")
        try Data("Metadata fixture".utf8).write(to:file)
        try fm.createDirectory(at:root.appendingPathComponent("folder"),withIntermediateDirectories:false)
        for (name,target) in [("file-link","regular.txt"),("folder-link","folder"),("broken-link","absent")] {
            try fm.createSymbolicLink(atPath:root.appendingPathComponent(name).path,withDestinationPath:target)
        }
        let fifo=root.appendingPathComponent("fifo")
        guard mkfifo(fifo.path,0o600)==0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
        try Data("Control leaf".utf8).write(to:root.appendingPathComponent("new\nline.txt"))
        try Data("Unicode leaf".utf8).write(to:root.appendingPathComponent("café-e\u{0301}-か\u{3099}-'\".txt"))
        var cases=[[String:Any]]()
        for name in ["regular.txt","folder","file-link","folder-link","broken-link","fifo","new\nline.txt","café-e\u{0301}-か\u{3099}-'\".txt","missing.txt"] {
            do {
                let values=try root.appendingPathComponent(name).resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey,.isRegularFileKey])
                cases.append(["name":name,"flags":[values.isDirectory==true,values.isSymbolicLink==true,values.isRegularFile==true],"error":NSNull()])
            } catch {
                cases.append(["name":name,"flags":NSNull(),"error":error.localizedDescription.replacingOccurrences(of:root.path,with:"<ROOT>").replacingOccurrences(of:root.lastPathComponent,with:"<ROOT>")])
            }
        }
        let data=try JSONSerialization.data(withJSONObject:["baseline":"0.11.0 FinderDrop URL.resourceValues","locale":Locale.current.identifier,"cases":cases],options:[.prettyPrinted,.sortedKeys])
        try data.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
    }
}
