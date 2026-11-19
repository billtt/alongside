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
        let home = MotionFrame(art.cel("settle", 8))
        var current = home
        var beats = [(home, 0.18)]
        func visit(_ key: Key, taking time: Double, hold: Double = 0) {
            let target = key == .rest ? home : MotionFrame(art.cel("grooming", key.rawValue - 1))
            let route = motions.path(from: current, to: target).dropFirst()
            if !route.isEmpty {
                let spacing = time / Double(route.count)
                for frame in route { beats.append((frame, spacing)) }
            }
            if hold > 0 { beats.append((target, hold)) }
            current = target
        }
        func wetPaw(_ n: Int) {
            for _ in 0..<n {
                visit(.lick, taking: .random(in: 0.17...0.27))
                visit(.wrist, taking: .random(in: 0.18...0.34))
            }
        }
        func faceWash() {
            visit(.lift, taking: 0.44)
            visit(.wrist, taking: 0.39)
            for _ in 0..<Int.random(in: 3...5) {
                wetPaw(.random(in: 2...5))
                for _ in 0..<Int.random(in: 1...3) {
                    visit(.cheek, taking: 0.26)
                    visit(.ear, taking: 0.30, hold: .random(in: 0.05...0.16))
                    visit(.sweep, taking: 0.28)
                    visit(.lower, taking: 0.24)
                    visit(.wrist, taking: 0.23)
                }
            }
            wetPaw(.random(in: 2...5))
            visit(.lower, taking: 0.24)
            visit(.pause, taking: 0.52, hold: .random(in: 0.5...1.3))
        }
        func coat(_ turned: Bool) {
            if turned { visit(.shoulder, taking: 0.78) }
            for _ in 0..<Int.random(in: 5...11) {
                visit(turned ? .flank : .chest, taking: .random(in: 0.24...0.39))
                visit(turned ? .shoulder : .pause, taking: .random(in: 0.23...0.40))
            }
            visit(.pause, taking: 0.72, hold: .random(in: 0.5...1.5))
        }
        func hindFoot() {
            visit(.sit, taking: 1.0, hold: 0.35)
            visit(.raiseFoot, taking: 0.76, hold: 0.26)
            for _ in 0..<Int.random(in: 6...13) {
                visit(.toes, taking: .random(in: 0.21...0.32))
                visit(.retract, taking: .random(in: 0.18...0.31))
                visit(.raiseFoot, taking: 0.14)
            }
            visit(.sit, taking: 0.75, hold: .random(in: 0.4...1.0))
            visit(.pause, taking: 0.95, hold: 0.50)
        }

        faceWash()
        coat(false)
        if Bool.random() {
            coat(true)
            hindFoot()
        } else {
            hindFoot()
            coat(true)
        }
        if Int.random(in: 0..<3) == 0 { coat(false) }
        visit(.rest, taking: 0.64, hold: 0.22)
        sequence = Reaction(library: motions, timed: beats)
    }
}
