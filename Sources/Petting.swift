import AppKit

enum TouchArea { case head, back, sensitive, neutral }
enum TouchResponse { case enjoy, notice, leave }

// Coordinates follow the original, unmirrored cel, measured from its top left.
struct TouchLayout: Decodable {
    let head, headRadius: CGPoint
    let back, sensitive: [CGPoint]

    func area(at point: CGPoint) -> TouchArea {
        let dx = (point.x-head.x)/headRadius.x, dy = (point.y-head.y)/headRadius.y
        if dx*dx + dy*dy <= 1 { return .head }
        if inside(point, polygon: sensitive) { return .sensitive }
        if inside(point, polygon: back) { return .back }
        return .neutral
    }

    private func inside(_ p: CGPoint, polygon: [CGPoint]) -> Bool {
        guard var a = polygon.last else { return false }
        var result = false
        for b in polygon {
            if (a.y > p.y) != (b.y > p.y) && p.x < (b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x {
                result.toggle()
            }
            a = b
        }
        return result
    }
}

struct PettingInput {
    private var sincePress = Double.infinity
    private var count = 0
    private var previousComfort = false
    private var held: Double?
    private var wantsSpace = false
    private var quietTime = 0.0

    mutating func press(_ area: TouchArea, threshold: Int, clickCount:Int = 1) -> TouchResponse? {
        if quietTime > 0 {quietTime=max(quietTime,0.85);return nil}
        count = sincePress <= 0.85 ? count+1 : 1
        sincePress = 0
        held = 0
        let comfort=area == .head || area == .back
        let doublePet=clickCount==2 && previousComfort && comfort
        wantsSpace = area == .sensitive || (count >= threshold && !doublePet)
        previousComfort=comfort
        guard !wantsSpace else {return nil}
        if doublePet {return .enjoy}
        return count==1 ? .notice:nil
    }

    mutating func advance(_ dt: Double) -> TouchResponse? {
        sincePress += dt
        quietTime = max(0, quietTime-dt)
        guard let elapsed = held else { return nil }
        held = elapsed+dt
        // Give an upward drag time to cross the pickup threshold.
        return elapsed+dt >= (wantsSpace ? 0.16 : 1.25) ? leave() : nil
    }

    mutating func release() -> TouchResponse? {
        defer { held = nil }
        return held != nil && wantsSpace ? leave() : nil
    }

    mutating func cancelDrag() {
        held = nil
        sincePress = .infinity
        count = 0
        previousComfort=false
        wantsSpace = false
    }

    private mutating func leave() -> TouchResponse {
        cancelDrag()
        quietTime = 3.5
        return .leave
    }
}

// Two feathered pieces of the original loaf expression fit the seated and prone faces.
// The unmodified face supplies the muzzle, fur, ears and outline in every phase.
struct EyeDrawing {
    let patches: [CGImage]
    private let eyeSpacing:CGFloat
    init?(face: CGImage, centers: [CGPoint]) {
        guard centers.count == 2, centers[1].x>centers[0].x else {return nil}
        eyeSpacing=centers[1].x-centers[0].x
        let w = 56, h = 40
        var result: [CGImage] = []
        for center in centers {
            guard let patch = face.cropping(to: CGRect(x: center.x-28,y: center.y-20,width: CGFloat(w),height: CGFloat(h))),
                  let ctx = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                                      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),
                  let gradient = CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),
                      colors:[CGColor(gray:1,alpha:1),CGColor(gray:1,alpha:1),CGColor(gray:1,alpha:0)] as CFArray,
                      locations:[0,0.68,1]) else { return nil }
            ctx.scaleBy(x:28,y:20)
            ctx.drawRadialGradient(gradient,startCenter:CGPoint(x:1,y:1),startRadius:0,
                                   endCenter:CGPoint(x:1,y:1),endRadius:1,options:[])
            ctx.setBlendMode(.sourceIn)
            ctx.draw(patch,in:CGRect(x:0,y:0,width:2,height:2))
            guard let image=ctx.makeImage() else { return nil }
            result.append(image)
        }
        patches=result
    }

    func draw(in ctx: CGContext, on image: CGImage, centers: [CGPoint]) {
        // Only the far-facing eye is visible when Dada looks over his shoulder.
        if centers.count==1, let p=centers.first {
            ctx.saveGState();ctx.translateBy(x:p.x,y:CGFloat(image.height)-p.y)
            ctx.rotate(by:-0.38)
            ctx.draw(patches[1],in:CGRect(x:-20,y:-13,width:40,height:26));ctx.restoreGState()
            return
        }
        let scale=(centers[1].x-centers[0].x)/eyeSpacing
        for (patch,p) in zip(patches,centers) {
            let w=CGFloat(patch.width)*scale,h=CGFloat(patch.height)*scale
            ctx.draw(patch,in:CGRect(x:p.x-w/2,y:CGFloat(image.height)-p.y-h/2,width:w,height:h))
        }
    }
}

struct PetHeart: Equatable {
    let center: CGPoint
    let size, opacity: CGFloat

    func draw(in cg: CGContext) {
        cg.saveGState()
        cg.translateBy(x:center.x,y:center.y)
        cg.scaleBy(x:size,y:size)
        cg.setFillColor(CGColor(red:0.90,green:0.43,blue:0.48,alpha:opacity))
        cg.move(to:CGPoint(x:0,y:-0.46))
        cg.addCurve(to:CGPoint(x:-0.46,y:0.18),control1:CGPoint(x:-0.12,y:-0.31),control2:CGPoint(x:-0.52,y:-0.04))
        cg.addCurve(to:CGPoint(x:0,y:0.28),control1:CGPoint(x:-0.42,y:0.52),control2:CGPoint(x:-0.12,y:0.50))
        cg.addCurve(to:CGPoint(x:0.46,y:0.18),control1:CGPoint(x:0.12,y:0.50),control2:CGPoint(x:0.42,y:0.52))
        cg.addCurve(to:CGPoint(x:0,y:-0.46),control1:CGPoint(x:0.52,y:-0.04),control2:CGPoint(x:0.12,y:-0.31))
        cg.closePath(); cg.fillPath(); cg.restoreGState()
    }
}
