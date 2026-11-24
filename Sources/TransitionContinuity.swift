import CoreGraphics
import Foundation

// Compare rendered silhouettes at a shared scale and ground line; comparing
// source PNG bounding boxes would mix arbitrary crop dimensions with pose changes.
func verifyTransitionContinuity(_ art: PetArt) throws {
    let motions = MotionLibrary(art)
    let width = 360, height = 270, unit: CGFloat = 185
    struct Outline { let mask: [UInt8], width: Int, height: Int }
    func outline(_ frame: MotionFrame) throws -> Outline {
        let drawing = SpriteDrawing(cel: frame.cel, grounded: true, mirror: frame.mirrored,
                                    feet: CGPoint(x: 180, y: 36), k: unit * frame.cel.scale, stretch: 1, backing: 1)
        guard let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = cg.data?.assumingMemoryBound(to: UInt8.self) else { throw ArtError.invalid("过渡轮廓采样") }
        defer { withExtendedLifetime(cg) {} }
        cg.translateBy(x: drawing.frame.minX, y: drawing.frame.minY)
        cg.concatenate(drawing.transform)
        cg.draw(drawing.image, in: CGRect(x: 0, y: 0, width: drawing.image.width, height: drawing.image.height))
        var mask = [UInt8](repeating: 0, count: width * height)
        var xmin = width, xmax = 0, ymin = height, ymax = 0
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 100 {
                mask[y * width + x] = 1
                xmin = min(xmin, x); xmax = max(xmax, x)
                ymin = min(ymin, y); ymax = max(ymax, y)
            }
        }
        guard xmax > xmin, ymax > ymin else { throw ArtError.invalid("缺少转场轮廓") }
        return Outline(mask: mask, width: xmax - xmin + 1, height: ymax - ymin + 1)
    }
    func require(_ ok: Bool, _ text: String) throws {
        if !ok { throw ArtError.invalid("动作衔接 · " + text) }
    }
    for mirror in [false, true] {
        let walk = MotionFrame(art.cel("walk", 0), mirror)
        let sit = MotionFrame(art.cel("settle", 0), mirror)
        let route = motions.path(from: walk, to: sit)
        let backwards = motions.path(from: sit, to: walk)
        try require(Array(route.reversed()) == backwards && Set(route).count == route.count,
                    "走到坐与坐到走共用可逆的一条路线")
        let shapes = try route.map(outline)
        for (a, b) in zip(shapes, shapes.dropFirst()) {
            var shared = 0, combined = 0
            for i in a.mask.indices {
                shared += Int(a.mask[i] & b.mask[i])
                combined += Int(a.mask[i] | b.mask[i])
            }
            try require(Double(shared) / Double(combined) > 0.665, "收脚、撑胸和坐定之间轮廓改变过大")
        }
        for key in [MotionFrame(art.cel("standTurn", 2), mirror), MotionFrame(art.cel("settle", 3), mirror)] {
            try require(route.contains(key), "行走坐下经过四脚承重和半坐")
            for target in [walk, sit] {
                let interrupted = motions.path(from: key, to: target)
                try require(interrupted.first == key && interrupted.last == target && Set(interrupted).count == interrupted.count,
                            "从借用原画中断时重复起势")
            }
        }
        let turn = motions.path(from: sit, to: MotionFrame(sit.cel, !mirror))
        let heights = try turn.map { try outline($0).height }
        try require(heights.max()! - heights.min()! <= 7, "坐着换朝向时身体忽高忽低")
    }
    let rear = try outline(MotionFrame(art.cel("turn", 5)))
    let approach = try outline(MotionFrame(art.cel("standTurn", 13)))
    try require(abs(Double(rear.width) / Double(approach.width) - 1) < 0.08, "背睡落稳时躯干突然变宽")
    let side = art.cel("motion-side-prone", 3), prone = art.cel("settle", 8)
    guard let eyes = prone.eyeCenters, eyes.count == 2 else { throw ArtError.invalid("正面趴姿眼距") }
    // Centers of the two gold irises in the last, already near-frontal drawing.
    let left = side.projected(CGPoint(x: 38.3, y: 59.8)), right = side.projected(CGPoint(x: 77.4, y: 59.0))
    let previous = hypot(right.x - left.x, right.y - left.y) * side.scale
    let final = hypot(eyes[1].x - eyes[0].x, eyes[1].y - eyes[0].y) * prone.scale
    try require(abs(final / previous - 1) < 0.06, "侧卧转正面时最后一步眼距突变")
}
