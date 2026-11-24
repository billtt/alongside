import Foundation

// The five labels in the 1 Hz domestic-cat observation model. Sleep and touch
// are outside this data set. The caller supplies the currently drawable choices.
enum ObservedActivity: String, CaseIterable {
    case lie, sit, stand, move, groom
}

struct RestBehaviorModel: Decodable {
    private let format: Int
    private let labels: [String]
    private let weights: TanhNetwork
    private let exitProbability: [[Double]]
    private let ageCuts: [Int]

    private enum CodingKeys: String, CodingKey {
        case format, labels, weights
        case exitProbability = "exit_probability_by_age", ageCuts = "clock_age_cuts_seconds"
    }

    static func loadIfPresent(root: URL) throws -> Self? {
        let url = root.appendingPathComponent("Behavior/transitions-v1.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let model = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard model.format == 1, model.labels == ObservedActivity.allCases.map(\.rawValue),
              model.weights.matches(inputs: 11, hidden: 8, outputs: 5),
              model.ageCuts.allSatisfy({ $0 > 0 }), model.ageCuts == Array(Set(model.ageCuts)).sorted(),
              model.exitProbability.count == model.labels.count,
              model.exitProbability.allSatisfy({ row in
                  row.count == model.ageCuts.count + 1 && row.allSatisfy { (0...1).contains($0) }
              }) else { throw ArtError.invalid("日常行为模型") }
        return model
    }

    // Probability that an already lying cat stays in that class for the next
    // thirty observed seconds. An attention decision uses this as rest drive.
    func restDrive(after seconds: Double) -> Double {
        let age = max(1, Int(seconds))
        return survival(of: .lie, from: age, through: age + 30)
    }

    // Each hazard estimates a change on the interval from age to age + 1.
    // Stop decisions at motor boundaries can span several such intervals.
    func survival(of activity: ObservedActivity, from start: Int, through end: Int) -> Double {
        let row = ObservedActivity.allCases.firstIndex(of: activity)!
        var chance = 1.0
        for age in max(1, start)..<max(1, start, end) {
            let bin = ageCuts.firstIndex(where: { $0 > age }) ?? ageCuts.count
            chance *= 1 - exitProbability[row][bin]
        }
        return chance
    }

    func next(after previous: ObservedActivity, current: ObservedActivity, seconds: Double,
              allowed: [ObservedActivity], draw: Double) -> ObservedActivity? {
        let classes = ObservedActivity.allCases
        var features = classes.map { $0 == previous ? 1.0 : 0.0 }
        features += classes.map { $0 == current ? 1.0 : 0.0 }
        features.append(log1p(max(1, seconds)) / 4)
        let logits = weights.logits(features)
        let choices = classes.indices.filter { classes[$0] != current && allowed.contains(classes[$0]) }
        guard let maximum = choices.map({ logits[$0] }).max() else { return nil }
        let masses = choices.map { exp(logits[$0] - maximum) }
        var roll = min(max(0, draw), 1) * masses.reduce(0, +)
        for (choice, mass) in zip(choices, masses) {
            roll -= mass
            if roll < 0 { return classes[choice] }
        }
        return choices.last.map { classes[$0] }
    }
}
