import AppKit
import ImageIO

private struct FrameSpec: Decodable {
    let file: String
    let unitsPerPixel, anchorX: CGFloat
    let gripFromTop: CGFloat?
    let contact: [CGFloat]?
    let seconds: Double?
}
struct Temperament:Decodable {
    let backSleepWeight, sideSleepWeight, loafSleepWeight, quietRestWeight, irritationThreshold:Int
    let walkSpeed:Double
    let sleepDuration:[Double]
    var sleepTime:Double { .random(in:sleepDuration[0]...sleepDuration[1]) }
}
private struct TrackSpec: Decodable {
    let start, through, end: String
    let turnsAround: Bool?
}
private struct Descriptor: Decodable {
    let name:String
    let clips:[String:[FrameSpec]]
    let temperament:Temperament
    let transitions:[TrackSpec]?
}
enum ArtError: Error { case invalid(String) }

// Each key is a pose on the same rig. Interpolated poses and authored keys
// feed the same compositor, picking mask, floor scan and Dock silhouette.
final class RigRaster {
    let image, grounded:CGImage
    let context:CGContext
    let pixels:UnsafeMutablePointer<UInt8>
    init(_ pose:SkeletalPose) {
        let w=Int(pose.size.width),h=Int(pose.size.height)
        let ctx=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                          space:CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        pose.paint(in:ctx)
        context=ctx;pixels=ctx.data!.assumingMemoryBound(to:UInt8.self)
        image=ctx.makeImage()!
        let minInk=max(2,Int(ceil(Double(w)*0.06)))
        var bottom=h
        for y in (0..<h).reversed() {
            var ink=0
            for x in 0..<w where pixels[(y*w+x)*4+3]>=184 {ink+=1;if ink>=minInk {break}}
            if ink>=minInk {bottom=y+1;break}
        }
        grounded=bottom==h ? image:image.cropping(to:CGRect(x:0,y:0,width:w,height:bottom))!
    }
}

final class Cel {
    let pose:SkeletalPose
    let seconds:Double?
    private let contactFromTop:CGPoint?
    private static let renderedKeys:NSCache<NSObject,RigRaster> = {
        let cache=NSCache<NSObject,RigRaster>()
        cache.totalCostLimit=24*1024*1024
        return cache
    }()
    private let cacheKey:NSObject?
    private var renderedSample:RigRaster?
    private var raster:RigRaster {
        if let cacheKey {
            if let saved=Self.renderedKeys.object(forKey:cacheKey) {return saved}
            let value=RigRaster(pose)
            Self.renderedKeys.setObject(value,forKey:cacheKey,cost:value.image.bytesPerRow*value.image.height)
            return value
        }
        if let renderedSample {return renderedSample}
        let value=RigRaster(pose)
        renderedSample=value
        return value
    }
    var image:CGImage {raster.image}
    var groundedImage:CGImage {raster.grounded}
    var scale:CGFloat {pose.scale}
    var anchorX:CGFloat {pose.reversed ? pose.size.width-pose.anchor:pose.anchor}
    var gripHeight:CGFloat {pose.grip}
    var contact:CGPoint? {contactFromTop.map{CGPoint(x:$0.x,y:CGFloat(groundedImage.height)-$0.y)}}

    init(pose:SkeletalPose,seconds:Double?=nil,contact:CGPoint?=nil,reusable:Bool=false) {
        cacheKey=reusable ? NSObject():nil
        self.pose=pose;self.seconds=seconds;contactFromTop=contact
    }
    private weak var lastNeighbor:Cel?
    private weak var lastProjection:ProjectionInterpolator?
    private var lastFlip=false
    func toward(_ other:Cel,_ t:CGFloat,reflectEnd:Bool=false)->Cel {
        if t<=0 || (self === other && !reflectEnd) {return self}
        if t>=1 {return other}
        let end=reflectEnd ? other.pose.facingOpposite():other.pose
        var result=pose.toward(end,t)
        if pose.skin !== end.skin || pose.reversed != end.reversed || pose.projection != nil || end.projection != nil {
            let pair:ProjectionInterpolator
            if lastNeighbor === other,lastFlip==reflectEnd,let lastProjection {pair=lastProjection}
            else {
                pair=ProjectionInterpolator(a:raster,b:other.raster,from:pose,to:end,flip:reflectEnd)
                lastProjection=pair;lastNeighbor=other;lastFlip=reflectEnd
            }
            result.projection=ProjectionSample(pair:pair,time:t)
        }
        return Cel(pose:result)
    }
    private var restingSamples:[Int:Cel]=[:]
    func restingBreath(_ phase:CGFloat)->Cel {
        let step=Int((phase*5).rounded())
        if step==0 {return self}
        if let saved=restingSamples[step] {return saved}
        var joints=pose.joints
        if let index=pose.names.firstIndex(of:"chest") {
            let j=joints[index],amount=CGFloat(step)/5
            joints[index]=Joint(j.x,j.y,j.angle+amount*0.009,j.length,j.thickness*(1+amount*0.018))
        }
        let result=Cel(pose:pose.withJoints(joints),reusable:true)
        restingSamples[step]=result
        return result
    }
    func contains(_ p:CGPoint, height:Int)->Bool {
        guard p.x>=0,p.y>=0,p.x<pose.size.width,p.y<CGFloat(height) else{return false}
        return raster.pixels[((height-1-Int(p.y))*Int(pose.size.width)+Int(p.x))*4+3]>25
    }
    lazy var trailingClearance:[CGFloat] = {
        let raster=self.raster,w=raster.image.width,h=raster.grounded.height
        var result=[CGFloat](repeating:.infinity,count:w),lowest=h
        for x in (0..<w).reversed() {
            for depth in 0..<lowest where raster.pixels[((h-1-depth)*w+x)*4+3]>25 {
                lowest=depth;break
            }
            if lowest<h {result[x]=CGFloat(lowest)}
        }
        return result
    }()
}
final class PetArt {
    let name:String
    let temperament:Temperament
    let clips:[String:[Cel]]
    private let gait:[Cel]
    let transitions:[(frames:[Cel], turnsAround:Bool)]
    let descentProfiles:[DockProfile]
    init(root:URL,measuringDescent:Bool=false,calibratingViews:Bool=false) throws {
        if measuringDescent {descentProfiles=[]}
        else {
            descentProfiles=try JSONDecoder().decode([DockProfile].self,from:Data(contentsOf:root.appendingPathComponent("Rig/descent.json")))
            guard descentProfiles.count==DockMotion.samples*DockMotion.substeps+1 else {throw ArtError.invalid("Dock 接地轮廓")}
        }
        let data=try JSONDecoder().decode(Descriptor.self,from:Data(contentsOf:root.appendingPathComponent("pet.json")))
        let traits=data.temperament
        guard traits.sleepDuration.count==2,traits.sleepDuration[0]>0,traits.sleepDuration[1]>=traits.sleepDuration[0],
              traits.walkSpeed>0,traits.irritationThreshold>1 else {throw ArtError.invalid("无效的行为参数")}
        name=data.name;temperament=traits
        let skeleton=try Skeleton(root:root.appendingPathComponent("Rig"),calibrating:calibratingViews)
        var byFile:[String:Cel]=[:]
        let loaded=try data.clips.mapValues { specs in
            try specs.map { item in
                if let existing=byFile[item.file] {return existing}
                let pose=try skeleton.pose(item.file,scale:item.unitsPerPixel,anchor:item.anchorX,gripFromTop:item.gripFromTop)
                var point:CGPoint?
                if let c=item.contact {
                    guard c.count==2,(0..<pose.size.width).contains(c[0]),(0..<pose.size.height).contains(c[1])
                    else {throw ArtError.invalid(item.file)}
                    point=CGPoint(x:c[0],y:c[1])
                }
                let cel=Cel(pose:pose,seconds:item.seconds,contact:point,reusable:true)
                byFile[item.file]=cel;return cel
            }
        }
        guard let strides=loaded["walk"],strides.count==6 else {throw ArtError.invalid("步态")}
        let bind=strides[1]
        gait=try (0..<36).map {i in
            if i%6==0 {return strides[i/6]}
            let pose=try skeleton.pose("gait-\(i)",scale:bind.scale,anchor:bind.anchorX,gripFromTop:nil)
            return Cel(pose:pose,reusable:true)
        }
        clips=loaded
        transitions=try (data.transitions ?? []).map { track in
            guard let start=byFile[track.start],let end=byFile[track.end],
                  let between=loaded[track.through],!between.isEmpty else {throw ArtError.invalid(track.through)}
            return ([start]+between+[end],track.turnsAround ?? false)
        }
        for (key,n) in ["turn":6,"settle":9,"walk":6,"side":3,"back":3,"loaf":3,"paw":3,"swat":3,"nip":3,"carry":3,"leap":3,"stepDown":12,"hopUp":8,"release":4] {
            guard clips[key]?.count==n else {throw ArtError.invalid(key)}
        }
    }
    func walking(at elapsed:Double)->Cel {
        let phase=elapsed.truncatingRemainder(dividingBy:1.14)*Double(gait.count)/1.14
        let index=Int(phase)%gait.count
        return gait[index].toward(gait[(index+1)%gait.count],phase-floor(phase))
    }
    func cel(_ key:String,_ index:Int)->Cel { clips[key]![index] }
}
// The same mapping places the ink, its contact landmarks, and its clickable area.
struct SpriteDrawing {
    let cel: Cel
    let grounded: Bool
    let frame: CGRect
    let transform: CGAffineTransform
    var image: CGImage { grounded ? cel.groundedImage : cel.image }
    init(cel:Cel,grounded:Bool,mirror:Bool,feet:CGPoint,k:CGFloat,stretch:CGFloat,backing:CGFloat) {
        self.cel=cel;self.grounded=grounded
        let img=grounded ? cel.groundedImage:cel.image
        let horizontal=mirror ? -k:k
        var mapping=CGAffineTransform(a:horizontal,b:0,c:0,d:k*stretch,
                                      tx:feet.x-cel.anchorX*horizontal,ty:feet.y)
        let ink=CGRect(x:0,y:0,width:img.width,height:img.height).applying(mapping)
        let left=floor(ink.minX*backing)/backing, bottom=floor(ink.minY*backing)/backing
        frame=CGRect(x:left,y:bottom,width:ceil(ink.maxX*backing)/backing-left,
                     height:ceil(ink.maxY*backing)/backing-bottom)
        mapping.tx -= left;mapping.ty -= bottom
        transform=mapping
    }
    func paint(in cg:CGContext) {
        cg.saveGState()
        cg.concatenate(transform);cg.interpolationQuality = .high
        cg.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        cg.restoreGState()
    }
    func contains(_ p:CGPoint)->Bool {cel.contains(p.applying(transform.inverted()),height:image.height)}
}
final class PetView:NSView {
    weak var pet:PetController?
    var drawing:SpriteDrawing?
    override var isOpaque:Bool {false}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    override func draw(_ dirtyRect:NSRect) {
        guard let cg=NSGraphicsContext.current?.cgContext,let drawing else{return}
        cg.clear(bounds);drawing.paint(in:cg)
    }
    override func mouseDown(with event:NSEvent) {
        let down=event.window?.convertPoint(toScreen:event.locationInWindow) ?? NSEvent.mouseLocation
        pet?.press(at:down)
    }
    override func mouseDragged(with event:NSEvent) {pet?.drag(to:NSEvent.mouseLocation)}
    override func mouseUp(with event:NSEvent) {pet?.release(at:NSEvent.mouseLocation)}
    override func rightMouseDown(with event:NSEvent) {if let menu=pet?.controls {NSMenu.popUpContextMenu(menu,with:event,for:self)}}
}
final class PetPanel:NSPanel {
    override var canBecomeKey:Bool {false}
    override var canBecomeMain:Bool {false}
}
