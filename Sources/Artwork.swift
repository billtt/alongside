import AppKit
import ImageIO

private struct FrameSpec: Decodable {
    let sleepDrawing: SleepProfile?
    let file: String
    let unitsPerPixel, anchorX: CGFloat
    let gripFromTop, pitchDegrees, restingWeight: CGFloat?
    let eyeCenters: [CGPoint]?
    let contact: [CGFloat]?
    let seconds: Double?
}
struct Temperament:Decodable {
    let backSleepWeight, sideSleepWeight, loafSleepWeight, quietRestWeight, irritationThreshold:Int
    let walkSpeed:Double
    let sleepDuration:[Double]
    let restDuration:[Double]?
    var restTime:Double {let r=restDuration ?? sleepDuration;return .random(in:r[0]...r[1])}
    var sleepTime:Double { .random(in:sleepDuration[0]...sleepDuration[1]) }
}
private struct TrackSpec: Decodable {
    let start, through, end: String
    let turnsAround: Bool?
    let plantedPaws: [[CGFloat]]?
}
private struct Descriptor: Decodable {
    let name:String
    let clips:[String:[FrameSpec]]
    let temperament:Temperament
    let levelView: LevelViewSpec?
    let clipScale:[String:[CGFloat]]?
    let gaitSpeed:CGFloat?
    let walkContacts:[[CGFloat]]?
    let touchLayouts:[String:TouchLayout]?
    let clipLayouts:[String:[String]]?
    let transitions:[TrackSpec]?
}
private struct LevelViewSpec: Decodable {
    let profiles: [String: [[CGFloat]]]
    let restingContacts: [String: RestingContact]?
    let clips: [String: [String]]
}
enum ArtError: Error { case invalid(String) }

final class Cel {
    let image, groundedImage: CGImage
    let scale, anchorX, gripHeight: CGFloat
    let supportOffset: CGFloat  // distance up from the bottom of the grounded image
    let contact: CGPoint?
    let seconds: Double?
    fileprivate(set) var touchLayout:TouchLayout?
    fileprivate(set) var eyeCenters:[CGPoint]?
    fileprivate var sleepProfile:SleepProfile?
    lazy var sleeping:SleepDrawing?=sleepProfile.flatMap {SleepDrawing(image:groundedImage,profile:$0)}
    let sourceSize: CGSize
    private let levelView: LevelView?
    private let pitch: CGAffineTransform
    private let mask:NSBitmapImageRep
    init(url:URL,scale:CGFloat,anchorX:CGFloat,gripFromTop:CGFloat?,contact:[CGFloat]?,seconds:Double?,pitchDegrees:CGFloat?=nil,levelKnots:[[CGFloat]]?=nil,restingContact:RestingContact?=nil,restingWeight:CGFloat=1,plantedPaws:[CGFloat]=[]) throws {
        guard let src=CGImageSourceCreateWithURL(url as CFURL,nil),
              var cg=CGImageSourceCreateImageAtIndex(src,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary)
        else {throw ArtError.invalid(url.lastPathComponent)}
        sourceSize = CGSize(width: cg.width, height: cg.height)
        if let levelKnots, !levelKnots.isEmpty {
            (cg, levelView) = try LevelView.render(cg, knots: levelKnots, contact: restingContact, scale: scale, weight: restingWeight, plantedPaws: plantedPaws)
        } else { levelView = nil }
        var pivot=anchorX
        if let angle=pitchDegrees {
            let rotation=CGAffineTransform(rotationAngle:angle * .pi/180)
            let src=CGRect(x:0,y:0,width:cg.width,height:cg.height)
            let bounds=src.applying(rotation).integral
            guard let ctx=CGContext(data:nil,width:Int(bounds.width),height:Int(bounds.height),bitsPerComponent:8,
                                    bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)
            else {throw ArtError.invalid(url.lastPathComponent)}
            ctx.translateBy(x:-bounds.minX,y:-bounds.minY);ctx.concatenate(rotation)
            ctx.interpolationQuality = .high;ctx.draw(cg,in:src)
            guard let rotated=ctx.makeImage() else {throw ArtError.invalid(url.lastPathComponent)}
            pivot=CGPoint(x:anchorX,y:src.midY).applying(rotation).x-bounds.minX
            // Landmarks are measured from the PNG's top edge; Core Graphics rotates y-up.
            pitch=CGAffineTransform(a:rotation.a,b:-rotation.b,c:-rotation.c,d:rotation.d,
                                    tx:rotation.c*src.height-bounds.minX,ty:bounds.maxY-rotation.d*src.height)
            cg=rotated
        } else { pitch = .identity }
        image=cg
        let pixels=NSBitmapImageRep(cgImage:cg)
        mask=pixels;self.scale=scale;self.anchorX=pivot;self.seconds=seconds
        let grip=CGPoint(x:anchorX,y:gripFromTop ?? sourceSize.height*0.04)
        gripHeight=CGFloat(cg.height)-(levelView?.projected(grip) ?? grip).applying(pitch).y
        // A whisker or a few antialias pixels below a foot do not support the animal.
        let minInk=max(2,Int(ceil(Double(cg.width)*0.06)))
        var height=cg.height
        for row in (0..<cg.height).reversed() {
            var ink=0
            for col in 0..<cg.width where (pixels.colorAt(x:col,y:row)?.alphaComponent ?? 0) >= 0.72 {
                ink += 1
                if ink>=minInk {break}
            }
            if ink>=minInk {height=row+1;break}
        }
        if let plane=levelView?.supportFromTop {
            height=cg.height
            supportOffset=CGFloat(height)-CGPoint(x:anchorX,y:plane).applying(pitch).y
        } else {supportOffset=0}
        groundedImage=cg.cropping(to:CGRect(x:0,y:0,width:cg.width,height:height)) ?? cg
        if let contact {
            guard contact.count==2, (0..<sourceSize.width).contains(contact[0]),
                  (0..<sourceSize.height).contains(contact[1]) else {throw ArtError.invalid(url.lastPathComponent)}
            let p=CGPoint(x:contact[0],y:contact[1])
            let placed=(levelView?.projected(p) ?? p).applying(pitch)
            self.contact=CGPoint(x:placed.x,y:CGFloat(height)-placed.y)
        } else {self.contact=nil}
    }
    func projected(_ source:CGPoint)->CGPoint {(levelView?.projected(source) ?? source).applying(pitch)}
    func original(_ pixel:CGPoint)->CGPoint {
        let level=pixel.applying(pitch.inverted())
        return levelView?.original(level) ?? level
    }
    func contains(_ p:CGPoint, height:Int)->Bool {
        guard p.x>=0,p.y>=0,p.x<CGFloat(image.width),p.y<CGFloat(height) else {return false}
        return (mask.colorAt(x:Int(p.x),y:height-1-Int(p.y))?.alphaComponent ?? 0)>0.10
    }
    private lazy var sole:[CGFloat] = {
        let h=groundedImage.height
        let ctx=CGContext(data:nil,width:image.width,height:h,bitsPerComponent:8,bytesPerRow:image.width*4,
                          space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(groundedImage,in:CGRect(x:0,y:0,width:image.width,height:h))
        let alpha=ctx.data!.assumingMemoryBound(to:UInt8.self)
        return withExtendedLifetime(ctx) {(0..<image.width).map { col in
            for depth in 0..<h where alpha[(h-1-depth)*ctx.bytesPerRow+col*4+3]>25 {
                return CGFloat(depth)
            }
            return .infinity
        }}
    }()
    // Lowest visible pixel among all columns on the platform side of the edge.
    lazy var leadingClearance:[CGFloat] = envelope(trailing:false)
    lazy var trailingClearance:[CGFloat] = envelope(trailing:true)
    private func envelope(trailing:Bool)->[CGFloat] {
        var result=sole, lowest=CGFloat.infinity
        for n in result.indices {
            let i=trailing ? result.count-1-n:n
            lowest=min(lowest,result[i]);result[i]=lowest
        }
        return result
    }

}
final class PetArt {
    let name:String
    let temperament:Temperament
    let gait:WalkCycle
    let eyelids:[EyeDrawing]
    let clips:[String:[Cel]]
    let transitions:[(frames:[Cel], turnsAround:Bool, paws:[[CGFloat]]?)]
    init(root:URL) throws {
        let data=try JSONDecoder().decode(Descriptor.self,from:Data(contentsOf:root.appendingPathComponent("pet.json")))
        let traits=data.temperament
        guard traits.sleepDuration.count==2,traits.sleepDuration[0]>0,traits.sleepDuration[1]>=traits.sleepDuration[0],
              traits.walkSpeed>0,traits.irritationThreshold>1 else {throw ArtError.invalid("无效的行为参数")}
        if let r=traits.restDuration, r.count != 2 || r[0]<=0 || r[1]<r[0] {throw ArtError.invalid("休息时长")}
        name=data.name;temperament=traits
        var loaded:[String:[Cel]]=[:]
        if let view=data.levelView, Set(view.clips.keys) != Set(data.clips.keys) {
            throw ArtError.invalid("平视标定未覆盖所有动作")
        }
        var supports:[String:Set<CGFloat>]=[:]
        for track in data.transitions ?? [] {
            guard let pairs=track.plantedPaws else {continue}
            guard let between=data.clips[track.through],pairs.count==between.count+1,
                  pairs.allSatisfy({$0.count==2 && $0.allSatisfy((0...1).contains)}) else {throw ArtError.invalid(track.through)}
            let files=[track.start]+between.map(\.file)+[track.end]
            for (i,pair) in pairs.enumerated() {
                supports[files[i],default:[]].insert(pair[0])
                supports[files[i+1],default:[]].insert(pair[1])
            }
        }
        for (key,specs) in data.clips {
            let scales=data.clipScale?[key] ?? [1]
            guard (scales.count==1 || scales.count==specs.count),scales.allSatisfy({$0>0}) else {throw ArtError.invalid(key)}
            let views=data.levelView?.clips[key]
            if let views, views.count != 1 && views.count != specs.count {throw ArtError.invalid(key)}
            loaded[key]=try specs.enumerated().map { i,spec in
                var knots:[[CGFloat]]?
                var resting:RestingContact?
                if let views {
                    let name=views[views.count==1 ? 0:i]
                    guard let profile=data.levelView?.profiles[name] else {throw ArtError.invalid(name)}
                    knots=profile
                    resting=data.levelView?.restingContacts?[name]
                }
                return try Cel(url:root.appendingPathComponent(spec.file),scale:spec.unitsPerPixel*scales[scales.count==1 ? 0:i],
                        anchorX:spec.anchorX,gripFromTop:spec.gripFromTop,contact:spec.contact,seconds:spec.seconds,pitchDegrees:spec.pitchDegrees,levelKnots:knots,
                        restingContact:resting,restingWeight:spec.restingWeight ?? 1,plantedPaws:supports[spec.file]?.sorted() ?? [])
            }
        }
        for (key, names) in data.clipLayouts ?? [:] {
            guard let frames = loaded[key], names.count == 1 || names.count == frames.count else {throw ArtError.invalid(key)}
            for (i, cel) in frames.enumerated() {
                guard let layout = data.touchLayouts?[names.count == 1 ? names[0] : names[i]],
                      layout.headRadius.x > 0, layout.headRadius.y > 0 else {throw ArtError.invalid(key)}
                cel.touchLayout = layout
            }
        }
        guard let walk=loaded["walk"],walk.count==6 else {throw ArtError.invalid("walk")}
        gait=try WalkCycle(frames:walk,contacts:data.walkContacts,speed:data.gaitSpeed ?? traits.walkSpeed)
        clips=loaded
        var byFile:[String:Cel]=[:]
        for (key,specs) in data.clips {
            for (spec,cel) in zip(specs,loaded[key]!) {
                cel.sleepProfile=spec.sleepDrawing
                if let eyes=spec.eyeCenters {
                    guard eyes.count==1 || (eyes.count==2 && eyes[1].x>eyes[0].x) else {throw ArtError.invalid(spec.file)}
                    cel.eyeCenters=eyes.map(cel.projected)
                }
                byFile[spec.file]=cel
            }
        }
        eyelids=(loaded["loaf"] ?? []).dropFirst().compactMap { cel in
            cel.eyeCenters.flatMap {EyeDrawing(face:cel.image,centers:$0)}
        }
        transitions=try (data.transitions ?? []).map { track in
            guard let start=byFile[track.start],let end=byFile[track.end],
                  let between=loaded[track.through],!between.isEmpty else {throw ArtError.invalid(track.through)}
            return ([start]+between+[end],track.turnsAround ?? false,track.plantedPaws)
        }
        for (key,n) in ["turn":6,"settle":9,"walk":6,"side":3,"back":3,"loaf":3,"paw":3,"swat":3,"nip":3,"carry":3,"leap":3,"stepDown":12,"hopUp":8,"release":4] {
            guard clips[key]?.count==n else {throw ArtError.invalid(key)}
        }
    }
    func cel(_ key:String,_ index:Int)->Cel { clips[key]![index] }
}
// The same mapping places the ink, its contact landmarks, and its clickable area.
struct SpriteDrawing {
    let cel: Cel
    let grounded: Bool
    let frame: CGRect
    let transform: CGAffineTransform
    let image:CGImage
    let sleepPhase:SleepPhase?
    init(cel:Cel,grounded:Bool,mirror:Bool,feet:CGPoint,k:CGFloat,stretch:CGFloat,backing:CGFloat,headroom:CGFloat=0,screenFloor:CGFloat?=nil,sleepPhase:SleepPhase?=nil) {
        self.cel=cel;self.grounded=grounded
        self.sleepPhase=sleepPhase
        let img=sleepPhase.flatMap {cel.sleeping?.image(at:$0)} ?? (grounded ? cel.groundedImage:cel.image)
        image=img
        let horizontal=mirror ? -k:k
        let base=feet.y-(grounded ? cel.supportOffset*k*stretch:0)
        var mapping=CGAffineTransform(a:horizontal,b:0,c:0,d:k*stretch,
                                      tx:feet.x-cel.anchorX*horizontal,ty:base)
        let ink=CGRect(x:0,y:0,width:img.width,height:img.height).applying(mapping)
        let left=floor(ink.minX*backing)/backing
        var bottom=floor(ink.minY*backing)/backing
        if grounded, cel.supportOffset>0, let screenFloor {bottom=max(screenFloor,bottom)}
        frame=CGRect(x:left,y:bottom,width:ceil(ink.maxX*backing)/backing-left,
                     height:ceil((ink.maxY+headroom)*backing)/backing-bottom)
        mapping.tx -= left;mapping.ty -= bottom
        transform=mapping
    }
    func touchArea(at p:CGPoint)->TouchArea? {
        guard contains(p) else {return nil}
        let pixel=p.applying(transform.inverted())
        let source=cel.original(sourcePixel(pixel))
        let normalized=CGPoint(x:source.x/cel.sourceSize.width,y:source.y/cel.sourceSize.height)
        return cel.touchLayout?.area(at:normalized) ?? .neutral
    }
    var headTop:CGPoint? {
        guard let layout=cel.touchLayout else {return nil}
        let p=cel.projected(CGPoint(x:layout.head.x*cel.sourceSize.width,
                                    y:max(0,layout.head.y-layout.headRadius.y)*cel.sourceSize.height))
        return CGPoint(x:p.x,y:CGFloat(image.height)-p.y).applying(transform)
    }
    func heart(progress:Double,unit:CGFloat,origin:CGPoint?=nil)->PetHeart? {
        guard let top=origin ?? headTop else {return nil}
        let size=clamp(unit*0.105,8,31)
        return PetHeart(center:CGPoint(x:top.x+size*0.16*progress,y:top.y+size*(0.6+1.45*progress)),
                        size:size*(0.78+0.22*min(1,progress*5)),opacity:0.92*min(1,(1-progress)*3))
    }
    private func sourcePixel(_ p:CGPoint)->CGPoint {
        let top=CGPoint(x:p.x,y:CGFloat(image.height)-p.y)
        if let sleepPhase,let sleep=cel.sleeping {return sleep.sourcePoint(top,phase:sleepPhase)}
        return top
    }
    func contains(_ p:CGPoint)->Bool {
        guard CGRect(origin:.zero,size:frame.size).contains(p) else {return false}
        let pixel=sourcePixel(p.applying(transform.inverted()))
        return cel.contains(CGPoint(x:pixel.x,y:CGFloat(image.height)-pixel.y),height:image.height)
    }
}
final class PetView:NSView {
    weak var pet:PetController?
    var drawing:SpriteDrawing?
    var heart:PetHeart?
    var eyelids:EyeDrawing?
    override var isOpaque:Bool {false}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    override func draw(_ dirtyRect:NSRect) {
        guard let cg=NSGraphicsContext.current?.cgContext,let drawing else{return}
        cg.clear(bounds);cg.saveGState()
        cg.concatenate(drawing.transform)
        cg.interpolationQuality = .high
        let image=drawing.image
        cg.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        if let centers=drawing.cel.eyeCenters {eyelids?.draw(in:cg,on:image,centers:centers)}
        cg.restoreGState()
        heart?.draw(in:cg)
    }
    override func mouseDown(with event:NSEvent) {
        let down=event.window?.convertPoint(toScreen:event.locationInWindow) ?? NSEvent.mouseLocation
        pet?.press(at:down,clickCount:event.clickCount)
    }
    override func mouseDragged(with event:NSEvent) {pet?.drag(to:NSEvent.mouseLocation)}
    override func mouseUp(with event:NSEvent) {pet?.release(at:NSEvent.mouseLocation)}
    override func rightMouseDown(with event:NSEvent) {if let menu=pet?.controls {NSMenu.popUpContextMenu(menu,with:event,for:self)}}
}
final class PetPanel:NSPanel {
    override var canBecomeKey:Bool {false}
    override var canBecomeMain:Bool {false}
}
