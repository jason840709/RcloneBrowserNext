import Foundation

struct RBNFinderDrop {
    let source: EngineEndpoint
    let selection: [EngineSelection]

    init(urls: [URL]) throws {
        guard !urls.isEmpty, urls.count <= 10000 else { throw EngineError("一次最多拖入 10,000 個項目。") }
        var parent: URL?
        var seen = Set<String>()
        var selected = [[String: Any]]()
        for original in urls {
            guard original.isFileURL, original.host == nil || original.host == "" || original.host == "localhost" else {
                throw EngineError("請從 Finder 拖入本機檔案或資料夾。")
            }
            let url = original.standardizedFileURL
            guard url.path != "/" else { throw EngineError("請拖入資料夾內的項目。") }
            let folder = url.deletingLastPathComponent().standardizedFileURL
            if let expected = parent, expected.path != folder.path {
                throw EngineError("一次請拖入同一資料夾內的項目；不同來源可以分次加入。")
            }
            parent = folder
            guard seen.insert(url.path).inserted else { continue }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else {
                throw EngineError("請拖入原始檔案或資料夾；拖放不會跟隨符號連結。")
            }
            guard values.isDirectory == true || values.isRegularFile == true else {
                throw EngineError("拖入的項目不是可傳輸的檔案或資料夾。")
            }
            selected.append(["name": url.lastPathComponent,
                             "isDir": values.isDirectory == true])
        }
        guard let parent = parent, !selected.isEmpty else { throw EngineError("請拖入檔案或資料夾。") }
        source = try EngineEndpoint(["remote": NSNull(), "path": parent.path])
        selection = try EngineSelection.parse(selected)
    }
}
