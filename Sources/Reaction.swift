import Foundation

struct MotionFrame: Hashable {
    let cel: Cel
    let mirrored: Bool

    init(_ cel: Cel, _ mirrored: Bool = false) {
        self.cel = cel
        self.mirrored = mirrored
    }
    init(_ current: (Cel, Bool)) { self.init(current.0, current.1) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.cel === rhs.cel && lhs.mirrored == rhs.mirrored }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(cel)); hasher.combine(mirrored) }
}

final class MotionLibrary {
    private var adjacent: [MotionFrame: [MotionFrame]] = [:]

    private var plantSteps:[MotionFrame:[MotionFrame:CGFloat]]=[:]
    func step(from a:MotionFrame,to b:MotionFrame)->CGFloat {plantSteps[a]?[b] ?? 0}

    init(_ art: PetArt) {
        for flip in [false, true] {
            func connect(_ cels: [Cel], turning: Bool = false, paws:[[CGFloat]]?=nil) {
                let frames = cels.enumerated().map { i, cel in
                    MotionFrame(cel, turning && i == cels.count - 1 ? !flip : flip)
                }
                for (i,pair) in zip(frames,frames.dropFirst()).enumerated() {
                    let (a,b)=pair
                    if let toes=paws?[i] {
                        func foot(_ f:MotionFrame,_ u:CGFloat)->CGFloat {
                            (u*CGFloat(f.cel.image.width)-f.cel.anchorX)*f.cel.scale*(f.mirrored ? -1:1)
                        }
                        let dx=foot(a,toes[0])-foot(b,toes[1])
                        plantSteps[a,default:[:]][b]=dx
                        plantSteps[b,default:[:]][a] = -dx
                    }
                    adjacent[a, default: []].append(b)
                    adjacent[b, default: []].append(a)
                }
            }
            for track in art.transitions { connect(track.frames, turning: track.turnsAround,paws: track.paws) }
            for key in ["settle", "walk", "side", "loaf"] { connect(art.clips[key]!) }
            connect([art.cel("walk",5),art.cel("walk",0)])
            connect(art.clips["release"]!+[art.cel("hopUp",7),art.cel("walk",0)])
        }
    }

    // Walk along authored neighboring drawings, including from a partially completed gesture.
    func path(from start: MotionFrame, to end: MotionFrame) -> [MotionFrame] {
        if start == end { return [start] }
        var queue = [start], previous = [start: start], next = 0
        while next < queue.count && previous[end] == nil {
            let frame = queue[next]
            next += 1
            for neighbor in adjacent[frame] ?? [] where previous[neighbor] == nil {
                previous[neighbor] = frame
                queue.append(neighbor)
            }
        }
        guard previous[end] != nil else { return [start, end] }
        var route = [end], cursor = end
        while cursor != start {
            cursor = previous[cursor]!
            route.append(cursor)
        }
        return route.reversed()
    }


}

struct Reaction {
    private struct Beat {
        let frame: MotionFrame
        let end: Double
        let travel:CGFloat
    }
    private var beats: [Beat] = []
    private(set) var peakTime:Double=0
    var duration: Double { beats.last!.end }

    private mutating func append(_ frame:MotionFrame,for seconds:Double,library:MotionLibrary) {
        let last=beats.last
        let travel=last.map {$0.travel+library.step(from:$0.frame,to:frame)} ?? 0
        beats.append(Beat(frame:frame,end:(last?.end ?? 0)+seconds,travel:travel))
    }

    private func beat(at time: Double) -> Beat {
        var low = 0, high = beats.count - 1
        while low < high {
            let mid = (low + high) / 2
            if time < beats[mid].end { high = mid } else { low = mid + 1 }
        }
        return beats[low]
    }

    func travel(at time:Double)->CGFloat {beat(at:time).travel}

    init(library: MotionLibrary, timed: [(MotionFrame, Double)]) {
        for (frame, seconds) in timed { append(frame, for: seconds, library: library) }
    }

    init(library:MotionLibrary,path: [MotionFrame], maximumFrameTime: Double = .infinity) {
        for frame in path {
            append(frame,for:min(frame.cel.seconds ?? 0.145, maximumFrameTime),library:library)
        }
    }

    init(library: MotionLibrary, from initial: MotionFrame, toward peak: MotionFrame,
         returningTo home: MotionFrame, hold: Double, frameTime: Double = 0.105, awakeAfter:(MotionFrame,Double)?=nil) {
        for frame in library.path(from:initial,to:peak).dropLast() {append(frame,for:frameTime,library:library)}
        peakTime=beats.last?.end ?? 0
        append(peak,for:hold,library:library)
        if let (awake,seconds)=awakeAfter {
            for frame in library.path(from:peak,to:awake).dropFirst().dropLast() {append(frame,for:frameTime,library:library)}
            append(awake,for:seconds,library:library)
        }
        for frame in library.path(from:awakeAfter?.0 ?? peak,to:home).dropFirst() {append(frame,for:frameTime,library:library)}
    }

    func frame(at elapsed: Double) -> (Cel, Bool) {
        let frame = beat(at: elapsed).frame
        return (frame.cel,frame.mirrored)
    }
}
