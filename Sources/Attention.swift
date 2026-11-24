import Foundation

/// Both research models export the input-major arrays W1, b1, W2, b2 in this order.
struct TanhNetwork: Decodable {
    private let inputWeights, outputWeights: [[Double]]
    private let hiddenBias, outputBias: [Double]

    init(from decoder: Decoder) throws {
        var arrays = try decoder.unkeyedContainer()
        inputWeights = try arrays.decode([[Double]].self)
        hiddenBias = try arrays.decode([Double].self)
        outputWeights = try arrays.decode([[Double]].self)
        outputBias = try arrays.decode([Double].self)
        guard arrays.isAtEnd else { throw ArtError.invalid("网络权重数量") }
    }

    func matches(inputs: Int, hidden: Int, outputs: Int) -> Bool {
        func matrix(_ values: [[Double]], _ rows: Int, _ cols: Int) -> Bool {
            values.count == rows && values.allSatisfy { $0.count == cols && $0.allSatisfy(\.isFinite) }
        }
        return matrix(inputWeights, inputs, hidden) && hiddenBias.count == hidden
            && hiddenBias.allSatisfy(\.isFinite) && matrix(outputWeights, hidden, outputs)
            && outputBias.count == outputs && outputBias.allSatisfy(\.isFinite)
    }

    func logits(_ inputs: [Double]) -> [Double] {
        precondition(inputs.count == inputWeights.count)
        var scores = outputBias
        for j in hiddenBias.indices {
            var activation = hiddenBias[j]
            for i in inputs.indices { activation += inputs[i] * inputWeights[i][j] }
            let h = tanh(activation)
            for k in scores.indices { scores[k] += h * outputWeights[j][k] }
        }
        return scores
    }
}

/// The shipped network is base-v1.json from Tools/Research/CatPolicy/experiment.py
/// (synthetic desktop interactions, training seed 430). Natural cat behavior uses a separate vocabulary.
struct AttentionModel: Decodable {
    private let schema: String
    private let features, intents: [String]
    private let weights: TanhNetwork

    static func loadIfPresent(root: URL) throws -> AttentionModel? {
        let folder = root.appendingPathComponent("Attention", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        let url = folder.appendingPathComponent("base-v1.json")
        let model = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard model.schema == "synthetic-desktop-intents-v1",
              model.features == ["recent_head_touch", "recent_sensitive_touch", "disturbance",
                                 "rest_drive", "elapsed_in_pose", "pointer_nearness"],
              model.intents == ["rest", "look", "groom", "withdraw"],
              model.weights.matches(inputs: 6, hidden: 16, outputs: 4)
        else { throw ArtError.invalid("注意模型结构或输入输出不兼容") }
        return model
    }

    /// The attention interrupt chooses between rest and look. Their conditional
    /// log odds equal the difference of those two logits in the original softmax.
    fileprivate func logOdds(_ inputs: [Double]) -> Double {
        let scores = weights.logits(inputs)
        return scores[1] - scores[0]
    }
}

struct AttentionDecision {
    let looks: Bool
    let hold: Double
    let lookProbability: Double
}

final class AttentionPolicy {
    private struct Profile: Codable {
        var lookVotes = 0
        var restVotes = 0
        var encounters = 0
        var lastEncounter: TimeInterval?
    }

    private let model: AttentionModel
    private let defaults: UserDefaults?
    private let profileKey = "Dada.Attention.profile.v1"
    private var profile = Profile()
    var feedbackCount: Int { profile.lookVotes + profile.restVotes }
    var familiarEncounters: Int { profile.encounters }

    init(model: AttentionModel, defaults: UserDefaults?) {
        self.model = model
        self.defaults = defaults
        if let data = defaults?.data(forKey: profileKey),
           let saved = try? JSONDecoder().decode(Profile.self, from: data),
           (0...1000).contains(saved.lookVotes), (0...1000).contains(saved.restVotes),
           (0...12).contains(saved.encounters), saved.lastEncounter?.isFinite != false {
            profile = saved
        }
    }

    /// Call on a quiet approach or comfortable light touch only. Sensitivity,
    /// withdrawal, pickup and double-pet affection retain their existing routes.
    func decide(touch: Bool, disturbance: Double, restDrive: Double, elapsed: Double, nearness: Double,
                approachSpeed: Double = 0, draw: Double = .random(in: 0..<1)) -> AttentionDecision {
        func unit(_ value: Double) -> Double { min(1, max(0, value)) }
        let near = unit(nearness)
        let disturbance = unit(disturbance)
        let inputs = [touch ? 1.0 : 0.0, 0, disturbance, unit(restDrive), unit(elapsed / 180), near]
        var score = model.logOdds(inputs)
        let fastPass = unit((approachSpeed - 1) / 5)
        if !touch {
            // Synthetic training sampled arbitrary pointer positions. Reaching this
            // decision requires an actual outside-to-inside visit. Calibrate that
            // selected event for the desktop; approach speed has no training label.
            score = 0.53 * score + 1.52 - 1.22 * fastPass
        }
        var familiarity = 0.0
        if disturbance < 0.45 {
            let odds = Double(profile.lookVotes + 2) / Double(profile.restVotes + 2)
            score += log(min(5, max(0.2, odds)))
            familiarity = Double(profile.encounters) / 12
        }
        let probability = 1 / (1 + exp(-score))
        // The training labels specify intent, not gaze time. These bounded
        // animation timings allow a familiar, quiet encounter to linger a little.
        let pass = touch ? 0 : 0.32 * fastPass
        let hold = max(0.45, 0.48 + 1.35 * probability + 0.20 * near + 0.55 * familiarity - pass)
        return AttentionDecision(looks: draw < probability, hold: hold, lookProbability: probability)
    }

    func teach(look: Bool) {
        if max(profile.lookVotes, profile.restVotes) >= 1000 {
            profile.lookVotes /= 2
            profile.restVotes /= 2
        }
        if look { profile.lookVotes += 1 } else { profile.restVotes += 1 }
        save()
    }

    /// Count a completed, gentle encounter at most once per half hour across launches.
    @discardableResult func recordGentleEncounter(at date: Date = Date()) -> Bool {
        let time = date.timeIntervalSinceReferenceDate
        guard profile.encounters < 12, time.isFinite else { return false }
        if let last = profile.lastEncounter, time - last < 1800 { return false }
        profile.encounters += 1
        profile.lastEncounter = time
        save()
        return true
    }

    func reset() {
        profile = Profile()
        defaults?.removeObject(forKey: profileKey)
    }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: profileKey)
    }
}

/// Distances are measured from the face in cat body lengths. A visit starts
/// outside the outer radius and ends at the inner one. A stationary cursor
/// already beside a newly seated cat does not count as an approach.
struct PointerApproach {
    private var previous: Double?
    private var armed = false
    private var cooldown = 0.0
    private(set) var closingSpeed = 0.0   // body lengths per second

    mutating func observe(distance: Double, dt: Double) -> Bool {
        guard distance.isFinite, distance >= 0, dt.isFinite, dt > 0, dt <= 0.5 else {
            self = PointerApproach()
            return false
        }
        let last = previous
        previous = distance
        cooldown = max(0, cooldown - dt)
        if let last {
            let speed = min(32, max(0, (last - distance) / dt))
            closingSpeed += (speed - closingSpeed) * (1 - exp(-dt / 0.12))
        }
        if distance >= 1.65 { armed = true }
        guard let last, armed, distance < 1.05 else { return false }
        armed = false
        guard cooldown == 0, distance < last else { return false }
        cooldown = 2.5
        return true
    }
}

func verifyAttentionPolicy(_ model: AttentionModel) throws {
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArtError.invalid("注意模型 · " + message) }
    }
    let name = "Alongside.Attention.Check." + UUID().uuidString
    guard let store = UserDefaults(suiteName: name) else { throw ArtError.invalid("注意个性检查") }
    defer { store.removePersistentDomain(forName: name) }
    let policy = AttentionPolicy(model: model, defaults: store)
    func touch(_ brain: AttentionPolicy, draw: Double = 0) -> AttentionDecision {
        brain.decide(touch: true, disturbance: 0.1, restDrive: 0.6, elapsed: 90, nearness: 0.8, draw: draw)
    }
    let before = touch(policy)
    // Independent NumPy reference for the bundled 6→16→4 network.
    try require(abs(before.lookProbability - 0.8099927054225138) < 1e-6, "训练权重的推断值")
    try require(before.looks && !touch(policy, draw: 1).looks, "按概率选择回看或休息")
    policy.teach(look: true)
    let time = Date(timeIntervalSinceReferenceDate: 3600)
    let afterVote = touch(policy)
    try require(policy.recordGentleEncounter(at: time), "记录温和互动")
    try require(touch(policy).lookProbability == afterVote.lookProbability
                && touch(policy).hold > afterVote.hold, "相处次数独立于喜好反馈")
    let restored = AttentionPolicy(model: model, defaults: store)
    try require(restored.feedbackCount == 1 && restored.familiarEncounters == 1, "重新载入个性")
    try require(!restored.recordGentleEncounter(at: time.addingTimeInterval(1799)), "温和接触去重")
    try require(restored.recordGentleEncounter(at: time.addingTimeInterval(1800)), "另一次温和接触")
    try require(touch(restored).lookProbability > before.lookProbability && touch(restored).hold > before.hold,
                "偏好与熟悉度影响反应")
    for _ in 0..<4 { restored.teach(look: false) }
    try require(touch(restored).lookProbability < before.lookProbability, "偏爱安静")
    restored.reset()
    let clean = AttentionPolicy(model: model, defaults: store)
    try require(clean.feedbackCount == 0 && clean.familiarEncounters == 0
                && touch(clean).lookProbability == before.lookProbability, "清除独立档案")
    var approach = PointerApproach()
    let visits = [0.5, 0.5, 2.0, 1.4, 0.9, 0.9, 1.1, 0.8].map {
        approach.observe(distance: $0, dt: 1 / 30.0)
    }
    try require(visits == [false, false, false, false, true, false, false, false], "接近仅触发一次")
    func approachDecision(_ speed: Double) -> AttentionDecision {
        clean.decide(touch: false, disturbance: 0, restDrive: 0.9, elapsed: 5,
                     nearness: 0.36, approachSpeed: speed, draw: 0)
    }
    let slow = approachDecision(1), fast = approachDecision(6)
    try require((0.40...0.65).contains(slow.lookProbability), "刚趴下时能察觉缓慢来访")
    try require(approach.closingSpeed > 0 && fast.lookProbability < slow.lookProbability
                && fast.hold < slow.hold, "接近速度影响注意和停留")
}
