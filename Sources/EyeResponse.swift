import Foundation

/// One eye movement sampled during a quiet encounter. Times use the existing rest clock.
struct EyeMovement {
    enum Kind: Int, CaseIterable { case halfBlink, narrow, close }
    let kind: Kind
    let onset, duration: Double

    func lid(at age: Double) -> Int? {
        let t = age - onset
        guard t >= 0, t < duration else { return nil }
        if kind == .close && t >= 0.13 && t < duration - 0.16 { return 1 }
        return 0
    }
}

struct EyeResponseModel: Decodable {
    enum Condition: Int { case neutral, slowBlink }
    private let schema: String, conditions, movements: [String]
    private let perMinute, seconds: [[Double]]

    static func loadIfPresent(root: URL) throws -> Self? {
        let file = root.appendingPathComponent("Attention/eye-events-v1.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let model = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        func valid(_ table: [[Double]]) -> Bool {
            table.count == 2 && table.allSatisfy { $0.count == 3 && $0.allSatisfy { $0 > 0 && $0.isFinite } }
        }
        guard model.schema == "cat-eye-events-1", model.conditions == ["neutral", "slowBlink"],
              model.movements == ["halfBlink", "narrow", "close"], valid(model.perMinute), valid(model.seconds)
        else { throw ArtError.invalid("眼神回应模型") }
        return model
    }

    // The data contain counts per minute, not individual reaction times. Model
    // a first event inside this encounter using competing constant rates.
    func firstMovement(_ condition: Condition, at age: Double, window: Double,
                       timeDraw: Double, kindDraw: Double) -> EyeMovement? {
        let rates = perMinute[condition.rawValue], total = rates.reduce(0, +)
        guard (0..<1).contains(timeDraw), (0...1).contains(kindDraw), window > 0 else { return nil }
        let delay = -log1p(-timeDraw) * 60 / total
        guard delay < window else { return nil }
        let sample = kindDraw * total
        let kind: EyeMovement.Kind = sample < rates[0] ? .halfBlink :
            (sample < rates[0] + rates[1] ? .narrow : .close)
        // Long real closures may last many seconds. Keep the desktop cat
        // responsive and keep a prolonged narrowing distinct from a half blink.
        let bounds: ClosedRange<Double>
        switch kind {
        case .halfBlink: bounds = 0.18...0.65
        case .narrow: bounds = 0.75...1.85
        case .close: bounds = 0.85...2.65
        }
        let measured = seconds[condition.rawValue][kind.rawValue]
        return EyeMovement(kind: kind, onset: age + delay,
                           duration: min(bounds.upperBound, max(bounds.lowerBound, measured)))
    }
}

func verifyEyeResponses(_ model: EyeResponseModel) throws {
    func check(_ ok: Bool, _ name: String) throws { if !ok { throw ArtError.invalid("眼神回应 · " + name) } }
    let a = model.firstMovement(.slowBlink, at: 5, window: 8, timeDraw: 0.1, kindDraw: 0)
    let b = model.firstMovement(.slowBlink, at: 5, window: 8, timeDraw: 0.1, kindDraw: 0.65)
    let c = model.firstMovement(.slowBlink, at: 5, window: 8, timeDraw: 0.1, kindDraw: 0.98)
    guard let a, let b, let c else { throw ArtError.invalid("眼神回应缺少动作") }
    try check(a.kind == .halfBlink && b.kind == .narrow && c.kind == .close &&
              abs(a.duration - 0.54) < 1e-8 && a.duration < b.duration, "不同眼睑动作与实测时长")
    try check(abs(a.onset - (5 - log(0.9)*60/(161.5/18.5))) < 1e-9,
              "与训练导出的每分钟发生率一致")
    try check(c.lid(at: 5) == nil && c.lid(at: c.onset + 0.01) == 0 &&
              c.lid(at: c.onset + 0.3) == 1 && c.lid(at: c.onset + c.duration - 0.08) == 0 &&
              c.lid(at: c.onset + c.duration + 0.01) == nil, "循半闭、闭合、半开回到睁眼")
    try check(model.firstMovement(.neutral, at: 0, window: 8, timeDraw: 0.58, kindDraw: 0) == nil &&
              model.firstMovement(.slowBlink, at: 0, window: 8, timeDraw: 0.58, kindDraw: 0) != nil &&
              model.firstMovement(.slowBlink, at: 0, window: 8, timeDraw: 0.9, kindDraw: 0) == nil,
              "相同采样下不同情境有各自的回应机会，也可继续睁眼")
}
