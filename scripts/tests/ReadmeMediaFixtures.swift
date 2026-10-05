import AppKit
import AVFoundation
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Original procedural demo art, not a photograph or a representation of a real
/// place. The same deterministic landscape supplies image/photo/video examples.
enum ReadmeMediaFixtures {
    static func prepare(in folder: URL) async throws {
        let image = landscape()
        let ci = CIImage(cgImage: image)
            .applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 7200, y: 0), "inputTargetNeutral": CIVector(x: 5600, y: 0)])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.18, kCIInputContrastKey: 1.08, kCIInputBrightnessKey: 0.035])
        let warm = CIContext().createCGImage(ci, from: ci.extent)!
        try write(image, to: folder.appendingPathComponent("Alpine Lake.png"))
        try write(image.cropping(to: CGRect(x: 190, y: 130, width: 1260, height: 760))!,
                  to: folder.appendingPathComponent("Detail Crop.png"))
        try write(image, to: folder.appendingPathComponent("Cool Study.tiff"))
        try write(warm, to: folder.appendingPathComponent("Warm Study.tiff"))
        try await video(image: image, to: folder.appendingPathComponent("Lake Original.mov"))
        try await video(image: warm, to: folder.appendingPathComponent("Lake Graded.mov"))
        try pdf(to: folder.appendingPathComponent("Field Notes Original.pdf"), revised: false)
        try pdf(to: folder.appendingPathComponent("Field Notes Revised.pdf"), revised: true)
    }

    static func landscape() -> CGImage {
        let width = 1600, height = 1000
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: space, components: [r, g, b, a])!
        }
        let sky = CGGradient(colorsSpace: space, colors: [color(0.88, 0.83, 0.74), color(0.47, 0.66, 0.76), color(0.2, 0.39, 0.57)] as CFArray,
                             locations: [0, 0.55, 1])!
        c.drawLinearGradient(sky, start: CGPoint(x: 0, y: 260), end: CGPoint(x: 0, y: 1000), options: [.drawsBeforeStartLocation])
        c.setFillColor(color(1, 0.91, 0.69, 0.9)); c.fillEllipse(in: CGRect(x: 1195, y: 748, width: 86, height: 86))
        // Layered mountain silhouettes, with repeated facets and snow ridges.
        let mountains: [[CGPoint]] = [
            [CGPoint(x: 0,y: 360), CGPoint(x: 0,y: 590), CGPoint(x: 210,y: 755), CGPoint(x: 420,y: 655), CGPoint(x: 620,y: 870), CGPoint(x: 805,y: 645), CGPoint(x: 1030,y: 800), CGPoint(x: 1230,y: 680), CGPoint(x: 1450,y: 735), CGPoint(x: 1600,y: 570), CGPoint(x: 1600,y: 360)],
            [CGPoint(x: 0,y: 345), CGPoint(x: 0,y: 570), CGPoint(x: 250,y: 640), CGPoint(x: 440,y: 535), CGPoint(x: 765,y: 725), CGPoint(x: 970,y: 575), CGPoint(x: 1170,y: 640), CGPoint(x: 1430,y: 500), CGPoint(x: 1600,y: 550), CGPoint(x: 1600,y: 345)]
        ]
        for (index, points) in mountains.enumerated() {
            c.setFillColor(index == 0 ? color(0.39,0.48,0.54) : color(0.22,0.35,0.4))
            c.beginPath(); c.addLines(between: points); c.closePath(); c.fillPath()
        }
        for (peak, spread) in [(CGPoint(x:620,y:870), CGFloat(172)), (CGPoint(x:1030,y:800), CGFloat(138)), (CGPoint(x:210,y:755), CGFloat(104))] {
            c.setFillColor(color(0.91,0.92,0.87,0.88)); c.beginPath(); c.move(to:peak)
            c.addLines(between:[CGPoint(x:peak.x-spread,y:peak.y-spread*0.76), CGPoint(x:peak.x-25,y:peak.y-74), CGPoint(x:peak.x+30,y:peak.y-124), CGPoint(x:peak.x+55,y:peak.y-95), CGPoint(x:peak.x+spread,y:peak.y-spread*1.16)])
            c.closePath(); c.fillPath()
        }
        let lake = CGGradient(colorsSpace: space, colors: [color(0.07,0.25,0.3),color(0.3,0.48,0.51),color(0.62,0.7,0.68)] as CFArray, locations:[0,0.72,1])!
        c.saveGState(); c.clip(to:CGRect(x:0,y:0,width:1600,height:380))
        c.drawLinearGradient(lake,start:CGPoint(x:0,y:0),end:CGPoint(x:0,y:380),options:[])
        var seed: UInt64 = 42
        func random() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((seed >> 32) % 10000) / 10000 }
        for _ in 0..<1800 {
            let y = random()*375, x = random()*1600, length = 8+random()*58
            c.setStrokeColor(color(0.75,0.83,0.79,0.015+random()*0.14)); c.setLineWidth(0.7+random()*1.7)
            c.move(to:CGPoint(x:x,y:y)); c.addLine(to:CGPoint(x:x+length,y:y)); c.strokePath()
        }
        c.restoreGState()
        for index in 0..<125 {
            let x = CGFloat(index)*13 + random()*5
            let h = 16+random()*52
            c.setFillColor(color(0.1+random()*0.04,0.23+random()*0.06,0.24+random()*0.06))
            c.move(to:CGPoint(x:x,y:365+h)); c.addLine(to:CGPoint(x:x-9,y:355)); c.addLine(to:CGPoint(x:x+11,y:355)); c.closePath(); c.fillPath()
        }
        c.setFillColor(color(0.065,0.16,0.16)); c.beginPath(); c.move(to:CGPoint(x:0,y:0))
        c.addLine(to:CGPoint(x:0,y:215)); c.addCurve(to:CGPoint(x:460,y:0),control1:CGPoint(x:150,y:95),control2:CGPoint(x:255,y:102)); c.closePath(); c.fillPath()
        for index in 0..<15 {
            let x = CGFloat(index)*24, height = 120+random()*185, bottom = max(0,110-x*0.22)
            c.setStrokeColor(color(0.12,0.19,0.17)); c.setLineWidth(4); c.move(to:CGPoint(x:x,y:bottom)); c.addLine(to:CGPoint(x:x,y:bottom+height)); c.strokePath()
            for branch in 0..<7 {
                let y = bottom+height*(0.17+CGFloat(branch)*0.115), half=(height-(y-bottom))*0.19
                c.setFillColor(color(0.06+random()*0.05,0.16+random()*0.07,0.16+random()*0.06))
                c.move(to:CGPoint(x:x,y:y+height*0.3)); c.addLine(to:CGPoint(x:x-half,y:y)); c.addLine(to:CGPoint(x:x+half,y:y)); c.closePath(); c.fillPath()
            }
        }
        // Fine deterministic textures prevent a flat-poster histogram and give
        // similarity matching real local features, without embedding text labels.
        for _ in 0..<14000 {
            let x=random()*1600,y=random()*1000
            c.setFillColor(random()>0.5 ? color(1,1,1,0.012+random()*0.025) : color(0,0,0,0.01+random()*0.025))
            c.fillEllipse(in:CGRect(x:x,y:y,width:1+random()*3,height:1+random()*2))
        }
        return c.makeImage()!
    }

    static func write(_ image: CGImage, to url: URL) throws {
        let type = url.pathExtension == "tiff" ? UTType.tiff : UTType.png
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,type.identifier as CFString,1,nil) else { throw Failure.message("Image writer unavailable") }
        CGImageDestinationAddImage(destination,image,[kCGImagePropertyTIFFDictionary:[kCGImagePropertyTIFFImageDescription:"CrossDiff procedural demonstration landscape; not a photograph"]] as CFDictionary)
        if !CGImageDestinationFinalize(destination) { throw Failure.message("Could not save demo art") }
    }

    static func video(image: CGImage, to url: URL) async throws {
        try? FileManager.default.removeItem(at:url)
        let width=960,height=600
        let writer=try AVAssetWriter(outputURL:url,fileType:.mov)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height,
            AVVideoColorPropertiesKey:[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,AVVideoTransferFunctionKey:AVVideoTransferFunction_ITU_R_709_2,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2]])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true])
        writer.add(input); guard writer.startWriting() else { throw writer.error ?? Failure.message("Video writer unavailable") }; writer.startSession(atSourceTime:.zero)
        for index in 0..<48 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds:1_000_000) }
            var pixel:CVPixelBuffer?
            guard let pool=adaptor.pixelBufferPool,CVPixelBufferPoolCreatePixelBuffer(nil,pool,&pixel)==kCVReturnSuccess,let pixel else { throw Failure.message("No video frame buffer") }
            CVPixelBufferLockBaseAddress(pixel,[])
            let c=CGContext(data:CVPixelBufferGetBaseAddress(pixel),width:width,height:height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(pixel),space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let zoom=1+Double(index)*0.0009
            c.draw(image,in:CGRect(x:-Double(index)*0.3,y:-Double(index)*0.15,width:Double(width)*zoom,height:Double(height)*zoom))
            CVPixelBufferUnlockBaseAddress(pixel,[])
            guard adaptor.append(pixel,withPresentationTime:CMTime(value:Int64(index),timescale:24)) else { throw writer.error ?? Failure.message("Could not encode frame") }
        }
        writer.endSession(atSourceTime:CMTime(value:2,timescale:1)); input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.message("Could not finish demo video") }
    }

    static func pdf(to url: URL, revised: Bool) throws {
        var bounds=CGRect(x:0,y:0,width:480,height:640)
        guard let c=CGContext(url as CFURL,mediaBox:&bounds,nil) else { throw Failure.message("Cannot create PDF") }
        for page in 0..<3 {
            c.beginPDFPage(nil); c.setFillColor(CGColor(gray:1,alpha:1)); c.fill(bounds)
            c.setFillColor(CGColor(srgbRed:0.13,green:0.31,blue:0.39,alpha:1)); c.fill(CGRect(x:32,y:569,width:416,height:3))
            let title=["Coastal light", "Observation notes", "Results & next steps"][page]
            let lines=[("FIELD NOTES  /  2026",CGFloat(11),CGFloat(594)),(title,28,527),
                       ("A local study of light, color and composition.",12,493),
                       ("01   Observe the scene",16,447),("Return to one viewpoint at different times of day.",12,419),
                       ("Record the changing shapes of light and shadow.",12,397),
                       ("02   Compare the findings",16,350),
                       (revised ? "Compare twelve frames across three evening visits." : "Compare eight frames across two evening visits.",12,322),
                       ("Keep originals and notes together in a local archive.",12,300),
                       ("03   Review the details",16,252),
                       (revised ? "Include a color study and the final contact sheet." : "Include the original contact sheet for reference.",12,224)]
            for (text,size,y) in lines {
                let value=NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:size,weight:size>=16 ? .semibold:.regular),.foregroundColor:NSColor(srgbRed:0.15,green:0.23,blue:0.28,alpha:1)])
                c.textPosition=CGPoint(x:32,y:y); CTLineDraw(CTLineCreateWithAttributedString(value),c)
            }
            c.setFillColor(CGColor(srgbRed:0.9,green:0.94,blue:0.94,alpha:1)); c.fill(CGRect(x:32,y:92,width:416,height:84))
            for index in 0..<8 {
                c.setFillColor(CGColor(srgbRed:0.22+Double(index)*0.07,green:0.39+Double(index)*0.04,blue:0.45+Double(index)*0.02,alpha:1))
                c.fill(CGRect(x:44+index*49,y:104,width:44,height:revised ? 32+index*5:20+index*6))
            }
            let footer=NSAttributedString(string:"CrossDiff demo  ·  \(page+1) / 3",attributes:[.font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor.gray])
            c.textPosition=CGPoint(x:32,y:44); CTLineDraw(CTLineCreateWithAttributedString(footer),c); c.endPDFPage()
        }
        c.closePDF()
    }
    enum Failure: Error { case message(String) }
}
