import Foundation

/// Each pair identifies the same planted paw in two successive left-facing drawings.
struct WalkCycle {
    let distances: [CGFloat]
    let length, speed: CGFloat

    init(frames: [Cel], contacts: [[CGFloat]]?,speed:CGFloat) throws {
        guard speed>0 else {throw ArtError.invalid("行走速度")}
        self.speed=speed
        guard let contacts else {
            distances=Array(repeating:speed*0.19,count:frames.count)
            length=distances.reduce(0,+)
            return
        }
        guard contacts.count == frames.count else {throw ArtError.invalid("行走支撑点")}
        distances = try contacts.enumerated().map { i, pair in
            let a=frames[i], b=frames[(i+1)%frames.count]
            guard pair.count==2 else {throw ArtError.invalid("行走支撑爪")}
            let step=(pair[1]-b.anchorX)*b.scale - (pair[0]-a.anchorX)*a.scale
            guard step>0 else {throw ArtError.invalid("行走步幅")}
            return step
        }
        length=distances.reduce(0,+)
    }

    func sample(time:Double,speed:CGFloat,startingAt start:Int=0)->(index:Int,distance:CGFloat) {
        let beats=time*speed/length*CGFloat(distances.count)
        let ticks=Int(floor(beats+1e-9)), remainder=ticks%distances.count
        var distance=CGFloat(ticks/distances.count)*length
        for i in 0..<remainder {distance+=distances[(start+i)%distances.count]}
        return ((start+remainder)%distances.count,distance)
    }
}
