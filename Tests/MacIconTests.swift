#if os(macOS)
import Foundation
@preconcurrency import AppKit

/// Tests the running application's theme image and transparent icon resources.
/// A temporary copy of the signed app must retain its fixed icon and signature.
@main struct MacIconTests {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static var passed = 0
    private static var failed = 0
    private static let families = ["purple", "blue", "green"]

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    private static func test(_ title: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS \(title)") }
        catch { failed += 1; print("FAIL \(title): \(error)") }
    }

    private static func iconURL(_ family: String, in resources: URL) -> URL {
        resources.appendingPathComponent(family == "purple" ? "AppIcon.icns" : "AppIcon-\(family).icns")
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        try require(task.terminationStatus == 0, "\(executable.lastPathComponent) exited \(task.terminationStatus): \(text)")
        return text
    }

    private static func verifySignature(_ app: URL) throws {
        _ = try run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", "--verbose=2", app.path])
    }

    private static func contents(_ app: URL) throws -> [String: Data] {
        let directory = app.appendingPathComponent("Contents", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw Failure(description: "Could not enumerate Contents")
        }
        var result = [String: Data]()
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(file.path.dropFirst(directory.path.count + 1))] = try Data(contentsOf: file)
            }
        }
        return result
    }

    private static func raster(_ image: NSImage, size: Int = 128) throws -> [UInt8] {
        // A Quartz drawing destination uses premultiplied RGBA. A bitmap can
        // hold straight alpha, but NSGraphicsContext cannot draw into that
        // 8-bit format and returns nil on current macOS.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB,
                                          bitmapFormat: [],
                                          bytesPerRow: size * 4, bitsPerPixel: 32) else {
            throw Failure(description: "Could not allocate the premultiplied icon bitmap")
        }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap), let pixels = bitmap.bitmapData else {
            throw Failure(description: "Could not create the premultiplied icon drawing context")
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        return Array(UnsafeBufferPointer(start: pixels, count: size * size * 4))
    }

    /// The drawing buffers already contain premultiplied RGBA, so compare
    /// those bytes directly without multiplying their RGB values a second time.
    private static func distance(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard lhs.count == rhs.count else { return .infinity }
        var error = 0.0
        for i in lhs.indices { error += abs(Double(lhs[i]) - Double(rhs[i])) }
        return error / Double(lhs.count)
    }

    private static func transparentFraction(_ pixels: [UInt8]) -> Double {
        Double(stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] == 0 }.count) / Double(pixels.count / 4)
    }

    private static func readPNGRepresentations(_ url: URL) throws -> [String: [UInt8]] {
        let data = try Data(contentsOf: url)
        try require(data.count >= 8 && String(decoding: data.prefix(4), as: UTF8.self) == "icns", "Not an ICNS file")
        var offset = 8
        var output = [String: [UInt8]]()
        while offset < data.count {
            try require(offset + 8 <= data.count, "Truncated ICNS member header")
            let tag = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let count = data[(offset + 4)..<(offset + 8)].reduce(0) { ($0 << 8) | Int($1) }
            try require(count >= 8 && offset + count <= data.count, "Truncated ICNS member")
            guard let rep = NSBitmapImageRep(data: data[(offset + 8)..<(offset + count)]) else {
                throw Failure(description: "Cannot decode ICNS member \(tag)")
            }
            var alpha = [UInt8]()
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let color = rep.colorAt(x: x, y: y) else { throw Failure(description: "Cannot read icon pixel") }
                    alpha.append(UInt8((color.alphaComponent * 255).rounded()))
                }
            }
            let minimumClearFraction = rep.pixelsWide <= 16 ? 0.35 : 0.45
            try require(alpha.contains(255) && Double(alpha.filter { $0 == 0 }.count) / Double(alpha.count) > minimumClearFraction,
                        "\(tag) does not have transparent ring interiors and surrounding space")
            try require(alpha[(rep.pixelsHigh / 2) * rep.pixelsWide + rep.pixelsWide / 2] < 32, "\(tag) has an opaque center")
            output[tag] = alpha
            offset += count
        }
        try require(output.count == 11, "Expected all eleven optical and Retina representations")
        return output
    }

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let previousIcon = application.applicationIconImage
        defer { application.applicationIconImage = previousIcon }
        let args = CommandLine.arguments
        guard args.count == 3 else {
            print("FAIL Usage: MacIconTests Resources BuiltApp.app")
            exit(1)
        }
        let resources = URL(fileURLWithPath: args[1], isDirectory: true)
        let original = URL(fileURLWithPath: args[2], isDirectory: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("rbn-icon-tests-\(UUID().uuidString)", isDirectory: true)
        let fixture = temporary.appendingPathComponent("Rclone Browser Next.app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var originalContents = [String: Data]()
        var originalEntries = [String]()
        var expected = [String: [UInt8]]()
        var setupOK = false
        test("Copies the built signed app into an isolated icon fixture") {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: original, to: fixture)
            try verifySignature(fixture)
            originalContents = try contents(fixture)
            originalEntries = try FileManager.default.contentsOfDirectory(atPath: fixture.path).sorted()
            try require(!originalContents.isEmpty, "Empty signed app fixture")
            setupOK = true
        }
        var referenceMasks: [String: [UInt8]]?
        for family in families {
            test("\(family) artwork has all transparent representations and unchanged geometry") {
                let source = iconURL(family, in: resources)
                let masks = try readPNGRepresentations(source)
                if let referenceMasks = referenceMasks { try require(masks == referenceMasks, "The color variant changed the full alpha geometry") }
                else { referenceMasks = masks }
                guard let image = NSImage(contentsOf: source), image.isValid else { throw Failure(description: "Cannot decode \(family) image") }
                expected[family] = try raster(image)
            }
        }
        if setupOK && expected.count == families.count {
            for family in ["blue", "green", "purple"] {
                test("\(family) runtime application icon uses the selected transparent artwork") {
                    guard let image = NSImage(contentsOf: iconURL(family, in: resources)) else {
                        throw Failure(description: "Cannot decode \(family) image")
                    }
                    try require(RBNAppIconAppearance.apply(image), "The runtime icon was not accepted")
                    guard let currentImage = application.applicationIconImage else {
                        throw Failure(description: "The running application has no icon")
                    }
                    let actual = try raster(currentImage)
                    let scores = expected.mapValues { distance(actual, $0) }
                    let closest = scores.min { $0.value < $1.value }?.key
                    let centerAlpha = actual[(64 * 128 + 64) * 4 + 3]
                    try require(closest == family && (scores[family] ?? .infinity) < 20,
                                "The runtime icon did not match \(family): \(scores)")
                    try require(transparentFraction(actual) > 0.4 && centerAlpha < 32,
                                "The runtime icon lost its transparent background or ring interiors")
                }
                test("\(family) runtime icon preserves every signed Contents byte and strict signature validity") {
                    try require(try contents(fixture) == originalContents, "A theme change modified the signed Contents")
                    try require(try FileManager.default.contentsOfDirectory(atPath: fixture.path).sorted() == originalEntries,
                                "A theme change added a file to the app bundle")
                    try verifySignature(fixture)
                }
            }
            test("Resetting the runtime icon retains the fixed purple bundle icon and strict signature") {
                application.applicationIconImage = nil
                let infoURL = fixture.appendingPathComponent("Contents/Info.plist")
                let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), options: [], format: nil)
                guard let info = plist as? [String: Any] else { throw Failure(description: "Cannot read the bundle Info.plist") }
                try require(info["CFBundleIconFile"] as? String == "AppIcon.icns", "The bundle's default icon changed")
                let bundledIcon = fixture.appendingPathComponent("Contents/Resources/AppIcon.icns")
                try require(try Data(contentsOf: bundledIcon) == Data(contentsOf: iconURL("purple", in: resources)),
                            "The fixed bundle icon no longer matches the supplied purple artwork")
                try require(try contents(fixture) == originalContents, "Resetting the runtime icon changed signed Contents")
                try require(try FileManager.default.contentsOfDirectory(atPath: fixture.path).sorted() == originalEntries,
                            "Resetting the runtime icon added a file to the app bundle")
                try verifySignature(fixture)
            }
        }
        print("\nMacIconTests: \(passed) passed, \(failed) failed, 0 skipped")
        if failed > 0 {
            // exit does not unwind Swift defer blocks.
            application.applicationIconImage = previousIcon
            try? FileManager.default.removeItem(at: temporary)
            exit(1)
        }
    }
}
#endif
