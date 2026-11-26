import Foundation

/// Records the exact API used by the unchanged 0.11.0 Mac file/volume sorter.
/// Inputs are synthetic text only; no user folder, volume or account is read.
@main struct MacTextComparisonOracle {
    static func main() throws {
        let pairs: [(String,String)] = [
            ("Disk 2","Disk 10"),("Disk 10","Disk 2"),("Disk 02","Disk 2"),
            ("disk 2","Disk 2"),("ALPHA","alpha"),("File 9.txt","File 10.txt"),
            ("café","cafe\u{0301}"),("が","か\u{3099}"),("Å","A\u{030A}"),
            ("磁碟 2","磁碟 10"),("資料 9","資料 10"),("ＡＢＣ","ABC"),
            ("😀2","😀10"),("a-b","ab"),("foo 1.txt","foo 01.txt"),
            ("xé2","xé10"),("a10","a2"),("","a"),("",""),
            ("a\0b","a\0c"),("同名","同名")
        ]
        let rows = pairs.map { left,right in
            ["left":left,"right":right,"result":left.localizedStandardCompare(right).rawValue] as [String:Any]
        }
        let object:[String:Any] = ["source":"0.11.0 EngineLocationCatalog name.localizedStandardCompare", "api":"NSString.localizedStandardCompare:","locale":Locale.current.identifier,"cases":rows]
        var data = try JSONSerialization.data(withJSONObject: object, options:[.prettyPrinted,.sortedKeys])
        data.append(10)
        if CommandLine.arguments.count == 2 { try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1])) }
        else { try FileHandle.standardOutput.write(contentsOf:data) }
    }
}
