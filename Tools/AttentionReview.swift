import AppKit
import ImageIO
import UniformTypeIdentifiers

// Compile with Sources/*.swift except main.swift. Uses the live controller and PetView
// on a hidden panel; inputs and the small pointer drawn on the stage are simulated.
@main struct AttentionReview {
    private static let width = 768, height = 328

    private static func move(_ a: CGPoint, _ b: CGPoint, fraction: Double) -> CGPoint {
        let t = min(1, max(0, fraction))
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func drawCursor(_ cg: CGContext, point: CGPoint, click: Double?) {
        cg.saveGState()
        cg.translateBy(x: point.x, y: point.y)
        if let click, click >= 0, click < 0.42 {
            let t = click / 0.42, radius = 7 + 17 * t
            cg.setStrokeColor(CGColor(red: 0.45, green: 0.32, blue: 0.11, alpha: 1 - t))
            cg.setLineWidth(2)
            cg.strokeEllipse(in: CGRect(x: -radius, y: -radius, width: 2*radius, height: 2*radius))
        }
        cg.beginPath()
        cg.move(to: .zero)
        for point in [CGPoint(x: 0.8, y: -19), CGPoint(x: 5.7, y: -14.1),
                      CGPoint(x: 10, y: -21.5), CGPoint(x: 13.2, y: -19.6),
                      CGPoint(x: 9.1, y: -12.4), CGPoint(x: 15.6, y: -12.3)] {
            cg.addLine(to: point)
        }
        cg.closePath()
        cg.setFillColor(CGColor(gray: 0.12, alpha: 1))
        cg.setStrokeColor(CGColor(gray: 1, alpha: 1))
        cg.setLineWidth(1.8)
        cg.setLineJoin(.round)
        cg.drawPath(using: .fillStroke)
        cg.restoreGState()
    }

    private static func image(scene: AttentionCheckScene, startX: CGFloat, floor: CGFloat,
                              pointer: CGPoint, click: Double?, caption: String) throws -> CGImage {
        let pet = scene.pet
        guard let sprite = pet.view.drawing,
              let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                 bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ArtError.invalid("无法创建预览画面")
        }
        let bottom: CGFloat = 44
        cg.setFillColor(CGColor(red: 0.969, green: 0.957, blue: 0.925, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        cg.setFillColor(CGColor(red: 0.903, green: 0.886, blue: 0.845, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: bottom))
        cg.setFillColor(CGColor(red: 0.76, green: 0.73, blue: 0.67, alpha: 1))
        cg.fill(CGRect(x: 0, y: bottom - 1, width: CGFloat(width), height: 1))

        // A small camera pan during the walk keeps the face in view. The rail,
        // cursor and painting all use the same transform.
        let zoom = 334 / pet.unit
        let offset = pet.x - startX
        let pan = (offset < 0 ? -1.0 : 1.0) * max(0, abs(offset) - 0.18 * pet.unit) * 0.9
        let origin = CGPoint(x: 320 - (scene.head.x + pan) * zoom, y: bottom - floor * zoom)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        cg.saveGState()
        cg.translateBy(x: origin.x, y: origin.y)
        cg.scaleBy(x: zoom, y: zoom)
        cg.translateBy(x: sprite.frame.minX, y: sprite.frame.minY)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        pet.view.draw(pet.view.bounds)
        cg.endTransparencyLayer()
        cg.restoreGState()
        drawCursor(cg, point: CGPoint(x: origin.x + pointer.x*zoom, y: origin.y + pointer.y*zoom), click: click)
        (caption as NSString).draw(at: CGPoint(x: 28, y: height-43), withAttributes: [
            .font: NSFont.systemFont(ofSize: 19, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.20, alpha: 1)
        ])
        NSGraphicsContext.restoreGraphicsState()
        guard let result = cg.makeImage() else { throw ArtError.invalid("无法读取预览画面") }
        return result
    }

    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            throw ArtError.invalid("用法：AttentionReview 宠物资源目录 输出.gif")
        }
        var displays: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displays) == .success, displays > 0 else {
            throw ArtError.invalid("导出互动预览需要已登录的桌面会话")
        }
        _ = NSApplication.shared.setActivationPolicy(.accessory)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { throw ArtError.invalid("没有屏幕") }
        let art = try PetArt(root: URL(fileURLWithPath: args[1]))
        try verifyAttention(art, screen: screen)
        let scene = try AttentionCheckScene(art: art, screen: screen, draw: { 0.01 })
        let pet = scene.pet, startX = pet.x, floor = pet.y
        let ticks = 302, headTap = 128, pawTap = 201
        let output = URL(fileURLWithPath: args[2])
        let encoded = NSMutableData()
        guard let gif = CGImageDestinationCreateWithData(encoded, UTType.gif.identifier as CFString,
                                                        ticks/2, nil) else {
            throw ArtError.invalid("无法创建动图")
        }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var sawApproach = false, sawHead = false, sawReturn = false, sawWalk = false
        for tick in 0..<ticks {
            try autoreleasepool {
                let near = scene.approaching(1)
                let point: CGPoint
                switch tick {
                case ..<18: point = scene.approaching(0)
                case 18..<52: point = scene.approaching(Double(tick - 18) / 32)
                case 52..<112: point = near
                case 112..<headTap: point = move(near, scene.head, fraction: Double(tick - 112)/16)
                case headTap..<180: point = scene.head
                case 180..<pawTap: point = move(scene.head, scene.paw, fraction: Double(tick - 180)/21)
                default: point = scene.paw
                }
                if tick == headTap || tick == pawTap { pet.press(at: point) }
                if tick == headTap + 2 || tick == pawTap + 2 { pet.release(at: point) }
                scene.advance(point)
                if tick < headTap {
                    if pet.isAttending { sawApproach = true }
                    else if sawApproach { sawReturn = true }
                } else if tick < pawTap {
                    sawHead = sawHead || pet.isAttending
                }
                sawWalk = sawWalk || pet.pose == .walking
                guard tick % 2 == 0 else { return }
                let caption: String
                if tick < headTap {
                    if pet.isAttending { caption = "它看向靠近的指针" }
                    else if sawReturn { caption = "看过之后，继续趴着" }
                    else { caption = "指针慢慢靠近" }
                } else if tick < pawTap {
                    caption = pet.isAttending ? "轻碰额头，它又看了一眼" : "达达继续休息"
                } else {
                    caption = sawWalk ? "达达起身走开" : "碰到了前爪"
                }
                let lastTap = tick >= pawTap ? pawTap : headTap
                let sinceTap = tick >= headTap ? Double(tick - lastTap)/30 : nil
                let frame = try image(scene: scene, startX: startX, floor: floor,
                                      pointer: point, click: sinceTap, caption: caption)
                // Round cumulative time so that three 15-fps frames take exactly 0.20 s.
                let a = (Double(tick)*100/30).rounded(), b = (Double(tick+2)*100/30).rounded()
                CGImageDestinationAddImage(gif, frame, [kCGImagePropertyGIFDictionary:
                    [kCGImagePropertyGIFDelayTime: (b-a)/100]] as CFDictionary)
            }
        }
        guard sawApproach && sawReturn && sawHead && sawWalk else {
            throw ArtError.invalid("录制未覆盖完整的互动序列")
        }
        guard CGImageDestinationFinalize(gif) else { throw ArtError.invalid("动图写入失败") }
        try (encoded as Data).write(to: output, options: .atomic)
        print("Rendered \(ticks / 2) frames at 15 fps from the live attention, touch, and walk paths.")
    }
}
