import Foundation

struct PointerInvitation {
    // Coordinates are relative to the middle of the eyes, in body lengths.
    let offset: CGPoint
    let dwell: Double
    let leadSpeed: Double
}

/// A visit to the face, a deliberate sideways lead, then a pause at the destination.
/// The caller resets the detector for mouse-down, screen changes and ineligible poses.
struct InvitationGesture {
    private struct Lead {
        let start: CGPoint
        let direction: CGFloat
        let dwell: Double
        var elapsed: Double
        var furthest: CGFloat
        var stopped = 0.0
    }

    private enum Phase {
        case waiting, byFace(CGPoint, Double), leading(Lead), spent
    }

    private var phase = Phase.waiting
    private var previous: CGPoint?

    mutating func observe(relative point: CGPoint, dt: Double) -> PointerInvitation? {
        guard dt > 0, dt <= 0.25, point.x.isFinite, point.y.isFinite else {
            self = Self()
            return nil
        }
        let last = previous ?? point
        previous = point
        let speed = hypot(point.x - last.x, point.y - last.y) / dt
        let nearFace = hypot(point.x, point.y) <= 0.46
        switch phase {
        case .waiting:
            if nearFace { phase = .byFace(point, 0) }
        case .spent:
            if !nearFace { phase = .waiting }
        case let .byFace(start, dwell):
            let dx = point.x - start.x, dy = point.y - start.y
            if nearFace && hypot(dx, dy) < 0.085 {
                phase = dwell + dt <= 3.0 ? .byFace(start, dwell + dt) : .spent
            } else if dwell < 0.42 {
                phase = nearFace ? .byFace(point, 0) : .waiting
            } else {
                let direction: CGFloat = dx >= 0 ? 1 : -1
                guard abs(dx) >= abs(dy) * 1.4, speed <= 3.2,
                      direction * start.x >= -0.14 else {
                    phase = .spent
                    return nil
                }
                phase = .leading(Lead(start: start, direction: direction, dwell: dwell,
                                      elapsed: dt, furthest: abs(dx)))
            }
        case .leading(var lead):
            let distance = (point.x - lead.start.x) * lead.direction
            lead.elapsed += dt
            guard lead.elapsed <= 6.5, speed <= 3.2, abs(point.x) <= 3.5,
                  abs(point.y - lead.start.y) <= 0.38,
                  distance >= lead.furthest - 0.12 else {
                phase = .spent
                return nil
            }
            lead.furthest = max(lead.furthest, distance)
            lead.stopped = speed < 0.18 ? lead.stopped + dt : 0
            if lead.stopped >= 0.22 {
                phase = .spent
                // The first 0.085 lengths belonged to the face dwell tolerance.
                let pace = (distance - 0.085) / max(dt, lead.elapsed - lead.stopped)
                guard distance >= 0.62, abs(point.x) >= 0.75, (0.25...1.85).contains(pace)
                else { return nil }
                return PointerInvitation(offset: point, dwell: lead.dwell, leadSpeed: pace)
            }
            phase = .leading(lead)
        }
        return nil
    }
}

/// Fitted on synthetic desktop invitations. Only the recognized gesture is scored.
struct InvitationModel: Decodable {
    private let schema: String
    private let features, intents: [String]
    private let weights: TanhNetwork

    static func loadIfPresent(root: URL) throws -> Self? {
        let folder = root.appendingPathComponent("Invitation", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        let url = folder.appendingPathComponent("base-v1.json")
        let model = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard model.schema == "desktop-invitation-v1",
              model.features == ["face_dwell", "lead_speed", "rest_drive", "disturbance"],
              model.intents == ["stay", "follow"], model.weights.matches(inputs: 4, hidden: 8, outputs: 2)
        else { throw ArtError.invalid("邀请模型结构或输入输出不兼容") }
        return model
    }

    fileprivate func logOdds(_ cue: PointerInvitation, restDrive: Double, disturbance: Double) -> Double {
        func unit(_ x: Double) -> Double { min(1, max(0, x)) }
        let input = [unit((cue.dwell - 0.42) / 1.5), unit((cue.leadSpeed - 0.25) / 1.6),
                     unit(restDrive), unit(disturbance)]
        let scores = weights.logits(input)
        return scores[1] - scores[0]
    }
}

final class InvitationPolicy {
    private let model: InvitationModel
    private let defaults: UserDefaults?
    private let key = "Dada.Invitation.profile.v1"
    private var follow = 0, stay = 0
    var feedbackCount: Int { follow + stay }

    init(model: InvitationModel, defaults: UserDefaults?) {
        self.model = model
        self.defaults = defaults
        if let saved = defaults?.dictionary(forKey: key),
           let follow = saved["follow"] as? Int, let stay = saved["stay"] as? Int,
           (0...1000).contains(follow), (0...1000).contains(stay) {
            self.follow = follow
            self.stay = stay
        }
    }

    func probability(_ cue: PointerInvitation, restDrive: Double, disturbance: Double,
                     familiarity: Int = 0) -> Double {
        let base = model.logOdds(cue, restDrive: restDrive, disturbance: disturbance)
        let preferenceOdds = min(4, max(0.25, Double(follow + 3) / Double(stay + 3)))
        // Familiarity is the existing count of spaced, gentle encounters. It is
        // read at decision time, independently of votes about following the pointer.
        let familiar = Double(min(12, max(0, familiarity))) / 12
        let calm = 1 - min(1, max(0, disturbance))
        let familiarLogOdds = log(1.5) * familiar * calm
        return 1 / (1 + exp(-(base + log(preferenceOdds) + familiarLogOdds)))
    }

    func accepts(_ cue: PointerInvitation, restDrive: Double, disturbance: Double,
                 familiarity: Int = 0, draw: Double) -> Bool {
        draw < probability(cue, restDrive: restDrive, disturbance: disturbance, familiarity: familiarity)
    }

    /// Only an explicit preference changes this profile. A completed walk is not feedback.
    func teach(follow wantsFollow: Bool) {
        if max(follow, stay) >= 1000 { follow /= 2; stay /= 2 }
        if wantsFollow { follow += 1 } else { stay += 1 }
        defaults?.set(["follow": follow, "stay": stay], forKey: key)
    }

    func reset() {
        follow = 0
        stay = 0
        defaults?.removeObject(forKey: key)
    }
}

func verifyInvitationPolicy(_ model: InvitationModel) throws {
    func require(_ ok: Bool, _ label: String) throws {
        guard ok else { throw ArtError.invalid("邀请 · " + label) }
    }
    // Timed screen-space gestures, including declined and partially completed visits.
    typealias Leg = (point: CGPoint, seconds: Double)
    func play(_ legs: [Leg], hz: Int = 30, resetBeforeLast: Bool = false) -> [PointerInvitation] {
        var detector = InvitationGesture(), events: [PointerInvitation] = []
        var start = legs[0].point
        for (index, leg) in legs.enumerated() {
            if resetBeforeLast && index == legs.count - 1 { detector = InvitationGesture() }
            let ticks = max(1, Int((leg.seconds * Double(hz)).rounded()))
            for tick in 1...ticks {
                let t = Double(tick) / Double(ticks)
                let p = CGPoint(x: start.x + (leg.point.x - start.x) * t,
                                y: start.y + (leg.point.y - start.y) * t)
                if let cue = detector.observe(relative: p, dt: leg.seconds / Double(ticks)) {
                    events.append(cue)
                }
            }
            start = leg.point
        }
        return events
    }
    func path(side: CGFloat = 1, near: CGFloat = 0.22, destination: CGFloat = 1.6,
              dwell: Double = 0.65, pace: Double = 0.85, height: CGFloat = 0.14,
              stop: Double = 0.4) -> [Leg] {
        let start = CGPoint(x: side * near, y: 0.14), end = CGPoint(x: side * destination, y: height)
        return [(start, dwell), (end, abs(destination - near) / pace), (end, stop)]
    }
    let exampleEvents = play(path())
    try require(exampleEvents.count == 1, "完整邀请只触发一次")
    let example = exampleEvents[0]
    for hz in [15, 30, 60] {
        for side: CGFloat in [-1, 1] {
            for destination: CGFloat in [1.12, 2.45] {
                let cues = play(path(side: side, destination: destination, stop: 3), hz: hz)
                try require(cues.count == 1 && abs(cues[0].offset.x - destination * side) < 0.01,
                            "不同采样率、远近及两侧的实际落点")
            }
        }
    }
    let reversal: [Leg] = [(CGPoint(x: 0.22, y: 0.14), 0.65), (CGPoint(x: 1.3, y: 0.14), 1.2),
                           (CGPoint(x: 0.9, y: 0.14), 0.5), (CGPoint(x: 0.9, y: 0.14), 0.4)]
    for track in [path(near: 1.15), path(dwell: 0.1), path(dwell: 4), path(pace: 5),
                  path(height: 1), path(stop: 0.1), path(destination: 0.49), path(destination: -1.5), reversal] {
        try require(play(track).isEmpty, "路过、反向、远处或未完成的手势")
    }
    try require(play(path(), resetBeforeLast: true).isEmpty, "中断后丢弃部分手势")

    let suite = "Alongside.Invitation.Check." + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: suite) else { throw ArtError.invalid("邀请偏好检查") }
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = InvitationPolicy(model: model, defaults: defaults)
    func probability(_ profile: InvitationPolicy, disturbance: Double = 0) -> Double {
        profile.probability(example, restDrive: 0.87, disturbance: disturbance)
    }
    let neutral = probability(policy)
    func familiarityOddsRatio(_ encounters: Int, disturbance: Double) -> Double {
        let before = probability(policy, disturbance: disturbance)
        let after = policy.probability(example, restDrive: 0.87,
                                       disturbance: disturbance, familiarity: encounters)
        return (after / (1 - after)) / (before / (1 - before))
    }
    try require(abs(familiarityOddsRatio(20, disturbance: 0) - 1.5) < 1e-10 &&
                abs(familiarityOddsRatio(6, disturbance: 0) - sqrt(1.5)) < 1e-10 &&
                abs(familiarityOddsRatio(12, disturbance: 0.5) - sqrt(1.5)) < 1e-10 &&
                abs(familiarityOddsRatio(12, disturbance: 1) - 1) < 1e-10 &&
                policy.feedbackCount == 0, "熟悉度在安静时小幅提高赔率，打扰时衰减")
    try require((0.4...0.9).contains(neutral) && probability(policy, disturbance: 0.8) < neutral,
                "静卧时可能响应，打扰后更少")
    try require(policy.accepts(example, restDrive: 0.87, disturbance: 0, draw: 0) &&
                !policy.accepts(example, restDrive: 0.87, disturbance: 0, draw: 1) &&
                policy.feedbackCount == 0, "接受和略过都不自动记作偏好")
    policy.teach(follow: true)
    let reloaded = InvitationPolicy(model: model, defaults: defaults)
    try require(reloaded.feedbackCount == 1 && probability(reloaded) > neutral, "保存独立偏好")
    reloaded.teach(follow: false)
    reloaded.teach(follow: false)
    try require(probability(reloaded) < neutral, "可以偏爱留在原处")
    reloaded.reset()
    try require(probability(InvitationPolicy(model: model, defaults: defaults)) == neutral, "只清除邀请偏好")
}
