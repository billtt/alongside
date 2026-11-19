import Foundation

// Measured from the composited paws and tail, once at authoring time. Each
// entry gives the lowest opaque pixel at or to the right of a source column.
struct DockProfile: Codable {
    let scale,anchor:CGFloat
    let depths:[Int16]
    init(_ cel:Cel) {
        scale=cel.scale;anchor=cel.anchorX
        depths=cel.trailingClearance.map{$0.isFinite ? Int16($0):-1}
    }
    func support(at offset:CGFloat,unit:CGFloat,top:CGFloat)->CGFloat {
        let k=unit*scale
        let column=max(0,Int(floor(anchor+offset/k))-2)
        guard column<depths.count,depths[column]>=0 else {return -.infinity}
        return top-max(0,CGFloat(depths[column])-1)*k
    }
}

/// A low step can put the front paws below the Dock while the hind paws still stand on it.
struct DockMotion {
    let hop:Hop
    let duration:Double
    private let drawings:[Cel]
    private let ends:[CGFloat]
    private let heights:[CGFloat]
    static let samples=120
    static let substeps=4
    static let descentEnds:[CGFloat]=[0.045,0.11,0.18,0.26,0.33,0.40,0.47,0.54,0.61,0.70,0.79,0.87,0.95,1]

    static func measureDescent(_ art:PetArt)->[DockProfile] {
        let walk=art.cel("walk",0),keys=[walk]+art.clips["stepDown"]!+[walk]
        let count=samples*substeps
        return (0...count).map {i in autoreleasepool {
            DockProfile(sample(CGFloat(i)/CGFloat(count),keys,descentEnds))
        }}
    }

    init(hop:Hop, edge:CGFloat, unit:CGFloat, art:PetArt) {
        self.hop=hop
        let stride=art.cel("walk",0)
        if hop.descending {
            drawings=[stride]+art.clips["stepDown"]!+[stride]
            ends=Self.descentEnds
            duration=1.27
        } else {
            let up=art.clips["hopUp"]!
            drawings=[stride]+Array(up[0...3])+[art.cel("leap",1)]+Array(up[4...7])+[stride]
            ends=[0.045,0.11,0.17,0.235,0.34,0.48,0.56,0.66,0.77,0.90,1]
            duration=1.15
        }
        guard hop.descending else {heights=[];return}
        let count=Self.samples
        // Check the entire interval between samples, including both drawings at a cel change.
        // A cat facing left has its trailing paws on the right of the original drawing.
        let sign:CGFloat=hop.endX<hop.startX ? 1:-1
        var floors=[CGFloat](repeating:hop.endY,count:count+1)
        for i in 0..<count {
            let t=CGFloat(i)/CGFloat(count)
            let p=hop.position(t)
            var limit=hop.endY
            for profile in art.descentProfiles[(i*Self.substeps)...((i+1)*Self.substeps)] {
                limit=max(limit,profile.support(at:(edge-p.x)*sign,unit:unit,top:hop.startY))
            }
            floors[i]=max(floors[i],limit,p.y)
            floors[i+1]=max(floors[i+1],limit)
        }
        // Never lift back up at a change of paw, or drop a whole Dock height in one tick.
        for i in (0..<count).reversed() {floors[i]=max(floors[i],floors[i+1])}
        let maxDrop=(hop.startY-hop.endY)*4.4/CGFloat(count)
        for i in 1...count {floors[i]=max(floors[i],floors[i-1]-maxDrop)}
        heights=floors
    }

    private static func index(_ t:CGFloat, _ ends:[CGFloat])->Int {
        ends.firstIndex(where:{t < $0}) ?? ends.count-1
    }
    func frame(_ t:CGFloat)->Cel {drawings[Self.index(t,ends)]}
    func sample(_ t:CGFloat)->Cel {
        Self.sample(t,drawings,ends)
    }
    private static func sample(_ t:CGFloat,_ keys:[Cel],_ ends:[CGFloat])->Cel {
        let i=index(t,ends),start=i==0 ? 0:ends[i-1]
        guard i+1<keys.count else {return keys[i]}
        return keys[i].toward(keys[i+1],clamp((t-start)/(ends[i]-start),0,1))
    }
    func position(_ t:CGFloat)->CGPoint {
        let p=hop.position(t)
        guard hop.descending else {return p}
        let f=clamp(t,0,1)*CGFloat(Self.samples)
        let a=Int(f), b=min(a+1,Self.samples)
        return CGPoint(x:p.x,y:heights[a]+(heights[b]-heights[a])*(f-CGFloat(a)))
    }
}
