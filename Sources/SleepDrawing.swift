import CoreGraphics
import Foundation

struct SleepProfile: Decodable {
    let chestX, chestRadius: CGFloat
    let whiskerTips: [CGPoint]   // centers of visible fans, fractions of the calibrated cel
}

struct SleepPhase: Equatable {
    let breath, twitch: Int
    init(age: Double, twitchStart: Double, awake: Bool = false) {
        // Quiet pause after exhaling; the silhouette returns to its resting drawing.
        let period = awake ? 3.7 : 4.9
        let cycle = age.truncatingRemainder(dividingBy: period) / period
        let inhale=min(1,cycle/0.38), exhale=min(1,max(0,(cycle-0.38)/0.51))
        let rise=(1-cos(.pi*inhale))/2, fall=(1-cos(.pi*exhale))/2
        breath=Int(((rise-fall)*(awake ? 9 : 14)).rounded())
        let t=(age-twitchStart)/0.38
        twitch=(0...1).contains(t) ? Int((4*sin(.pi*t)*sin(2 * .pi*t)).rounded()):0
    }
}

// Resample the same painting locally. Feet, tail and the panel stay registered.
// Breath-only paintings repeat for the whole nap. Twitch combinations are transient.
final class SleepDrawing {
    private let w,h:Int
    private let context:CGContext
    private let chest, whiskers:[Float]
    private var breaths:[Int:CGImage]=[:]
    private var lastTwitch:(SleepPhase,CGImage)?
    let original:CGImage

    init?(image:CGImage,profile:SleepProfile) {
        w=image.width;h=image.height;original=image
        let space=image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpaceCreateDeviceRGB()
        let info=CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:4*w,space:space,bitmapInfo:info) else {return nil}
        context=ctx
        ctx.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
        func lobe(_ distance:CGFloat)->CGFloat {
            let v=max(0,1-distance*distance)
            return v*v
        }
        var rib=[Float](repeating:0,count:w*h), tips=rib
        for y in 0..<h {
            let v=(CGFloat(y)+0.5)/CGFloat(h)
            let heightWeight=lobe(v/0.81)
            for x in 0..<w {
                let u=(CGFloat(x)+0.5)/CGFloat(w), i=y*w+x
                rib[i]=Float(lobe((u-profile.chestX)/profile.chestRadius)*heightWeight*CGFloat(h)*0.031)
                for p in profile.whiskerTips {
                    let dx=(u-p.x)/0.085, dy=(v-p.y)/(0.08*CGFloat(w)/CGFloat(h))
                    let weight=max(0,1-dx*dx-dy*dy)
                    tips[i]=max(tips[i],Float(weight*weight*CGFloat(w)*0.010))
                }
            }
        }
        chest=rib;whiskers=tips
    }

    private func displacement(at i:Int,phase:SleepPhase)->Float {
        chest[i]*Float(phase.breath)/14 + whiskers[i]*Float(phase.twitch)/4
    }

    func sourcePoint(_ p:CGPoint,phase:SleepPhase)->CGPoint {
        guard p.x>=0,p.y>=0,p.x<CGFloat(w),p.y<CGFloat(h) else {return p}
        return CGPoint(x:p.x,y:p.y+CGFloat(displacement(at:Int(p.y)*w+Int(p.x),phase:phase)))
    }

    func image(at phase:SleepPhase)->CGImage {
        if phase.twitch==0 {
            if phase.breath==0 {return original}
            if let cached=breaths[phase.breath] {return cached}
        } else if let (p,image)=lastTwitch,p==phase {return image}
        guard let out=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                                space:context.colorSpace!,bitmapInfo:context.bitmapInfo.rawValue) else {return original}
        let src=context.data!.assumingMemoryBound(to:UInt8.self), dst=out.data!.assumingMemoryBound(to:UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let i=y*w+x, from=Float(y)+displacement(at:i,phase:phase)
                let y0=Int(from.rounded(.down)), f=from-Float(y0)
                for channel in 0..<4 {
                    let a=(0..<h).contains(y0) ? Float(src[(y0*w+x)*4+channel]):0
                    let b=(0..<h).contains(y0+1) ? Float(src[((y0+1)*w+x)*4+channel]):0
                    dst[i*4+channel]=UInt8(clamping:Int((a+(b-a)*f).rounded()))
                }
            }
        }
        guard let image=out.makeImage() else {return original}
        if phase.twitch==0 {breaths[phase.breath]=image} else {lastTwitch=(phase,image)}
        return image
    }
}
