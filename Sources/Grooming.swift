import Foundation

// Each stop is an authored drawing. The same neighboring drawings take the cat
// home if a touch, pickup or menu command interrupts a wash.
struct GroomingBout {
    enum Key: Int, CaseIterable {
        case rest, lift, wrist, lick, cheek, ear, sweep, lower, pause
        case chest, shoulder, flank, sit, raiseFoot, toes, retract
    }

    let sequence: Reaction
    let sites: [GroomingSite]

    init(art: PetArt, motions: MotionLibrary, showcase: Bool = true) {
        var random = SystemRandomNumberGenerator()
        self.init(art: art, motions: motions, showcase: showcase, using: &random)
    }

    init<R: RandomNumberGenerator>(art: PetArt, motions: MotionLibrary, showcase: Bool = true, using random: inout R) {
        let home = MotionFrame(art.cel("settle", 8))
        var current = home
        var beats = [(home, 0.18)]
        var elapsed = 0.18
        func move(to target: MotionFrame, taking time: Double, hold: Double = 0) {
            let route = motions.path(from: current, to: target).dropFirst()
            if !route.isEmpty {
                // Never compress a long recovery path into one or two display refreshes.
                let spacing = max(0.075, time / Double(route.count))
                for frame in route { beats.append((frame, spacing)) }
                elapsed += Double(route.count) * spacing
            }
            if hold > 0 { beats.append((target, hold)); elapsed += hold }
            current = target
        }
        func visit(_ key: Key, taking time: Double, hold: Double = 0) {
            move(to: key == .rest ? home : MotionFrame(art.cel("grooming", key.rawValue - 1)), taking: time, hold: hold)
        }
        func lick(_ key: Key, recovery: Int, count: Int) {
            visit(key, taking: 0.38, hold: 0.08)
            let withdrawn = MotionFrame(art.cel("groomingRecovery", recovery))
            for i in 0..<count {
                // Recover through the neighboring drawings with the support paw
                // still planted. Only entry and exit traverse the entire lift.
                move(to: withdrawn, taking: .random(in: 0.26...0.34, using: &random), hold: 0.11)
                if i + 1 < count {
                    visit(key, taking: .random(in: 0.21...0.28, using: &random), hold: 0.09)
                }
            }
        }

        func enter(_ site: GroomingSite) {
            switch site {
            case .face:
                visit(.lift, taking: 0.44)
                visit(.wrist, taking: 0.39)
            case .chest: break
            case .shoulder:
                visit(.shoulder, taking: 0.78)
            case .foot:
                visit(.sit, taking: 1.0, hold: 0.35)
                visit(.raiseFoot, taking: 0.76, hold: 0.26)
            }
        }
        func wash(_ site: GroomingSite) {
            let strokes = Int.random(in: 2...4, using: &random)
            switch site {
            case .face:
                lick(.lick, recovery: 0, count: strokes)
                for _ in 0..<Int.random(in: 1...2, using: &random) {
                    visit(.cheek, taking: 0.26)
                    visit(.ear, taking: 0.30, hold: .random(in: 0.06...0.16, using: &random))
                    visit(.sweep, taking: 0.28)
                    visit(.lower, taking: 0.24)
                    visit(.wrist, taking: 0.23)
                }
            case .chest: lick(.chest, recovery: 1, count: strokes)
            case .shoulder: lick(.flank, recovery: 2, count: strokes)
            case .foot: lick(.toes, recovery: 3, count: strokes)
            }
        }
        func leave(_ site: GroomingSite) {
            if site == .face { visit(.lower, taking: 0.24) }
            if site == .foot {
                visit(.retract, taking: 0.35, hold: 0.18)
                visit(.raiseFoot, taking: 0.25)
                visit(.sit, taking: 0.85, hold: .random(in: 0.4...0.9, using: &random))
            }
            visit(.pause, taking: 0.85, hold: .random(in: 0.45...1.15, using: &random))
        }

        var history: [GroomingSite] = []
        func choose(_ allowed: [GroomingSite]) -> GroomingSite {
            guard let model = art.groomingModel else { return allowed.randomElement(using: &random)! }
            return model.choose(after: history, allowed: allowed, draw: .random(in: 0..<1, using: &random))
        }

        var site = showcase ? GroomingSite.face : choose(GroomingSite.allCases)
        enter(site)
        var lastAge = 1
        while true {
            wash(site)
            history.append(site)
            let remaining = GroomingSite.allCases.filter { !history.contains($0) }
            // The menu demonstrates every available body region. During a
            // spontaneous wash the observed feline duration model can end the
            // bout at any completed packet. Eight packets bound desktop time.
            if showcase {
                if remaining.isEmpty { break }
            } else {
                let age = max(lastAge, Int(elapsed))
                let survival = art.behaviorModel?.survival(of: .groom, from: lastAge, through: age) ?? 0.75
                if history.count >= 8 || Double.random(in: 0..<1, using: &random) >= survival { break }
                lastAge = age
            }
            let next = choose(showcase ? remaining : GroomingSite.allCases)
            if next != site {
                leave(site)
                enter(next)
            }
            site = next
        }
        leave(site)
        sites = history
        visit(.rest, taking: 0.64, hold: 0.22)
        sequence = Reaction(library: motions, timed: beats)
    }
}
