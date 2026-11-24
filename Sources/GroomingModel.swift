import Foundation

enum GroomingSite: String, CaseIterable, Decodable {
    case face = "paw_face"
    case chest
    case shoulder = "shoulder_flank"
    case foot = "hind_paw"
}

/// Estimates another sample of grooming time given up to two observed regions
/// in the same bout. The training table contains time shares, not an event log.
struct GroomingModel: Decodable {
    struct Check: Decodable {
        let history: [GroomingSite]
        let probabilities: [Double]
    }
    private let schema: String
    private let regions: [String]
    private let weights: TanhNetwork
    let checks: [Check]

    static func loadIfPresent(root: URL) throws -> Self? {
        let url = root.appendingPathComponent("Behavior/grooming-v1.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let model = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard model.schema == "dada-grooming-time-share-v1",
              model.regions == GroomingSite.allCases.map(\.rawValue),
              model.checks.count >= 2,
              model.checks.allSatisfy({ $0.history.count <= 2 && $0.probabilities.count == 4 &&
                  $0.probabilities.allSatisfy({ (0...1).contains($0) }) }),
              model.weights.matches(inputs: 4, hidden: 6, outputs: 4) else {
            throw ArtError.invalid("理毛部位网络")
        }
        return model
    }

    func probabilities(after history: [GroomingSite]) -> [Double] {
        let recent = history.suffix(2)
        let features = GroomingSite.allCases.map { site in
            recent.reduce(0.0) { $0 + ($1 == site ? 0.5 : 0) }
        }
        let scores = weights.logits(features)
        let peak = scores.max()!
        let values = scores.map { exp($0 - peak) }
        let mass = values.reduce(0, +)
        return values.map { $0 / mass }
    }

    func choose(after history: [GroomingSite], allowed: [GroomingSite], draw: Double) -> GroomingSite {
        precondition(!allowed.isEmpty)
        let probabilities = probabilities(after: history)
        let pairs = zip(GroomingSite.allCases, probabilities).filter { allowed.contains($0.0) }
        var threshold = min(1, max(0, draw)) * pairs.reduce(0) { $0 + $1.1 }
        for (site, probability) in pairs {
            threshold -= probability
            if threshold < 0 { return site }
        }
        return pairs.last!.0
    }
}

func verifyGroomingControl(_ art: PetArt) throws {
    guard let model = art.groomingModel, let durationModel = art.behaviorModel else {
        throw ArtError.invalid("缺少理毛部位或时长模型")
    }
    func check(_ ok: Bool, _ message: String) throws {
        if !ok { throw ArtError.invalid("理毛控制 · " + message) }
    }
    // Held apart from Swift, the Python export produces these distributions.
    for sample in model.checks {
        let p = model.probabilities(after: sample.history)
        try check(zip(p, sample.probabilities).allSatisfy { abs($0 - $1) < 1e-8 }, "本机推断与导出概率相符")
    }
    let part = durationModel.survival(of: .groom, from: 1, through: 4)
    let remainder = durationModel.survival(of: .groom, from: 4, through: 19)
    let whole = durationModel.survival(of: .groom, from: 1, through: 19)
    try check(abs(whole - part * remainder) < 0.000001 && whole > 0 && whole < part && part < 1,
              "按实际已用时长累计保持理毛的概率")
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }
    var rollouts = Set<[GroomingSite]>()
    var repeats = false, shortest = 8, longest = 0
    let library = MotionLibrary(art), home = MotionFrame(art.cel("settle", 8))
    for seed: UInt64 in 1...64 {
        var random = Generator(state: seed)
        let trial = GroomingBout(art: art, motions: library, showcase: false, using: &random)
        let sites = trial.sites
        let frames = trial.sequence.timedFrames
        try check((1...8).contains(sites.count) && frames.first?.frame == home && frames.last?.frame == home,
                  "自主选择的任意部位组合都要接回趴姿")
        rollouts.insert(sites)
        repeats = repeats || zip(sites, sites.dropFirst()).contains { $0 == $1 }
        longest = max(longest, sites.count)
        shortest = min(shortest, sites.count)
    }
    try check(rollouts.count >= 12 && shortest == 1 && longest >= 4 && repeats, "可短洗、继续同处或转向别处")
    print("理毛模型回放 64 轮产生 \(rollouts.count) 种部位序列，每轮 \(shortest)–\(longest) 组。")
}
