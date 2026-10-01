import Foundation
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CrossDiffCore

@main struct PhotoMetadataChecks {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let imageURL = root.appendingPathComponent("sample.png")
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let output = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, image, nil)
        precondition(CGImageDestinationFinalize(output))
        let bytes = try Data(contentsOf: imageURL)
        let absent = try PhotoMetadataReader.recordedCurves(imageData: bytes, sourceName: imageURL.lastPathComponent)
        precondition(absent.isEmpty,
                     "Missing curve metadata must not become an invented identity curve")
        let sidecar = root.appendingPathComponent("processing.xmp")
        func xmp(_ body: String) -> Data {
            Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:raw="http://ns.adobe.com/camera-raw-settings/1.0/" raw:ProcessVersion="11.0">
            \(body)
            </rdf:Description></rdf:RDF></x:xmpmeta>
            """.utf8)
        }
        let valid = xmp("""
        <raw:ToneCurvePV2012><rdf:Seq><rdf:li>0, 12</rdf:li><rdf:li>128, 140</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></raw:ToneCurvePV2012>
        <raw:ToneCurvePV2012Red><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>255, 250</rdf:li></rdf:Seq></raw:ToneCurvePV2012Red>
        """)
        try valid.write(to: sidecar)
        let curves = try PhotoMetadataReader.recordedCurves(xmpURL: sidecar)
        precondition(curves.count == 2 && curves[0].points.count == 3)
        precondition(curves[0].points[1].x == 128.0 / 255 && curves[0].points[1].y == 140.0 / 255)
        precondition(curves[0].source.contains("11.0") && curves[0].source.contains("processing.xmp"))
        let metadata = CGImageMetadataCreateFromXMPData(valid as CFData)!
        let embedded = root.appendingPathComponent("embedded.png")
        let embeddedOutput = CGImageDestinationCreateWithURL(embedded as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImageAndMetadata(embeddedOutput, image, metadata, nil)
        precondition(CGImageDestinationFinalize(embeddedOutput))
        let embeddedBytes = try Data(contentsOf: embedded)
        let embeddedCurves = try PhotoMetadataReader.recordedCurves(imageData: embeddedBytes, sourceName: embedded.lastPathComponent)
        precondition(embeddedCurves.count == 2, "Embedded XMP must use the same reader")
        try xmp("<raw:ToneCurve><rdf:Seq><rdf:li>255, 0</rdf:li><rdf:li>0, 255</rdf:li></rdf:Seq></raw:ToneCurve>").write(to: sidecar)
        do {
            _ = try PhotoMetadataReader.recordedCurves(xmpURL: sidecar)
            fatalError("Unordered curve control points must be rejected")
        } catch is PhotoMetadataFailure {}
        try Data("<!DOCTYPE x [<!ENTITY x 'invalid'>]><x/>".utf8).write(to: sidecar)
        do {
            _ = try PhotoMetadataReader.recordedCurves(xmpURL: sidecar)
            fatalError("DTD input must be rejected")
        } catch is PhotoMetadataFailure {}
        // Explicit sidecars cannot bypass their byte budget, and special files do not block.
        let large = root.appendingPathComponent("too-large.xmp")
        FileManager.default.createFile(atPath: large.path, contents: Data())
        let largeHandle = try FileHandle(forWritingTo: large)
        try largeHandle.truncate(atOffset: UInt64(PhotoMetadataReader.maximumXMPBytes + 1)); try largeHandle.close()
        do {
            _ = try PhotoMetadataReader.recordedCurves(xmpURL: large)
            fatalError("Oversized XMP must be rejected")
        } catch is PhotoMetadataFailure {}
        let link = root.appendingPathComponent("symbolic.xmp")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sidecar)
        do {
            _ = try PhotoMetadataReader.recordedCurves(xmpURL: link)
            fatalError("Symlinked XMP must be rejected")
        } catch is PhotoMetadataFailure {}
        let fifo = root.appendingPathComponent("pipe.xmp")
        try? FileManager.default.removeItem(at: fifo)
        precondition(mkfifo(fifo.path, 0o600) == 0)
        do {
            _ = try PhotoMetadataReader.recordedCurves(xmpURL: fifo)
            fatalError("FIFO input must fail without blocking")
        } catch is PhotoMetadataFailure {}
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PhotoMetadataReader.recordedCurves(xmpURL: sidecar)
        }
        do { _ = try await cancelled.value; fatalError("Cancelled XMP reads must stop") }
        catch is CancellationError {}
        try bytes.write(to: embedded)
        let retained = try PhotoMetadataReader.recordedCurves(imageData: embeddedBytes, sourceName: embedded.lastPathComponent)
        let replaced = try PhotoMetadataReader.recordedCurves(imageData: Data(contentsOf: embedded), sourceName: embedded.lastPathComponent)
        precondition(retained.count == 2 && replaced.isEmpty, "Embedded records follow immutable image bytes, not a replaced file path")
        let after = try Data(contentsOf: imageURL)
        precondition(after == bytes, "Metadata analysis must preserve the source")
        print("PASS: absent/sidecar/embedded curves, snapshot isolation, bounded/cancellable reads, regular-file boundary, malformed XMP and source preservation")
    }
}
