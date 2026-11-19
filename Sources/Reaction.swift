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

    init(_ art: PetArt) {
        for flip in [false, true] {
            func connect(_ cels: [Cel], turning: Bool = false) {
                let frames = cels.enumerated().map { i, cel in
                    MotionFrame(cel, turning && i == cels.count - 1 ? !flip : flip)
                }
                for (a,b) in zip(frames,frames.dropFirst()) {
                    adjacent[a, default: []].append(b)
                    adjacent[b, default: []].append(a)
                }
            }
            for track in art.transitions { connect(track.frames, turning: track.turnsAround) }
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
    }
    private var beats: [Beat] = []
    private(set) var peakTime:Double=0
    var duration: Double { beats.last!.end }

    init(path: [MotionFrame], maximumFrameTime: Double = .infinity) {
        var time=0.0
        for frame in path {
            time += min(frame.cel.seconds ?? 0.145, maximumFrameTime)
            beats.append(Beat(frame:frame,end:time))
        }
    }

    init(library: MotionLibrary, from initial: MotionFrame, toward peak: MotionFrame,
         returningTo home: MotionFrame, hold: Double, frameTime: Double = 0.105) {
        var elapsed=0.0
        func append(_ frame:MotionFrame,_ seconds:Double) {
            elapsed += seconds
            beats.append(Beat(frame:frame,end:elapsed))
        }
        for frame in library.path(from:initial,to:peak).dropLast() {append(frame,frameTime)}
        peakTime=elapsed
        append(peak,hold)
        for frame in library.path(from:peak,to:home).dropFirst() {append(frame,frameTime)}
    }

    func frame(at elapsed: Double) -> (Cel, Bool) {
        let frame = (beats.first { elapsed < $0.end } ?? beats.last!).frame
        return (frame.cel,frame.mirrored)
    }
}
