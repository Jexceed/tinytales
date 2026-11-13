import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let logo = root.appendingPathComponent("macos/Resources/Brand/story-unicorn.png")
guard let source = CGImageSourceCreateWithURL(logo as CFURL, nil), let idle = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("The storytelling brand logo is missing or invalid") }
for size in [16,32,128,256,512] {
    for pixelScale in [1,2] {
        let pixels = size * pixelScale
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Icon context") }
        context.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
        context.setFillColor(CGColor(red: 0.98, green: 0.96, blue: 0.99, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 16, y: 16, width: 992, height: 992), cornerWidth: 220, cornerHeight: 220, transform: nil)); context.fillPath()
        context.interpolationQuality = .high
        let fitScale = min(856.0 / Double(idle.width), 856.0 / Double(idle.height))
        let width = Double(idle.width) * fitScale, height = Double(idle.height) * fitScale
        context.draw(idle, in: CGRect(x: (1024-width)/2, y: (1024-height)/2, width: width, height: height))
        let name = "icon_\(size)x\(size)\(pixelScale == 2 ? "@2x" : "").png"
        let url = root.appendingPathComponent("build/TinyTales.iconset/\(name)")
        guard let output = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("Icon output") }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Icon encode") }
    }
}
