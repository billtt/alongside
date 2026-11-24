import Foundation

/// A walk ending on a reachable painted footfall. Distances and speeds use the
/// same body units as WalkCycle. The caller applies direction and display scale.
struct ApproachGait {
    let plannedDistance: CGFloat
    private(set) var distance: CGFloat = 0
    private(set) var frameIndex: Int
    private(set) var isFinished: Bool

    private let cycle: WalkCycle
    private let start: Int, end: Int
    private let nominalLength: CGFloat, rampLength: CGFloat
    private var drive: CGFloat = 0, smoothedSpeed: CGFloat = 0

    /// Use endingAt when the following transition must start on a specific cel.
    /// If there is no such footfall in range, stay on the starting cel.
    init(cycle: WalkCycle, maximumDistance: CGFloat, startingAt: Int = 0, endingAt: Int? = nil) {
        self.cycle = cycle
        let count = cycle.distances.count
        precondition(cycle.length > 0 && cycle.distances.indices.contains(startingAt))
        if let endingAt { precondition(cycle.distances.indices.contains(endingAt)) }
        start = startingAt
        frameIndex = startingAt
        let budget = maximumDistance.isFinite ? max(0, maximumDistance) : 0
        let maxTurns = floor(budget / cycle.length)
        var farthest: CGFloat = 0, clockLength: CGFloat = 0
        var prefix: CGFloat = 0, index = start, lastCel = start
        // Each cel's reachable positions are its first offset plus whole cycles.
        for beat in cycle.distances.indices {
            if endingAt == nil || endingAt == index {
                let turns = maxTurns * cycle.length + prefix <= budget ? maxTurns : maxTurns - 1
                let candidate = turns * cycle.length + prefix
                if turns >= 0 && candidate > farthest {
                    farthest = candidate
                    lastCel = index
                    clockLength = turns * cycle.length + CGFloat(beat) * cycle.length / CGFloat(count)
                }
            }
            prefix += cycle.distances[index]
            index = (index + 1) % count
        }
        plannedDistance = farthest
        end = lastCel
        // Keep the original cadence of the six walk drawings. Their individual
        // contact displacements can differ substantially.
        nominalLength = clockLength
        rampLength = min(nominalLength, cycle.length * 0.42)
        isFinished = nominalLength == 0
    }

    /// Advance the clock at the commanded pace. All visible translation occurs
    /// on the same frame boundary as its measured change of supporting paw.
    @discardableResult mutating func advance(_ dt: Double, speed: CGFloat) -> CGFloat {
        guard !isFinished, dt > 0, dt.isFinite, speed.isFinite else { return 0 }
        let command = max(0, speed)
        let tau = 0.12
        let blend = -expm1(-dt / tau)
        // Exact integral of a first-order response during this tick. Changing
        // speed never re-evaluates time already spent at an earlier pace.
        let delta = command * dt + (smoothedSpeed - command) * tau * blend
        smoothedSpeed += (command - smoothedSpeed) * blend
        drive += max(0, delta)
        let previous = distance
        let finish = nominalLength + rampLength
        if drive >= finish {
            distance = plannedDistance
            frameIndex = end
            isFinished = true
        } else {
            // Parabolic shoulders meet the constant-cadence section with
            // continuous velocity and ease to zero at the destination.
            let phaseDistance: CGFloat
            if drive < rampLength {
                phaseDistance = drive * drive / (2 * rampLength)
            } else if drive > nominalLength {
                let left = finish - drive
                phaseDistance = nominalLength - left * left / (2 * rampLength)
            } else {
                phaseDistance = drive - rampLength / 2
            }
            let contact = cycle.sample(time: phaseDistance, speed: 1, startingAt: start)
            distance = min(contact.distance, plannedDistance)
            frameIndex = contact.index
        }
        return distance - previous
    }
}

func verifyApproachGait(_ art: PetArt) throws {
    let cycle = art.gait
    func require(_ ok: Bool, _ label: String) throws {
        guard ok else { throw ArtError.invalid("主动靠近步态 · " + label) }
    }
    let library = MotionLibrary(art)
    let prone = MotionFrame(art.cel("settle", 8))
    for mirrored in [false, true] {
        let frames = art.clips["walk"]!.map { MotionFrame($0, mirrored) }
        let sign: CGFloat = mirrored ? 1 : -1
        for i in frames.indices {
            let a = frames[i], b = frames[(i + 1) % frames.count]
            let step = sign * cycle.distances[i]
            try require(abs(library.step(from: a, to: b) - step) < 1e-8 &&
                        abs(library.step(from: b, to: a) + step) < 1e-8, "中断收步正反播放保持同一支撑爪")
            // Follow the real route home from each possible interruption.
            let sequence = Reaction(library: library, path: library.path(from: a, to: prone))
            var time = 0.0
            let beats = sequence.timedFrames
            for (before, after) in zip(beats, beats.dropFirst()) {
                guard let old = frames.firstIndex(of: before.frame),
                      let new = frames.firstIndex(of: after.frame) else { break }
                let expected = new == (old + 1) % frames.count ? cycle.distances[old] : -cycle.distances[new]
                let oldPosition = sequence.travel(at: time + before.seconds / 2)
                time += before.seconds
                let newPosition = sequence.travel(at: time + after.seconds / 2)
                try require(abs(newPosition - oldPosition - sign * expected) < 1e-8, "中途收步沿当前绘稿逐帧接地")
            }
        }
    }
    for start in cycle.distances.indices {
        let first = cycle.distances[start]
        let next = cycle.distances[(start + 1) % cycle.distances.count]
        var near = ApproachGait(cycle: cycle, maximumDistance: first * 0.9, startingAt: start)
        try require(near.isFinished && near.advance(1, speed: cycle.speed) == 0 &&
                    near.frameIndex == start, "一步以内留在原落点")
        let single = ApproachGait(cycle: cycle, maximumDistance: first + next * 0.25, startingAt: start)
        try require(single.plannedDistance == first, "只选择目标之前的完整落点")
    }
    for n in 1...3 {
        let limit = CGFloat(n) * cycle.length
        var exact = ApproachGait(cycle: cycle, maximumDistance: limit, endingAt: 0)
        let short = ApproachGait(cycle: cycle, maximumDistance: limit.nextDown, endingAt: 0)
        let extra = ApproachGait(cycle: cycle, maximumDistance: limit + 0.35 * cycle.length, endingAt: 0)
        try require(exact.plannedDistance == limit && extra.plannedDistance == limit &&
                    short.plannedDistance == CGFloat(n-1) * cycle.length, "整圈边界两侧选择可收势的脚点")
        for _ in 0..<1000 where !exact.isFinished { exact.advance(1/60.0, speed: cycle.speed) }
        try require(exact.isFinished && exact.frameIndex == 0 && exact.distance == limit, "最后一拍能直接接坐姿")
    }

    // Compare at matched wall-clock times under two different refresh patterns,
    // including a pause mid-route. Positive and mirrored walks share contacts.
    let goal = cycle.length * 2.66
    let schedule = [(0.57, 0.8), (0.73, 1.18), (0.64, 0.0), (0.64, 0.52), (5.0, 1.0)]
    func run(_ ticks: [Double], sign: CGFloat) throws -> [CGFloat] {
        var walk = ApproachGait(cycle: cycle, maximumDistance: goal, startingAt: 3)
        var checkpoints: [CGFloat] = [], tick = 0, position: CGFloat = 0
        for (hold, factor) in schedule {
            var remaining = hold
            while remaining > 1e-12 {
                let dt = min(remaining, ticks[tick % ticks.count])
                let previous = walk.frameIndex
                let moved = walk.advance(dt, speed: cycle.speed * factor)
                position += sign * moved
                if walk.frameIndex == previous {
                    try require(moved == 0, "同一绘稿保持支撑爪静止")
                } else {
                    try require(walk.frameIndex == (previous + 1) % cycle.distances.count &&
                                abs(moved - cycle.distances[previous]) < 1e-8, "换步严格使用原画接触距离")
                }
                try require(moved >= 0 && abs(position) <= goal, "接近目标时不倒退也不越界")
                remaining -= dt
                tick += 1
            }
            checkpoints.append(sign * position)
        }
        let final = walk.frameIndex
        try require(walk.isFinished && walk.distance == walk.plannedDistance &&
                    goal - walk.distance < cycle.distances[final], "停在最近的可达脚点")
        try require(walk.advance(12, speed: cycle.speed) == 0 && walk.frameIndex == final,
                    "停住后保持原脚点")
        return checkpoints
    }
    let left = try run([1/60.0], sign: -1)
    let right = try run([0.011, 0.043, 0.026, 0.039], sign: 1)
    try require(zip(left, right).allSatisfy { abs($0 - $1) < 1e-8 }, "中途变速与帧率抖动无关")
}
