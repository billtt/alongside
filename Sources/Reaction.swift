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
    private let art: PetArt

    init(_ art: PetArt) {
        self.art = art
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

    func target(action: String, offset: CGPoint, unit: CGFloat, from initial: MotionFrame, resting: Bool) -> MotionFrame {
        let side = art.cel(action,1)
        let restingFrames = art.clips[action + "Rest"] ?? []
        let useRestingFrames = resting && !restingFrames.isEmpty
        let options = useRestingFrames ? restingFrames : (art.clips[action + "Aim"] ?? []) + [side]
        let orientations = resting ? [initial.mirrored] : [false, true]
        var winner = MotionFrame(options[0],initial.mirrored), best = CGFloat.infinity
        for cel in options {
            guard let tip = cel.contact else { continue }
            let k = unit * cel.scale
            for flip in orientations {
                let x = (tip.x-cel.anchorX)*k*(flip ? -1:1)
                let distance = hypot(x-offset.x, tip.y*k-offset.y)
                let score = distance + (flip != initial.mirrored ? 0.045*unit:0)
                if score < best {
                    winner = MotionFrame(cel,flip)
                    best = score
                }
            }
        }
        return winner
    }
}

struct Reaction {
    private struct Beat {
        let frame: MotionFrame
        let end: Double
    }
    private var beats: [Beat] = []
    var duration: Double { beats.last!.end }

    init(path: [MotionFrame]) {
        var time=0.0
        for frame in path {
            time += frame.cel.seconds ?? 0.145
            beats.append(Beat(frame:frame,end:time))
        }
    }

    init(library: MotionLibrary, from initial: MotionFrame, toward peak: MotionFrame,
         returningTo home: MotionFrame, action: Pose, hold: Double? = nil) {
        let approach = library.path(from:initial,to:peak)
        let recovery = library.path(from:peak,to:home)
        // The paw hesitates before reaching. The swat accelerates into contact.
        let forward: [Double]
        let contactTime: Double
        switch action {
        case .swat: forward = [0.12,0.085,0.060,0.045]; contactTime = 0.105
        case .nip: forward = [0.105,0.095,0.070,0.060]; contactTime = 0.14
        case .paw: forward = [0.13,0.12,0.10,0.085]; contactTime = 0.20
        default: forward = [0.10,0.105,0.115,0.13]; contactTime = 1.7
        }
        func append(_ frame: MotionFrame, _ seconds: Double) {
            beats.append(Beat(frame:frame,end:(beats.last?.end ?? 0)+max(seconds,frame.cel.seconds ?? 0)))
        }
        for (i,frame) in approach.dropLast().enumerated() {
            let remaining = approach.count-1-i
            append(frame,remaining > forward.count ? 0.075 : forward[forward.count-remaining])
        }
        append(peak,hold ?? contactTime)
        let release = [0.075,0.095,0.115,0.14]
        for (i,frame) in recovery.dropFirst().enumerated() {
            append(frame,i < release.count ? release[i] : 0.08)
        }
    }

    func frame(at elapsed: Double) -> (Cel, Bool) {
        let frame = (beats.first { elapsed < $0.end } ?? beats.last!).frame
        return (frame.cel,frame.mirrored)
    }
}
