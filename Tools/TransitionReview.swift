import AppKit
import ImageIO
import UniformTypeIdentifiers

// Compile with the app sources except main.swift. Both sides keep the normal
// authored hold times, support corrections and unscaled camera.
@main struct TransitionReview {
    struct Sequence {
        let enter, leave: Reaction
        init(_ art: PetArt) {
            let library = MotionLibrary(art)
            let walk = MotionFrame(art.cel("walk", 0)), sit = MotionFrame(art.cel("settle", 0))
            enter = Reaction(library: library, path: library.path(from: walk, to: sit))
            leave = Reaction(library: library, path: library.path(from: sit, to: walk))
        }
    }
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { throw ArtError.invalid("用法：TransitionReview 旧版资源目录 新版资源目录 输出.gif") }
        let sequences = try args[1...2].map { try Sequence(PetArt(root: URL(fileURLWithPath: $0))) }
        let turnAt = 0.28 + sequences.map(\.enter.duration).max()! + 0.62
        let duration = turnAt + sequences.map(\.leave.duration).max()! + 0.28
        let frames = Int(ceil(duration * 15))
        let out = NSMutableData()
        guard let gif = CGImageDestinationCreateWithData(out, UTType.gif.identifier as CFString, frames, nil)
        else { throw ArtError.invalid("无法创建过渡动图") }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for index in 0..<frames {
            try autoreleasepool {
                let time = Double(index) / 15
                let w = 760, h = 266, floor: CGFloat = 28
                guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { throw ArtError.invalid("过渡预览画布") }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
                defer { NSGraphicsContext.restoreGraphicsState() }
                cg.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1))
                cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
                cg.setFillColor(CGColor(red: 0.87, green: 0.86, blue: 0.81, alpha: 1))
                cg.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: floor))
                cg.fill(CGRect(x: w/2, y: 0, width: 1, height: h))
                let unit: CGFloat = 180
                for (side, sequence) in sequences.enumerated() {
                    let x = CGFloat(side * w/2)
                    let action = time < turnAt ? sequence.enter : sequence.leave
                    let local = max(0, time - (time < turnAt ? 0.28 : turnAt))
                    let (cel, flip) = action.frame(at: local)
                    let feet = CGPoint(x: x + 214 + action.travel(at: local) * unit, y: floor)
                    let draw = SpriteDrawing(cel: cel, grounded: true, mirror: flip, feet: feet, k: unit * cel.scale,
                                             stretch: 1, backing: 1)
                    cg.saveGState()
                    cg.translateBy(x: draw.frame.minX, y: draw.frame.minY)
                    cg.concatenate(draw.transform)
                    cg.interpolationQuality = .high
                    cg.draw(draw.image, in: CGRect(x: 0, y: 0, width: draw.image.width, height: draw.image.height))
                    cg.restoreGState()
                    let title = side == 0 ? "旧版 · 0.1.17" : "新版 · 0.1.18"
                    (title as NSString).draw(at: CGPoint(x: x+20, y: CGFloat(h)-33), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor(calibratedWhite: 0.22, alpha: 1)])
                    let actionName = time < turnAt ? "收步坐下" : "起身迈步"
                    (actionName as NSString).draw(at: CGPoint(x: x+145, y: CGFloat(h)-32), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(calibratedWhite: 0.34, alpha: 1)])
                }
                guard let image = cg.makeImage() else { throw ArtError.invalid("过渡预览截帧") }
                let start = (Double(index) * 100 / 15).rounded(), end = (Double(index + 1) * 100 / 15).rounded()
                CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary:
                    [kCGImagePropertyGIFDelayTime: (end - start)/100]] as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(gif) else { throw ArtError.invalid("导出过渡预览") }
        try (out as Data).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
        print("Rendered \(frames) frames, \(duration) s")
    }
}
