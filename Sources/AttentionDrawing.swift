import CoreGraphics
import Foundation

struct AttentionEar: Decodable {
    let tip, hinge: CGPoint
}

/// All points are in the calibrated, unmirrored painting, with y increasing downward.
/// The ear tips can swivel about their roots. Each pupil moves inside its own iris.
final class AttentionDrawing {
    private struct Part {
        let bounds: CGRect
        let source: (CGPoint, CGPoint) -> CGPoint
    }

    private let parts: [Part]
    private let input: CGContext
    private var inputImage: CGImage?
    private var last: (direction: CGPoint, image: CGImage)?

    init?(image: CGImage, eyes: [CGPoint], ears: [AttentionEar]) {
        guard eyes.count == 2, ears.count == 2 else { return nil }
        let spacing = eyes[1].x - eyes[0].x
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard spacing > 0, let input = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 4 * image.width, space: space, bitmapInfo: info) else { return nil }
        self.input = input
        var parts: [Part] = []
        for (i, ear) in ears.enumerated() {
            let length = ear.hinge.y - ear.tip.y
            guard length > 0 else { return nil }
            let radius = length * 0.80
            let bounds = CGRect(x: min(ear.tip.x, ear.hinge.x) - radius, y: 0,
                                width: abs(ear.tip.x - ear.hinge.x) + 2 * radius, height: ear.hinge.y)
            parts.append(Part(bounds: bounds) { p, gaze in
                let lift = min(1, max(0, (ear.hinge.y - p.y) / length))
                let center = ear.hinge.x + (ear.tip.x - ear.hinge.x) * lift
                let span = min(1, max(0, 2 - 2 * abs(p.x - center) / radius))
                let weight = lift * lift * span * span * (3 - 2 * span)
                let outward: CGFloat = i == 0 ? -1 : 1
                let turn = gaze.x * (outward * gaze.x > 0 ? 0.22 : 0.13)
                let perk = -outward * max(0, gaze.y) * 0.065
                return CGPoint(x: p.x - length * (turn + perk) * weight,
                               y: p.y - length * abs(turn) * 0.18 * weight)
            })
        }
        for (i, eye) in eyes.enumerated() {
            let rx = spacing * 0.205, ry = spacing * 0.137
            let center = CGPoint(x: eye.x, y: eye.y - spacing * 0.012)
            let tilt: CGFloat = i == 0 ? 0.18 : -0.18
            let bounds = CGRect(x: center.x-rx, y: center.y-ry-rx*abs(tilt),
                                width: 2*rx, height: 2*(ry+rx*abs(tilt)))
            parts.append(Part(bounds: bounds) { p, gaze in
                let x = (p.x-center.x) / rx
                let y = (p.y-center.y - (p.x-center.x)*tilt) / ry
                guard x*x+y*y < 1 else { return p }
                // Remap a chord of the iris while keeping both ends on the painted eyelid.
                let halfWidth = sqrt(1-y*y), u = x / halfWidth, horizontal = gaze.x * 0.48
                let sx = halfWidth * (u-horizontal) / (1-u*horizontal)
                let halfHeight = sqrt(max(0.0001, 1-sx*sx)), v = y / halfHeight
                let vertical = -gaze.y * 0.30
                let sy = halfHeight * (v-vertical) / (1-v*vertical)
                return CGPoint(x: center.x + sx*rx, y: center.y + sy*ry + sx*rx*tilt)
            })
        }
        self.parts = parts
    }

    static func direction(_ gaze: CGPoint) -> CGPoint {
        func discrete(_ value: CGFloat) -> CGFloat {
            guard value.isFinite else { return 0 }
            return (min(1,max(-1,value))*12).rounded()/12
        }
        return CGPoint(x: discrete(gaze.x), y: discrete(gaze.y))
    }

    func sourcePoint(_ point: CGPoint, direction: CGPoint) -> CGPoint {
        guard direction != .zero, let part = parts.first(where: { $0.bounds.contains(point) })
        else { return point }
        return part.source(point, direction)
    }

    func image(_ original: CGImage, direction: CGPoint) -> CGImage {
        guard direction != .zero else { return original }
        let w = input.width, h = input.height
        guard original.width == w, original.height == h else { return original }
        if inputImage !== original {
            input.setBlendMode(.copy)
            input.draw(original, in: CGRect(x: 0, y: 0, width: w, height: h))
            inputImage = original
            last = nil
        }
        if let last, direction == last.direction { return last.image }
        guard let out = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: 4*w, space: input.colorSpace!, bitmapInfo: input.bitmapInfo.rawValue),
              let source = input.data?.assumingMemoryBound(to: UInt8.self),
              let dest = out.data?.assumingMemoryBound(to: UInt8.self) else { return original }
        memcpy(dest, source, 4*w*h)
        for part in parts {
            let box = part.bounds.integral.intersection(CGRect(x: 0,y: 0,width: w,height: h))
            guard !box.isEmpty else { continue }
            for y in Int(box.minY)..<Int(box.maxY) {
                for x in Int(box.minX)..<Int(box.maxX) {
                    let pixel = CGPoint(x: CGFloat(x)+0.5, y: CGFloat(y)+0.5)
                    let p = part.source(pixel, direction)
                    if p == pixel { continue }
                    let sx = min(CGFloat(w-1),max(0,p.x-0.5)), sy = min(CGFloat(h-1),max(0,p.y-0.5))
                    let x0 = Int(sx), y0 = Int(sy), x1 = min(w-1,x0+1), y1 = min(h-1,y0+1)
                    let dx = sx-CGFloat(x0), dy = sy-CGFloat(y0)
                    let a = (y0*w+x0)*4, b = (y0*w+x1)*4, c = (y1*w+x0)*4, d = (y1*w+x1)*4
                    for channel in 0..<4 {
                        let top = (1-dx)*CGFloat(source[a+channel])+dx*CGFloat(source[b+channel])
                        let bottom = (1-dx)*CGFloat(source[c+channel])+dx*CGFloat(source[d+channel])
                        dest[(y*w+x)*4+channel] = UInt8(clamping: Int(((1-dy)*top+dy*bottom).rounded()))
                    }
                }
            }
        }
        guard let image = out.makeImage() else { return original }
        last = (direction, image)
        return image
    }
}
