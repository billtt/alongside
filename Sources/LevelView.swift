import CoreGraphics
import Foundation

// A resting body bears weight inside this band of the unmirrored artwork.
struct RestingContact: Decodable {
    let body: [CGFloat]
    let overhang: CGFloat   // in pet units, shared by differently sized drawings
}

// Coordinates in the painter's unmirrored, top-down pixel grid. Each column has
// a displacement for the upper body and a separate one for its supporting mass.
struct LevelView {
    struct Column {
        let upper, sole: CGFloat

        func projected(_ y: CGFloat) -> CGFloat {
            let t = min(1, max(0, (y - 0.34) / 0.54))
            return y + upper + (sole - upper) * t
        }

        func original(_ y: CGFloat) -> CGFloat {
            if y <= 0.34 + upper { return y - upper }
            if y >= 0.88 + sole { return y - sole }
            return 0.34 + (y - 0.34 - upper) * 0.54 / (0.54 + sole - upper)
        }
    }
    let columns: [Column]
    let height: CGFloat
    let supportFromTop: CGFloat?

    func projected(_ pixel: CGPoint) -> CGPoint {
        let c = columns[min(columns.count-1, max(0, Int(pixel.x)))]
        return CGPoint(x: pixel.x, y: c.projected(pixel.y / height) * height)
    }

    func original(_ pixel: CGPoint) -> CGPoint {
        let c = columns[min(columns.count-1, max(0, Int(pixel.x)))]
        return CGPoint(x: pixel.x, y: c.original(pixel.y / height) * height)
    }

    // A knot holds x, upper-body depth relief, and the share of the local
    // ground gap to remove. A zero third value leaves a swinging foot free.
    static func render(_ source: CGImage, knots: [[CGFloat]], contact: RestingContact?, scale: CGFloat, weight: CGFloat, plantedPaws:[CGFloat]) throws -> (CGImage, LevelView) {
        let w = source.width, h = source.height
        guard w > 1, knots.count >= 2, knots.allSatisfy({ $0.count == 3 && (0...1).contains($0[0]) &&
            (0...0.25).contains($0[1]) && (0...1).contains($0[2]) }),
            zip(knots, knots.dropFirst()).allSatisfy({ $0[0] < $1[0] }),
            knots.first![0] == 0, knots.last![0] == 1 else { throw ArtError.invalid("平视标定点") }
        if let contact {
            guard contact.body.count == 2, contact.body[0] >= 0, contact.body[1] <= 1,
                  contact.body[0] < contact.body[1], (0...0.06).contains(contact.overhang),
                  (0...1).contains(weight), scale > 0 else { throw ArtError.invalid("承重线标定") }
        }
        let space = source.colorSpace?.model == .rgb ? source.colorSpace! : CGColorSpaceCreateDeviceRGB()
        func bitmap() throws -> CGContext {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                                      space: space, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw ArtError.invalid("平视画布") }
            return ctx
        }
        let input = try bitmap(), output = try bitmap()
        input.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        let src = input.data!.assumingMemoryBound(to: UInt8.self)
        let dst = output.data!.assumingMemoryBound(to: UInt8.self)
        return try withExtendedLifetime((input, output)) {
            var bottoms = [Int](repeating: -1, count: w), groundRow = 0
            for row in (0..<h).reversed() {
                var ink = 0
                for x in 0..<w where src[(row*w+x)*4+3] >= 184 {
                    if bottoms[x] < 0 { bottoms[x] = row }
                    ink += 1
                }
                if groundRow == 0 && ink >= max(2, Int(ceil(Double(w)*0.06))) { groundRow = row }
            }
            let sole: [CGFloat] = knots.enumerated().map { i, knot in
                // Beyond the last pad, carry its displacement through the round
                // rump or tail. The extreme outline itself is never a support.
                let reference = knots[min(knots.count-2, max(1,i))][0]
                let x = Int(reference*CGFloat(w-1)), r = max(2, w/40)
                let bottom = bottoms[max(0,x-r)...min(w-1,x+r)].max()!
                guard bottom >= 0 else { return 0 }
                return min(0.12, CGFloat(max(0,groundRow-bottom))/CGFloat(h)) * knot[2]
            }
            var columns: [Column] = [], segment = 0
            for x in 0..<w {
                let u = CGFloat(x)/CGFloat(w-1)
                while segment+2 < knots.count && u > knots[segment+1][0] { segment += 1 }
                let a = knots[segment], b = knots[segment+1]
                let t = (u-a[0])/(b[0]-a[0]), s = t*t*(3-2*t)
                let shift = sole[segment]+(sole[segment+1]-sole[segment])*s
                let room = CGFloat(max(0,groundRow-bottoms[x])) / CGFloat(h)
                columns.append(Column(upper: a[1]+(b[1]-a[1])*s, sole: min(room,shift)))
            }
            // Register the lower torso to the support plane. Nearby paws and the
            // curled tail keep their drawn outline and can extend in front of it.
            var support: CGFloat?
            if let contact {
                let plane = CGFloat(groundRow + 1) - contact.overhang * weight / scale
                support = plane
                let height = CGFloat(h), width = CGFloat(w)
                let contour = bottoms.enumerated().map { x, y in
                    columns[x].projected((CGFloat(y)+0.5)/height)*height
                }
                let radius = max(1, w/180)
                for x in 0..<w {
                    let u = CGFloat(x)/width
                    let margin = min(u-contact.body[0], contact.body[1]-u)
                    let blend = min(1, max(0, 1+margin/0.055))
                    guard blend > 0 else { continue }
                    // Average a few adjacent tips of fur so the new baseline
                    // retains the ink texture and the joints keep their shape.
                    let nearby = contour[max(0,x-radius)...min(w-1,x+radius)]
                    let bottom = nearby.reduce(0,+)/CGFloat(nearby.count)
                    let gap = plane-bottom
                    let nearSurface = min(1, max(0,(width*0.075-gap)/(width*0.035)))
                    let correction = (gap+width*0.005)*nearSurface*blend*blend*(3-2*blend)*weight
                    columns[x] = Column(upper: columns[x].upper, sole: columns[x].sole+correction/height)
                }
            }
            if !plantedPaws.isEmpty {
                // During a turn the far planted leg was drawn higher in perspective.
                // Measure its pad on the level-view drawing before adjusting either leg.
                let plane=support ?? CGFloat(groundRow+1)-0.006/scale
                support=plane
                let original=columns, height=CGFloat(h), width=CGFloat(w)
                for foot in plantedPaws {
                    let center=Int(foot*width), radius=max(2,Int(width*0.017))
                    let pad=(max(0,center-radius)...min(w-1,center+radius)).map { x in
                        original[x].projected((CGFloat(bottoms[x])+0.5)/height)*height
                    }.sorted()
                    let gap=max(0,plane+1-pad[3*pad.count/4])
                    guard gap>0 else {continue}
                    for x in 0..<w {
                        let distance=(CGFloat(x)/width-foot)/0.125
                        let t=min(1,max(0,(abs(distance)-0.34)/0.66))
                        let shift=gap*(1-t*t*(3-2*t))/height
                        let c=original[x]
                        columns[x]=Column(upper:max(columns[x].upper,c.upper+0.24*shift),
                                          sole:max(columns[x].sole,c.sole+shift))
                    }
                }
            }
            let view = LevelView(columns: columns, height: CGFloat(h), supportFromTop: support)
            // Interpolate premultiplied color and alpha together to keep fine fur edges.
            for y in 0..<h {
                for x in 0..<w {
                    let from = columns[x].original((CGFloat(y)+0.5)/CGFloat(h))*CGFloat(h)-0.5
                    guard from > -1 && from < CGFloat(h) else { continue }
                    let y0 = Int(from.rounded(.down)), fraction = from-CGFloat(y0)
                    let offset = (y*w+x)*4
                    for ch in 0..<4 {
                        let a = y0 >= 0 ? CGFloat(src[(y0*w+x)*4+ch]) : 0
                        let b = y0+1 < h ? CGFloat(src[((y0+1)*w+x)*4+ch]) : 0
                        dst[offset+ch] = UInt8(clamping: Int((a+(b-a)*fraction).rounded()))
                    }
                }
            }
            guard let image = output.makeImage() else { throw ArtError.invalid("平视原画") }
            return (image, view)
        }
    }
}
