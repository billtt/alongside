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

final class Cel {
    let image, groundedImage: CGImage
    let scale, anchorX, gripHeight: CGFloat
    let contact: CGPoint?
    let seconds: Double?
    private let mask:NSBitmapImageRep
    init(url:URL,scale:CGFloat,anchorX:CGFloat,gripFromTop:CGFloat?,contact:[CGFloat]?,seconds:Double?) throws {
        guard let src=CGImageSourceCreateWithURL(url as CFURL,nil),
              let cg=CGImageSourceCreateImageAtIndex(src,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary)
        else {throw ArtError.invalid(url.lastPathComponent)}
        image=cg
        let pixels=NSBitmapImageRep(cgImage:cg)
        mask=pixels;self.scale=scale;self.anchorX=anchorX;self.seconds=seconds
        gripHeight=CGFloat(cg.height)-(gripFromTop ?? CGFloat(cg.height)*0.04)
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
        groundedImage=cg.cropping(to:CGRect(x:0,y:0,width:cg.width,height:height)) ?? cg
        if let contact {
            guard contact.count==2, (0..<CGFloat(cg.width)).contains(contact[0]),
                  (0..<CGFloat(height)).contains(contact[1]) else {throw ArtError.invalid(url.lastPathComponent)}
            self.contact=CGPoint(x:contact[0],y:CGFloat(height)-contact[1])
        } else {self.contact=nil}
    }
    func contains(_ p:CGPoint, height:Int)->Bool {
        guard p.x>=0,p.y>=0,p.x<CGFloat(image.width),p.y<CGFloat(height) else {return false}
        return (mask.colorAt(x:Int(p.x),y:height-1-Int(p.y))?.alphaComponent ?? 0)>0.10
    }
    // Distance from the lowest paw to the lowest ink at or behind each column
    // in the left-facing drawing. Used only for cels that straddle the Dock.
    lazy var trailingClearance: [CGFloat] = {
        let height=groundedImage.height
        var result=[CGFloat](repeating:.infinity,count:image.width)
        var lowest=height
        for col in (0..<image.width).reversed() {
            for depth in 0..<lowest {
                if (mask.colorAt(x:col,y:height-1-depth)?.alphaComponent ?? 0)>0.10 {
                    lowest=depth
                    break
                }
            }
            if lowest<height {result[col]=CGFloat(lowest)}
        }
        return result
    }()
}
final class PetArt {
    let name:String
    let temperament:Temperament
    let clips:[String:[Cel]]
    let transitions:[(frames:[Cel], turnsAround:Bool)]
    init(root:URL) throws {
        let data=try JSONDecoder().decode(Descriptor.self,from:Data(contentsOf:root.appendingPathComponent("pet.json")))
        let traits=data.temperament
        guard traits.sleepDuration.count==2,traits.sleepDuration[0]>0,traits.sleepDuration[1]>=traits.sleepDuration[0],
              traits.walkSpeed>0,traits.irritationThreshold>1 else {throw ArtError.invalid("无效的行为参数")}
        name=data.name;temperament=traits
        let loaded=try data.clips.mapValues { try $0.map {try Cel(url:root.appendingPathComponent($0.file),scale:$0.unitsPerPixel,anchorX:$0.anchorX,gripFromTop:$0.gripFromTop,contact:$0.contact,seconds:$0.seconds)} }
        clips=loaded
        var byFile:[String:Cel]=[:]
        for (key,specs) in data.clips {
            for (spec,cel) in zip(specs,loaded[key]!) {byFile[spec.file]=cel}
        }
        transitions=try (data.transitions ?? []).map { track in
            guard let start=byFile[track.start],let end=byFile[track.end],
                  let between=loaded[track.through],!between.isEmpty else {throw ArtError.invalid(track.through)}
            return ([start]+between+[end],track.turnsAround ?? false)
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
    func contains(_ p:CGPoint)->Bool {cel.contains(p.applying(transform.inverted()),height:image.height)}
}
final class PetView:NSView {
    weak var pet:PetController?
    var drawing:SpriteDrawing?
    override var isOpaque:Bool {false}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    override func draw(_ dirtyRect:NSRect) {
        guard let cg=NSGraphicsContext.current?.cgContext,let drawing else{return}
        cg.clear(bounds);cg.saveGState()
        cg.concatenate(drawing.transform)
        cg.interpolationQuality = .high
        let image=drawing.image
        cg.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));cg.restoreGState()
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
