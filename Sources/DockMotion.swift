import Foundation

/// Entry and exit steps use the ordinary gait. The transfer between them is
/// measured relative to the near lip, in the animal's direction of travel.
struct DockMotion {
    let hop:Hop
    let duration:Double
    let exitStride:Int
    private struct Beat {
        let cel:Cel, time:Double, x:CGFloat
        let moving:Bool
    }
    private let beats:[Beat]
    private let heights:[CGFloat]
    private static let samples=240

    init(hop:Hop, edge:CGFloat, unit:CGFloat, art:PetArt, entryStride:Int=0) {
        self.hop=hop
        let down=hop.descending, sign:CGFloat=hop.endX>hop.startX ? 1:-1
        let start=(hop.startX-edge)*sign/unit,end=(hop.endX-edge)*sign/unit
        var list:[Beat]=[],clock=0.0,travel=start,stride=entryStride
        func beat(_ cel:Cel,_ x:CGFloat,_ seconds:Double,moving:Bool=false) {
            travel=clamp(x,start,end)
            list.append(Beat(cel:cel,time:clock,x:edge+sign*unit*travel,moving:moving))
            clock+=seconds
        }
        func walk(to stop:CGFloat) {
            while travel<stop-0.0001 {
                let d=art.gait.distances[stride]
                beat(art.cel("walk",stride),travel,min(1,(stop-travel)/d)*0.085)
                travel=min(stop,travel+d)
                stride=(stride+1)%art.gait.distances.count
            }
        }
        let approachClearance=art.clips["walk"]!.map {$0.anchorX*$0.scale}.max()!
        walk(to:down ? -0.43:-approachClearance-0.035)
        let coreStart=travel
        if down {
            // Reach below the edge, carry the shoulders past it, then gather the hind feet.
            let offsets:[CGFloat]=[0,0.035,0.10,0.20,0.32,0.45,0.61,0.80,0.97,1.10,1.19,1.26]
            let holds=[0.065,0.075,0.080,0.065,0.052,0.042,0.040,0.045,0.055,0.065,0.085,0.095]
            let descent:[CGFloat]=[0,0,0.04,0.16,0.38,0.64,0.87,1,1,1,1,1]
            for i in offsets.indices {
                let cel=art.cel("stepDown",i)
                let clearance=descent[i]*(hop.startY-hop.endY)/(unit*cel.scale)
                let column=cel.trailingClearance.firstIndex(where:{$0>=clearance}) ?? cel.image.width
                let safe=(CGFloat(column+2)-cel.anchorX)*cel.scale
                beat(cel,max(travel,coreStart+offsets[i],safe),holds[i],moving:(3...8).contains(i))
            }
        } else {
            // Keep the look and coil on the floor. The forward toes on the reach
            // and catch drawings land on the same patch just inside the lip.
            beat(art.cel("hopUp",0),travel,0.075)
            beat(art.cel("hopUp",1),travel+0.06,0.13)
            beat(art.cel("hopUp",2),travel+0.012,0.070)
            beat(art.cel("hopUp",3),travel+0.11,0.085,moving:true)
            let up=art.clips["hopUp"]!
            let landing=min(0.40,end+0.13)
            func onForepaw(_ i:Int,_ toe:CGFloat)->CGFloat {landing-(up[i].anchorX-toe)*up[i].scale}
            // The full stretch is useful only on a high Dock relative to the pet.
            if (hop.endY-hop.startY)/unit>0.60 {
                beat(up[4],max(travel,onForepaw(4,19)-0.17),0.043,moving:true)
            }
            beat(up[5],max(travel,onForepaw(5,18)),0.050)
            beat(up[6],max(travel,onForepaw(6,32)),0.068)
            beat(up[7],max(travel,onForepaw(7,79)),0.065)
            let standing=art.cel("walk",0)
            // The reaching paw now stands underneath the shoulder in walk 0.
            travel=clamp(landing-(standing.anchorX-209)*standing.scale,travel,end)
        }
        // First stride already shares the platform with the gathered feet.
        stride=down ? 1:0
        walk(to:end)
        beat(art.cel("walk",stride),end,0.035)
        beats=list;duration=clock;exitStride=stride

        let count=Self.samples
        var limits=[CGFloat](repeating:min(hop.startY,hop.endY),count:count+1)
        let top=max(hop.startY,hop.endY), floor=min(hop.startY,hop.endY)
        for i in 0...count {
            let time=clock*Double(i)/Double(count)
            let dt=clock/Double(count)
            let lo=max(0,time-dt), hi=min(clock,time+dt)
            // At a discrete stride step, evaluate each drawing at its own position.
            for n in Self.index(lo,list)...Self.index(hi,list) {
                let cel=list[n].cel, k=unit*cel.scale
                let first=max(lo,list[n].time), last=min(hi,n+1<list.count ? list[n+1].time:clock)
                let x=Self.x(down ? first:last,n,list)
                let boundary=cel.anchorX+(x-edge)*sign/k
                if down {
                    let col=max(0,Int(boundary.rounded(.down))-1)
                    if col<cel.image.width {limits[i]=max(limits[i],top-cel.trailingClearance[col]*k)}
                } else {
                    let col=min(cel.image.width-1,Int(ceil(boundary))+1)
                    if col>=0 {limits[i]=max(limits[i],top-cel.leadingClearance[col]*k)}
                }
            }
        }
        // Anticipate clearance and ease a change of support over several samples.
        let maxStep=(top-floor)*7.5/CGFloat(count)
        if down {
            for i in (0..<count).reversed() {limits[i]=max(limits[i],limits[i+1])}
            let landingSlope=(0..<count).reduce(maxStep) {max($0,(limits[$1]-floor)/CGFloat(count-$1))}
            for i in 1...count {limits[i]=max(limits[i],limits[i-1]-landingSlope)}
        } else {
            for i in 1...count {limits[i]=max(limits[i],limits[i-1])}
            for i in (0..<count).reversed() {
                let n=Self.index(clock*Double(i)/Double(count),list)
                // Only the thrust can leave the floor. On the catch cels the
                // forepaw must stay planted until the drawing itself changes.
                if list[n].moving {limits[i]=max(limits[i],limits[i+1]-maxStep)}
            }
        }
        heights=limits
    }

    private static func index(_ time:Double,_ list:[Beat])->Int {
        (list.firstIndex(where:{$0.time>time}) ?? list.count)-1
    }
    private static func x(_ time:Double,_ j:Int,_ list:[Beat])->CGFloat {
        let a=list[j]
        guard a.moving,j+1<list.count else {return a.x}
        let b=list[j+1],f=clamp((time-a.time)/(b.time-a.time),0,1)
        return a.x+(b.x-a.x)*f
    }
    func frame(_ t:CGFloat)->Cel {beats[Self.index(clamp(t,0,1)*duration,beats)].cel}
    func position(_ t:CGFloat)->CGPoint {
        let fraction=clamp(t,0,1), time=fraction*duration
        let f=fraction*CGFloat(Self.samples),a=Int(f),b=min(a+1,Self.samples)
        return CGPoint(x:Self.x(time,Self.index(time,beats),beats),y:heights[a]+(heights[b]-heights[a])*(f-CGFloat(a)))
    }
}
