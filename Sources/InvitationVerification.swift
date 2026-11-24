import AppKit

// All scenarios enter through step(_:pointer:). The model reads the same pointer
// positions as the preview paints. The test never moves the user's actual mouse.
final class InvitationReplay {
    enum Gesture {
        case nearby, farther, dockEdge, passing, distant
    }

    let scene: AttentionCheckScene
    let gesture: Gesture
    let start: CGPoint
    let eyes: CGPoint
    let side: CGFloat
    private(set) var stayedProne = true
    private(set) var walked = false
    private(set) var settled = false
    private(set) var farthest: CGFloat = 0
    private(set) var movedAfterSettling: CGFloat = 0
    private(set) var safe = true
    private var restX: CGFloat?
    private var originalTime: Double?
    private(set) var timeRestored = false

    var pet: PetController { scene.pet }

    init(art: PetArt, screen: NSScreen, gesture: Gesture, side: CGFloat = -1, ledgeRoom: CGFloat = 1.05,
         draw: @escaping () -> Double = { 0.001 }) throws {
        self.gesture = gesture
        self.side = side
        scene = try AttentionCheckScene(art: art, screen: screen, draw: draw)
        guard let draw = scene.pet.view.drawing, let centers = draw.cel.eyeCenters, centers.count == 2 else {
            throw ArtError.invalid("邀请场景缺少双眼标定")
        }
        let eye = CGPoint(x: (centers[0].x + centers[1].x) / 2,
                          y: CGFloat(draw.image.height) - (centers[0].y + centers[1].y) / 2)
            .applying(draw.transform)
        eyes = CGPoint(x: draw.frame.minX + eye.x, y: draw.frame.minY + eye.y)
        start = CGPoint(x: scene.pet.x, y: scene.pet.y)
        if gesture == .dockEdge {
            let unit = pet.unit, height = unit * 0.24
            let screen = pet.surface.terrain.screen.offsetBy(dx: 0, dy: -height)
            var dock = CGRect(x: start.x, y: screen.minY, width: unit * 9, height: height)
            let proposed = Terrain(screen: screen, dock: dock)
            guard let range = proposed.dockStandingRange(radius: pet.radius) else {
                throw ArtError.invalid("邀请场景缺少可承重台面")
            }
            // Move the platform until the nearest safe standing boundary has the requested room.
            let boundary = side < 0 ? range.lowerBound : range.upperBound
            dock.origin.x += start.x + side * ledgeRoom * unit - boundary
            pet.surface = DockSurface(terrain: Terrain(screen: screen, dock: dock), source: "邀请测试台沿")
            pet.render()
        }
    }

    func pointer(at seconds: Double) -> CGPoint {
        let near = 0.22, end = gesture == .nearby ? 1.60 : 2.45
        let approachStart = 0.45, nearStart = 1.55, retreatStart = 2.30
        func blend(_ first: Double, _ last: Double, _ t: Double) -> Double {
            first + (last - first) * min(1, max(0, t))
        }
        let distance: Double
        switch gesture {
        case .distant:
            distance = blend(2.65, 1.52, (seconds - approachStart) / 1.10)
                + 0.90 * min(1, max(0, seconds - retreatStart))
        default:
            if seconds < retreatStart {
                distance = blend(2.05, near, (seconds - approachStart) / (nearStart - approachStart))
            } else {
                let speed = gesture == .passing ? 5.0 : 0.85
                distance = min(end, near + speed * (seconds - retreatStart))
            }
        }
        return CGPoint(x: eyes.x + side * distance * pet.unit, y: eyes.y + 0.14 * pet.unit)
    }

    func step(frame: Int, buttonDown: Bool = false) {
        let previousTime = pet.remainingPoseTime
        let wasProne = pet.pose == .prone
        pet.step(scene.dt, pointer: pointer(at: Double(frame) * scene.dt), pointerButtonDown: buttonDown)
        pet.render()
        stayedProne = stayedProne && pet.pose == .prone
        if wasProne && pet.isFollowingInvitation { originalTime = previousTime }
        walked = walked || pet.pose == .walking
        farthest = max(farthest, (pet.x - start.x) * side / pet.unit)
        if walked && pet.pose == .prone {
            if restX == nil {
                restX = pet.x
                if let originalTime { timeRestored = abs(originalTime - pet.remainingPoseTime) <= 2 * scene.dt }
            }
            settled = true
        }
        if let restX { movedAfterSettling = max(movedAfterSettling, abs(pet.x - restX) / pet.unit) }
        safe = safe && abs(pet.y - start.y) < 0.001 && pet.pose != .hop && pet.pose != .fall
        if gesture == .dockEdge, let range = pet.surface.terrain.dockStandingRange(radius: pet.radius) {
            safe = safe && (range.lowerBound - 0.001 ... range.upperBound + 0.001).contains(pet.x)
        }
    }
}

func verifyInvitation(_ art: PetArt, screen: NSScreen) throws {
    func check(_ ok: Bool, _ message: String) throws {
        if !ok { throw ArtError.invalid(message) }
    }
    func run(_ gesture: InvitationReplay.Gesture, side: CGFloat = -1, ledgeRoom: CGFloat = 1.05, buttonDown: Bool = false,
             draw: @escaping () -> Double = { 0.001 }) throws -> InvitationReplay {
        let trial = try InvitationReplay(art: art, screen: screen, gesture: gesture, side: side, ledgeRoom: ledgeRoom, draw: draw)
        var calmFrames = 0
        for frame in 0..<540 {
            trial.step(frame: frame, buttonDown: buttonDown)
            if trial.settled { calmFrames += 1 }
            if calmFrames >= 25 { break }
        }
        try check(trial.safe, "邀请时保持原有地面，台面上只走到可承重位置")
        return trial
    }
    let close = try run(.nearby)
    let far = try run(.farther)
    let mirrored = try run(.nearby, side: 1)
    for accepted in [close, far, mirrored] {
        try check(accepted.walked && accepted.settled && accepted.farthest > 0.2,
                  "达达向邀请一侧移动，并能自行停下来")
        try check(accepted.movedAfterSettling < 0.001, "跟步结束后停在原地")
        try check(accepted.timeRestored, "跟步结束后续上邀请前的休息余量")
    }
    try check(far.farthest > close.farthest + 0.08, "两种邀请距离有不同的停点")
    for direction: CGFloat in [-1, 1] {
        let edge = try run(.dockEdge, side: direction)
        try check(edge.walked && edge.settled && edge.farthest > 0.5 && edge.farthest < far.farthest,
                  "台沿方向 \(direction)，行走 \(edge.walked)，收势 \(edge.settled)，向前位移 \(edge.farthest)，姿势 \(edge.pet.pose)")
    }
    let tooShort = try run(.dockEdge, side: -1, ledgeRoom: 0.74)
    try check(tooShort.stayedProne && tooShort.farthest < 0.001, "起身后空间不够迈完一步时保留趴姿")
    for negative in [try run(.distant), try run(.passing), try run(.nearby, buttonDown: true),
                     try run(.nearby, draw: { 0.99999 })] {
        try check(negative.stayedProne && negative.farthest < 0.001,
                  "远处活动、快速移开、在别处按住鼠标或拒绝邀请时保留趴姿")
    }
    let manual = try InvitationReplay(art: art, screen: screen, gesture: .farther)
    let midStride = art.cel("walk", 3)
    for tick in 0..<360 {
        manual.step(frame: tick)
        if manual.pet.pose == .walking && manual.pet.frame().0 === midStride { break }
    }
    try check(manual.pet.isFollowingInvitation && manual.pet.frame().0 === midStride,
              "可中断的邀请已迈到第三次换脚")
    let frame = MotionFrame(manual.pet.frame())
    manual.pet.sleepNow()
    try check(!manual.pet.isFollowingInvitation && frame == MotionFrame(manual.pet.frame()),
              "睡眠指令从跟步的当前绘稿接管")
    for _ in 0..<460 where manual.pet.pose != .sleepBack { manual.pet.step(manual.scene.dt) }
    try check(manual.pet.pose == .sleepBack, "打断邀请后完成背睡")
    print(String(format: "Invitation replay passed; near %.2f and far %.2f body lengths.", close.farthest, far.farthest))
}
