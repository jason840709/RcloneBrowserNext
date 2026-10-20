#if os(macOS)
import Foundation
@preconcurrency import AppKit

/// Tests the installed app's file icon, including a setter process that has
/// already exited. Uses a temporary copy of the built, signed application.
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
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB,
                                          bitmapFormat: .alphaNonpremultiplied,
                                          bytesPerRow: size * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap), let pixels = bitmap.bitmapData else {
            throw Failure(description: "Could not create icon raster")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return Array(UnsafeBufferPointer(start: pixels, count: size * size * 4))
    }

    /// Compare all rendered pixels in premultiplied space so hidden RGB values
    /// in transparent pixels do not count against the actual artwork.
    private static func distance(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard lhs.count == rhs.count else { return .infinity }
        var error = 0.0
        for i in stride(from: 0, to: lhs.count, by: 4) {
            let a = Double(lhs[i + 3]) / 255, b = Double(rhs[i + 3]) / 255
            for channel in 0..<3 { error += abs(Double(lhs[i + channel]) * a - Double(rhs[i + channel]) * b) }
            error += abs(Double(lhs[i + 3]) - Double(rhs[i + 3]))
        }
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
        let args = CommandLine.arguments
        if args.count == 5 && args[1] == "--persist" {
            guard let image = NSImage(contentsOfFile: args[4]), image.isValid else { exit(2) }
            application.applicationIconImage = image
            let ok = RBNAppIconAppearance.persist(image, at: URL(fileURLWithPath: args[3], isDirectory: true))
            print("fileIconPersisted=\(ok);family=\(args[2])")
            exit(ok ? 0 : 3)
        }
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
        var expected = [String: [UInt8]]()
        var setupOK = false
        test("Copies the built signed app into an isolated icon fixture") {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: original, to: fixture)
            try verifySignature(fixture)
            originalContents = try contents(fixture)
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
                test("\(family) Finder icon survives its setter process exiting without a background tile") {
                    let message = try run(URL(fileURLWithPath: args[0]), ["--persist", family, fixture.path, iconURL(family, in: resources).path])
                    try require(message.contains("fileIconPersisted=true"), "The file icon write was not accepted")
                    let deadline = Date().addingTimeInterval(5)
                    var matched = false
                    var scores = [String: Double]()
                    repeat {
                        let actual = try raster(NSWorkspace.shared.icon(forFile: fixture.path))
                        scores = expected.mapValues { distance(actual, $0) }
                        let closest = scores.min { $0.value < $1.value }?.key
                        let centerAlpha = actual[(64 * 128 + 64) * 4 + 3]
                        matched = closest == family && (scores[family] ?? .infinity) < 20 && transparentFraction(actual) > 0.4 && centerAlpha < 32
                        if matched { break }
                        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                    } while Date() < deadline
                    try require(matched, "The stopped app's file icon did not match \(family): \(scores)")
                }
                test("\(family) file icon preserves every signed Contents byte and strict signature validity") {
                    try require(try contents(fixture) == originalContents, "A theme change modified the signed Contents")
                    try verifySignature(fixture)
                }
            }
            test("A missing application path rejects persistence without creating files") {
                guard let image = NSImage(contentsOf: iconURL("blue", in: resources)) else { throw Failure(description: "Missing blue icon") }
                let missing = temporary.appendingPathComponent("Missing.app", isDirectory: true)
                try require(!RBNAppIconAppearance.persist(image, at: missing), "Unexpectedly accepted a missing bundle")
                try require(!FileManager.default.fileExists(atPath: missing.path), "Created an unsolicited application")
            }
        }
        print("\nMacIconTests: \(passed) passed, \(failed) failed, 0 skipped")
        if failed > 0 { exit(1) }
    }
}
#endif
