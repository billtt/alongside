import AppKit

// The review movie and the desktop checks feed the same screen-coordinate
// events as the running cat. The window stays hidden and the real pointer stays still.
struct AttentionCheckScene {
    let pet: PetController
    let head: CGPoint
    let paw: CGPoint
    let dt = 1.0 / 30

    init(art: PetArt, screen: NSScreen, draw: @escaping () -> Double) throws {
        pet = PetController(art: art, screen: screen, attentionDraw: draw, defaults: nil)
        let ground = CGRect(x: pet.x - 1600, y: pet.y, width: 3200, height: 1200)
        pet.surface = DockSurface(terrain: Terrain(screen: ground, dock: nil), source: "注意力测试平地")
        pet.base = 130
        pet.resize(1, persist: false)
        pet.change(to: .prone, for: 60)
        for _ in 0..<300 where pet.pose != .prone { pet.step(1.0 / 30) }
        pet.render()
        guard pet.pose == .prone, let sprite = pet.view.drawing else {
            throw ArtError.invalid("注意力场景未就绪")
        }
        head = try Self.point(on: sprite, area: .head, near: CGPoint(x: 0.31, y: 0.15))
        paw = try Self.point(on: sprite, area: .sensitive, near: CGPoint(x: 0.19, y: 0.85))
    }

    // Start at the nearest opaque point in the requested region, using the
    // painted frame's own touch map for all coordinate conversions.
    private static func point(on sprite: SpriteDrawing, area: TouchArea, near target: CGPoint) throws -> CGPoint {
        let bounds = CGRect(origin: .zero, size: sprite.frame.size)
        var best: (CGPoint, CGFloat)?
        for row in 1..<31 {
            for column in 1..<41 {
                let u = CGFloat(column) / 41, v = CGFloat(row) / 31
                let point = CGPoint(x: u * bounds.width, y: (1 - v) * bounds.height)
                guard sprite.touchArea(at: point) == area else { continue }
                let distance = hypot(u - target.x, v - target.y)
                if distance < (best?.1 ?? .infinity) { best = (point, distance) }
            }
        }
        guard let point = best?.0 else { throw ArtError.invalid("注意力场景缺少触摸区域") }
        return CGPoint(x: sprite.frame.minX + point.x, y: sprite.frame.minY + point.y)
    }

    func byHead(x: CGFloat, y: CGFloat) -> CGPoint {
        CGPoint(x: head.x + x * pet.unit, y: head.y + y * pet.unit)
    }

    func approaching(_ fraction: Double) -> CGPoint {
        let t = min(1, max(0, fraction))
        return byHead(x: -2.35 + 2.06 * t, y: 0.55 - 0.38 * t)
    }

    func advance(_ point: CGPoint) {
        pet.step(dt, pointer: point)
        pet.render()
    }
}

func verifyAttention(_ art: PetArt, screen: NSScreen) throws {
    func require(_ ok: Bool, _ message: String) throws {
        if !ok { throw ArtError.invalid(message) }
    }
    let scene = try AttentionCheckScene(art: art, screen: screen, draw: { 0.01 })
    let pet = scene.pet
    let prone = art.cel("settle", 8)
    func pixels(direction: CGFloat, mirror: Bool = false) throws -> [UInt8] {
        let image = SpriteDrawing(cel: prone, grounded: true, mirror: mirror, feet: .zero,
                                  k: 1, stretch: 1, backing: 1, gaze: CGPoint(x: direction, y: 0)).image
        let w = image.width, h = image.height
        guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let raw = cg.data else { throw ArtError.invalid("校验注视原画") }
        cg.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Array(UnsafeBufferPointer(start: raw.assumingMemoryBound(to: UInt8.self), count: w*h*4))
    }
    let left = try pixels(direction: -1), right = try pixels(direction: 1)
    try require(left != right && left.suffix(left.count/2).elementsEqual(right.suffix(right.count/2)),
                "左右注视改变头部像素，保留腹部与爪子")
    let mirrored = try pixels(direction: 1, mirror: true)
    try require(left == mirrored, "注视的屏幕方向随原画镜像校正")
    let remaining = pet.remainingPoseTime
    let feet = CGPoint(x: pet.x, y: pet.y)
    var responded = false, turnedLeft = false
    for frame in 0..<36 {
        scene.advance(scene.approaching(Double(frame) / 32))
        responded = responded || pet.isAttending
        turnedLeft = turnedLeft || (pet.view.drawing?.gaze.x ?? 0) < -0.05
    }
    try require(responded && turnedLeft, "靠近头左侧时产生向左的注视")
    try require(pet.pose == .prone && feet == CGPoint(x: pet.x, y: pet.y), "注视期间保持趴姿和接地")
    for _ in 0..<210 { scene.advance(scene.approaching(1)) }
    try require(!pet.isAttending && (pet.view.drawing?.gaze ?? .zero) == .zero,
                "指针停留后注视结束并收回")
    try require(abs((remaining - pet.remainingPoseTime) - 246 * scene.dt) < 0.002,
                "注视过程中原卧姿时钟连续")

    pet.press(at: scene.head)
    pet.release(at: scene.head)
    scene.advance(scene.head)
    try require(pet.isAttending && pet.pose == .prone, "轻触头部可以从原趴姿注意")
    pet.press(at: scene.paw)
    pet.release(at: scene.paw)
    var walked = false
    for _ in 0..<150 {
        scene.advance(scene.paw)
        walked = walked || pet.pose == .walking
        if walked && abs(pet.x - feet.x) > pet.unit * 0.15 { break }
    }
    try require(walked && !pet.isAttending && abs(pet.x - feet.x) > pet.unit * 0.15,
                "碰爪后中止注视并走开")

    let quiet = try AttentionCheckScene(art: art, screen: screen, draw: { 0.9999 })
    var quietResponse = false
    for frame in 0..<36 {
        quiet.advance(quiet.approaching(Double(frame) / 32))
        quietResponse = quietResponse || quiet.pet.isAttending
    }
    try require(!quietResponse && quiet.pet.pose == .prone, "一次靠近也可以继续休息")
    quiet.pet.press(at: quiet.head)
    quiet.pet.release(at: quiet.head)
    let beforeBlink = quiet.pet.remainingPoseTime
    quiet.pet.press(at: quiet.head, clickCount: 2)
    quiet.pet.release(at: quiet.head)
    try require(quiet.pet.attention?.familiarEncounters == 1, "温和双击只记作一次熟悉的接触")
    try require(quiet.pet.pose == .look, "双击仍能引发原画的眯眼回应")
    var ticks = 0, sawHeart = false
    while ticks < 180 && quiet.pet.pose != .prone {
        quiet.advance(quiet.head)
        sawHeart = sawHeart || quiet.pet.view.heart != nil
        ticks += 1
    }
    try require(quiet.pet.pose == .prone && sawHeart &&
                abs(quiet.pet.remainingPoseTime - (beforeBlink - Double(ticks)*quiet.dt)) < 0.002,
                "双击眯眼冒爱心后接续原有休息时钟")
    var draws = [0.02, 0.98].makeIterator()
    let blink = try AttentionCheckScene(art: art, screen: screen, draw: { draws.next() ?? 0.99 })
    let start = blink.pet.remainingPoseTime, feetBeforeBlink = CGPoint(x: blink.pet.x, y: blink.pet.y)
    blink.pet.offerSlowBlink()
    var closeFrames = 0
    for _ in 0..<96 {
        blink.pet.step(blink.dt)
        blink.pet.render()
        if blink.pet.view.eyelids?.patches.first === art.eyelids.last?.patches.first { closeFrames += 1 }
    }
    try require(closeFrames >= 18 && blink.pet.view.eyelids == nil && !blink.pet.canReceiveSlowBlink &&
                blink.pet.pose == .prone && feetBeforeBlink == CGPoint(x: blink.pet.x, y: blink.pet.y) &&
                abs((start - blink.pet.remainingPoseTime) - 96 * blink.dt) < 0.001, "慢眨眼回应中先眯再闭，张眼后接续原时钟")
    blink.pet.press(at: blink.head, clickCount: 2)
    blink.pet.release(at: blink.head)
    for _ in 0..<90 where blink.pet.pose != .prone { blink.advance(blink.head) }
    try require(blink.pet.pose == .prone && !blink.pet.canReceiveSlowBlink,
                "温和触摸后继续计时，避免重复抽取同一次慢眨眼的回应")
    blink.pet.sleepNow()
    blink.pet.offerSlowBlink()
    try require(!blink.pet.canReceiveSlowBlink && blink.pet.view.eyelids == nil, "离开正面趴姿时结束眼神互动")
    print("Attention: approach, gaze, touch, slow blink, interrupted poses and rest clock passed.")
}
