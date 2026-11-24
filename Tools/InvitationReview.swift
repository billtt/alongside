import AppKit
import ImageIO
import UniformTypeIdentifiers

// Compile with Sources/*.swift except main.swift. All three rows run the real
// controller independently on the same clock, with a fixed camera and scale.
@main struct InvitationReview {
    static let width = 760, rowHeight = 192
    static let gestures: [InvitationReplay.Gesture] = [.nearby, .farther, .dockEdge]

    static func scenes(_ art: PetArt, _ screen: NSScreen) throws -> [InvitationReplay] {
        try gestures.map { try InvitationReplay(art: art, screen: screen, gesture: $0) }
    }

    static func duration(_ art: PetArt, _ screen: NSScreen) throws -> Int {
        let trials = try scenes(art, screen)
        for tick in 0..<600 {
            trials.forEach { $0.step(frame: tick) }
            if trials.allSatisfy({ $0.settled }) {
                return ((tick + 38) / 2) * 2
            }
        }
        throw ArtError.invalid("未录到三只达达完成跟步并重新趴下")
    }

    static func state(_ replay: InvitationReplay, seconds: Double) -> String {
        if replay.settled { return replay.gesture == .dockEdge ? "留在台沿，重新趴好" : "到这里，趴一会儿" }
        if replay.pet.pose == .walking { return "迈步跟来" }
        if replay.walked { return "停下，慢慢趴回去" }
        if replay.pet.pose == .changing { return "达达准备起身" }
        if seconds < 1.55 { return "靠近脸旁" }
        if seconds < 2.30 { return "停一停" }
        let end = replay.gesture == .nearby ? 1.60 : 2.45
        return seconds < 2.30 + (end - 0.22) / 0.85 ? "将指针慢慢引开" : "指针停住"
    }

    static func draw(_ replay: InvitationReplay, row: Int, frame: Int, cg: CGContext) throws {
        guard let sprite = replay.pet.view.drawing else { throw ArtError.invalid("缺少邀请动作画面") }
        let height = CGFloat(rowHeight), width = CGFloat(Self.width)
        let bottom = CGFloat(gestures.count - 1 - row) * height
        let seconds = Double(frame) * replay.scene.dt
        let zoom = 175 / replay.pet.unit
        let baseline: CGFloat = bottom + (replay.gesture == .dockEdge ? 48 : 23)
        let origin = CGPoint(x: 570 - replay.start.x * zoom, y: baseline - replay.start.y * zoom)
        let t = replay.pet.surface.terrain
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.clip(to: CGRect(x: 0, y: bottom, width: width, height: height))
        let floor = origin.y + t.floor * zoom
        cg.setFillColor(CGColor(red: 0.90, green: 0.89, blue: 0.84, alpha: 1))
        cg.fill(CGRect(x: 0, y: bottom, width: width, height: max(0, floor - bottom)))
        cg.setFillColor(CGColor(red: 0.78, green: 0.75, blue: 0.68, alpha: 1))
        cg.fill(CGRect(x: 0, y: floor - 1, width: width, height: 1))
        if let dock = t.dock {
            let left = origin.x + dock.minX * zoom
            let rect = CGRect(x: left, y: floor, width: dock.width * zoom, height: dock.height * zoom)
            cg.setFillColor(CGColor(red: 0.78, green: 0.83, blue: 0.79, alpha: 1))
            cg.fill(rect)
            cg.setFillColor(CGColor(red: 0.49, green: 0.56, blue: 0.51, alpha: 1))
            cg.fill(CGRect(x: left, y: rect.maxY - 1, width: rect.width, height: 1))
        }
        cg.saveGState()
        cg.translateBy(x: origin.x, y: origin.y)
        cg.scaleBy(x: zoom, y: zoom)
        cg.translateBy(x: sprite.frame.minX, y: sprite.frame.minY)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        replay.pet.view.draw(replay.pet.view.bounds)
        cg.endTransparencyLayer()
        cg.restoreGState()

        let pointer = replay.pointer(at: seconds)
        let cursor = NSCursor.arrow
        let tip = CGPoint(x: origin.x + pointer.x * zoom, y: origin.y + pointer.y * zoom)
        let size = cursor.image.size
        cursor.image.draw(in: CGRect(x: tip.x - cursor.hotSpot.x,
                                     y: tip.y - size.height + cursor.hotSpot.y,
                                     width: size.width, height: size.height))
        let title = ["近处停住", "引得更远", "引向台沿外"][row] as NSString
        let baselineY = bottom + height - 29
        title.draw(at: CGPoint(x: 20, y: baselineY), withAttributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.16, alpha: 1)])
        (state(replay, seconds: seconds) as NSString).draw(at: CGPoint(x: 126, y: baselineY + 1), withAttributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(calibratedWhite: 0.32, alpha: 1)])
    }

    static func image(_ trials: [InvitationReplay], frame: Int) throws -> CGImage {
        let h = rowHeight * trials.count
        guard let cg = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8,
                                 bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ArtError.invalid("无法绘制邀请预览")
        }
        cg.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: width, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for (index, trial) in trials.enumerated() { try draw(trial, row: index, frame: frame, cg: cg) }
        guard let image = cg.makeImage() else { throw ArtError.invalid("无法读取邀请预览画面") }
        return image
    }

    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { throw ArtError.invalid("用法：InvitationReview 宠物资源目录 输出.gif") }
        var displays: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displays) == .success, displays > 0 else {
            throw ArtError.invalid("从隐藏宠物窗口录制需要已登录的桌面会话")
        }
        _ = NSApplication.shared.setActivationPolicy(.accessory)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { throw ArtError.invalid("没有屏幕") }
        let art = try PetArt(root: URL(fileURLWithPath: args[1]))
        try verifyInvitation(art, screen: screen)
        let ticks = try duration(art, screen), trials = try scenes(art, screen)
        let data = NSMutableData()
        guard let gif = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, ticks/2, nil)
        else { throw ArtError.invalid("无法创建邀请动图") }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for tick in 0..<ticks {
            try autoreleasepool {
                trials.forEach { $0.step(frame: tick) }
                if tick % 2 == 0 {
                    let sample = try image(trials, frame: tick)
                    let a = (Double(tick) * 100/30).rounded(), b = (Double(tick+2) * 100/30).rounded()
                    CGImageDestinationAddImage(gif, sample, [kCGImagePropertyGIFDictionary:
                        [kCGImagePropertyGIFDelayTime: (b-a)/100]] as CFDictionary)
                }
            }
        }
        guard trials.allSatisfy({ $0.settled && $0.safe }), CGImageDestinationFinalize(gif) else {
            throw ArtError.invalid("邀请预览未能完整收势")
        }
        try (data as Data).write(to: URL(fileURLWithPath: args[2]), options: .atomic)
        print("Rendered \(ticks/2) frames across three invitation scenarios.")
    }
}
