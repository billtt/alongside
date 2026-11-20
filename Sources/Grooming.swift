import Foundation

// Each stop is an authored drawing. The same neighboring drawings take the cat
// home if a touch, pickup or menu command interrupts a wash.
struct GroomingBout {
    enum Key: Int, CaseIterable {
        case rest, lift, wrist, lick, cheek, ear, sweep, lower, pause
        case chest, shoulder, flank, sit, raiseFoot, toes, retract
    }

    let sequence: Reaction

    init(art: PetArt, motions: MotionLibrary) {
        var random = SystemRandomNumberGenerator()
        self.init(art: art, motions: motions, using: &random)
    }

    init<R: RandomNumberGenerator>(art: PetArt, motions: MotionLibrary, using random: inout R) {
        let home = MotionFrame(art.cel("settle", 8))
        var current = home
        var beats = [(home, 0.18)]
        func move(to target: MotionFrame, taking time: Double, hold: Double = 0) {
            let route = motions.path(from: current, to: target).dropFirst()
            if !route.isEmpty {
                // Never compress a long recovery path into one or two display refreshes.
                let spacing = max(0.075, time / Double(route.count))
                for frame in route { beats.append((frame, spacing)) }
            }
            if hold > 0 { beats.append((target, hold)) }
            current = target
        }
        func visit(_ key: Key, taking time: Double, hold: Double = 0) {
            move(to: key == .rest ? home : MotionFrame(art.cel("grooming", key.rawValue - 1)), taking: time, hold: hold)
        }
        func lick(_ key: Key, recovery: Int, count: Int) {
            visit(key, taking: 0.38, hold: 0.08)
            let withdrawn = MotionFrame(art.cel("groomingRecovery", recovery))
            for i in 0..<count {
                // The paw and torso remain in the licking pose. Only the tongue
                // and a small neck motion cycle; don't replay the whole approach.
                move(to: withdrawn, taking: .random(in: 0.18...0.25, using: &random), hold: 0.10)
                if i + 1 < count {
                    visit(key, taking: .random(in: 0.16...0.23, using: &random), hold: 0.08)
                }
            }
        }
        func wetPaw(_ n: Int) { lick(.lick, recovery: 0, count: n) }
        func faceWash() {
            visit(.lift, taking: 0.44)
            visit(.wrist, taking: 0.39)
            for _ in 0..<Int.random(in: 2...3, using: &random) {
                wetPaw(.random(in: 2...4, using: &random))
                for _ in 0..<Int.random(in: 1...2, using: &random) {
                    visit(.cheek, taking: 0.26)
                    visit(.ear, taking: 0.30, hold: .random(in: 0.05...0.16, using: &random))
                    visit(.sweep, taking: 0.28)
                    visit(.lower, taking: 0.24)
                    visit(.wrist, taking: 0.23)
                }
            }
            wetPaw(.random(in: 2...4, using: &random))
            visit(.lower, taking: 0.24)
            visit(.pause, taking: 0.52, hold: .random(in: 0.5...1.3, using: &random))
        }
        func coat(_ turned: Bool) {
            if turned { visit(.shoulder, taking: 0.78) }
            lick(turned ? .flank : .chest, recovery: turned ? 2 : 1,
                 count: .random(in: 5...8, using: &random))
            visit(.pause, taking: 0.85, hold: .random(in: 0.5...1.5, using: &random))
        }
        func hindFoot() {
            visit(.sit, taking: 1.0, hold: 0.35)
            visit(.raiseFoot, taking: 0.76, hold: 0.26)
            lick(.toes, recovery: 3, count: .random(in: 6...10, using: &random))
            visit(.retract, taking: 0.35, hold: 0.18)
            visit(.raiseFoot, taking: 0.25)
            visit(.sit, taking: 0.85, hold: .random(in: 0.4...1.0, using: &random))
            visit(.pause, taking: 0.95, hold: 0.50)
        }

        faceWash()
        coat(false)
        if Bool.random(using: &random) {
            coat(true)
            hindFoot()
        } else {
            hindFoot()
            coat(true)
        }
        if Int.random(in: 0..<3, using: &random) == 0 { coat(false) }
        visit(.rest, taking: 0.64, hold: 0.22)
        sequence = Reaction(library: motions, timed: beats)
    }
}
