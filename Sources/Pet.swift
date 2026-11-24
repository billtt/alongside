import AppKit

enum Pose: Equatable {
    case changing, sitting, prone, side, loaf, sleepSide, sleepBack, sleepLoaf
    case look, backLook, grooming, walking, hop, fall, carried
    var asleep:Bool { self == .sleepSide || self == .sleepBack || self == .sleepLoaf }
    var observedActivity: ObservedActivity? {
        switch self {
        case .prone, .loaf, .side: return .lie
        case .sitting: return .sit
        case .walking: return .move
        case .grooming: return .groom
        default: return nil
        }
    }
}
final class PetController {
    struct InvitedWalk {
        var gait: ApproachGait
        let pace: CGFloat
        let restRemaining: Double
    }
    let art:PetArt
    let motions:MotionLibrary
    let panel:PetPanel
    let view=PetView()
    var controls:NSMenu?
    let detector=DockDetector()
    var screen:NSScreen
    var surface:DockSurface
    private(set) var pose:Pose = .sitting
    private(set) var x:CGFloat=0, y:CGFloat=0
    private(set) var scale:CGFloat
    var base:CGFloat
    var unit:CGFloat {(radius-2)/0.78}
    // All cels, including the extended swiping paw, fit this footprint.
    var radius:CGFloat {
        let terrain=surface.terrain
        let size=min(base*scale,terrain.screen.width*0.36,terrain.screen.height*0.51)
        return terrain.fittingRadius(size*0.78+2)
    }
    private var age:Double=0, duration:Double=0
    private var direction:CGFloat = -1
    private var walkStart=0
    private var walkRate:CGFloat {art.gait.speed}
    private var wakeHold:Double {Double.random(in:4...5.5)}
    private var nextBlink = Double.infinity
    private var nextGroom = Double.infinity
    private var restAtGroomStart = 0.0
    private var nextTwitch=Double.infinity
    private var enjoymentAt:Double?

    private var journey:DockMotion?, fallStart:CGFloat=0
    private var released:MotionFrame?
    private var pressurePoint:CGPoint?, lastDrag:CGPoint?, carriedPointer:CGPoint?
    private var draggedPress=false
    private var pickupBand=CGRect.zero
    private var reaction:Reaction?
    private var petting = PettingInput()
    private var heartAge: Double?
    private var heartOrigin = CGPoint.zero
    private var blinkAge: Double?
    private var shownLid: Int?
    private var lastTime=ProcessInfo.processInfo.systemUptime
    private var inspectAt=0.0, timer:Timer?
    private var arrival:(pose:Pose, duration:Double, invitation:InvitedWalk?, showcaseGrooming:Bool)?
    private var restShape:Pose = .prone
    let attention: AttentionPolicy?
    let invitation: InvitationPolicy?
    private var invitationGesture = InvitationGesture()
    private var invitedWalk: InvitedWalk?
    var isFollowingInvitation: Bool { invitedWalk != nil || arrival?.invitation != nil }
    private let attentionDraw: () -> Double
    private var approach = PointerApproach()
    private var gaze = CGPoint.zero, gazeTarget = CGPoint.zero
    private var attentionRemaining = 0.0
    private var eyeMovement: EyeMovement?
    private var socialBlinkCooldown = 0.0
    private var disturbance = 0.0
    private var pendingGentleEncounter = false
    private var lastActivity: ObservedActivity?
    private var priorActivity: ObservedActivity?
    // Keep the clock, breathing and scheduled grooming when petting briefly
    // takes over a rest pose. A menu action or a withdrawal abandons this return.
    private var interruptedRest: (pose: Pose, age: Double, duration: Double,
                                  blink: Double, groom: Double, twitch: Double)?
    var isAttending: Bool { attentionRemaining > 0 }
    var remainingPoseTime: Double { max(0, duration - age) }

    init(art:PetArt,screen:NSScreen,attentionDraw: @escaping () -> Double = { Double.random(in: 0..<1) },
         defaults: UserDefaults? = .standard) {
        self.art=art;self.screen=screen;motions=MotionLibrary(art)
        self.attentionDraw = attentionDraw
        attention = art.attentionModel.map { AttentionPolicy(model: $0, defaults: defaults) }
        invitation = art.invitationModel.map { InvitationPolicy(model: $0, defaults: defaults) }
        surface=detector.read(screen)
        let saved=UserDefaults.standard.double(forKey:"PetScale")
        scale=saved>0 ? clamp(saved,0.55,2) : 1
        base=Self.baseSize(screen:screen,surface:surface)
        panel=PetPanel(contentRect:NSRect(x:0,y:0,width:200,height:180),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.backgroundColor = .clear;panel.isOpaque=false;panel.hasShadow=false
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        panel.hidesOnDeactivate=false;panel.isFloatingPanel=true;panel.becomesKeyOnlyIfNeeded=true
        panel.animationBehavior = .none;panel.isReleasedWhenClosed=false;panel.isExcludedFromWindowsMenu=true
        panel.level=NSWindow.Level(rawValue:Int(CGWindowLevelForKey(.screenSaverWindow))-1)
        panel.contentView=view;view.pet=self
        x=surface.terrain.landingX(near:surface.terrain.dock.map{$0.midX+$0.width*0.16} ?? screen.frame.midX,radius:radius)
        y=surface.terrain.support(x,radius);set(.sitting,2.4);render()
    }
    static func baseSize(screen:NSScreen,surface:DockSurface)->CGFloat {
        let h=surface.terrain.dock?.height ?? max(0,screen.visibleFrame.minY-screen.frame.minY)
        // Screenshot: a prone cat spans about 2.25 Dock heights.
        return clamp((h>8 ? h:68)*2.25,100,240)
    }
    func start() {
        if attention != nil { restNow() }
        panel.orderFrontRegardless()
        let t=Timer(timeInterval:1/30,repeats:true){[weak self]_ in self?.tick()}
        t.tolerance=0.005;RunLoop.main.add(t,forMode:.common);timer=t
        NotificationCenter.default.addObserver(self,selector:#selector(displaysChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
    }
    @objc func displaysChanged() { refreshScreen(at:pressurePoint == nil ? nil:NSEvent.mouseLocation,force:true) }
    private func refreshScreen(at point:CGPoint?,force:Bool=false) {
        let display = point.flatMap{p in NSScreen.screens.first{$0.frame.contains(p)}} ??
            NSScreen.screens.first{$0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber} ?? NSScreen.screens.first
        guard let display else {return}
        let changed=display.frame != screen.frame
        screen=display
        let updated=detector.read(display)
        guard force || changed || updated.terrain != surface.terrain else {return}
        interruptInvitation()
        approach = PointerApproach()
        surface=updated
        if changed || updated.terrain.dock != nil {base=Self.baseSize(screen:display,surface:surface)}
        if pose == .hop || arrival?.pose == .hop {journey=nil;set(.walking,3)}
        if pose != .carried {x=surface.terrain.landingX(near:x,radius:radius);reconcileHeight()}
    }
    private func reconcileHeight() {
        let floor=surface.terrain.support(x,radius)
        if y<=floor+1 {y=floor}
        else if y>floor+1 {fallStart=y;set(.fall,clamp(sqrt((y-floor)/800),0.25,1.2))}
    }
    func resize(_ new:CGFloat, persist:Bool=true) {
        interruptInvitation()
        approach = PointerApproach()
        scale=clamp(new,0.55,2)
        if persist {UserDefaults.standard.set(Double(scale),forKey:"PetScale")}
        if pose == .hop || arrival?.pose == .hop {journey=nil;set(.walking,3)}
        if pose == .carried {followHand()}
        else {x=surface.terrain.landingX(near:x,radius:radius);reconcileHeight()}
        render()
    }
    private func set(_ p:Pose,_ seconds:Double, invitation: InvitedWalk? = nil, showcaseGrooming: Bool = false) {
        approach = PointerApproach()
        invitationGesture = InvitationGesture()
        invitedWalk = invitation
        gaze = .zero; gazeTarget = .zero; attentionRemaining = 0
        eyeMovement = nil
        if p != .look && p != .backLook { interruptedRest = nil }
        if p != .look { pendingGentleEncounter = false }
        if p.asleep {
            priorActivity = nil
            lastActivity = nil
        } else if let next = p.observedActivity, next != lastActivity {
            priorActivity = lastActivity
            lastActivity = next
        }
        arrival=nil;enjoymentAt=nil
        if p != .walking {walkStart=0}
        if p != .hop {journey=nil}
        reaction=nil
        if p == .carried || p == .fall || p == .hop {heartAge=nil;blinkAge=nil}
        nextTwitch=(p == .sleepSide || p == .sleepLoaf) ? .random(in:12...30):.infinity
        nextBlink = p == .prone ? .random(in: 4...13) : .infinity
        nextGroom = p == .prone && art.clips["grooming"] != nil ? .random(in: 80...180) : .infinity
        pose=p;duration=seconds;age=0
        if p == .grooming {
            let bout = GroomingBout(art: art, motions: motions, showcase: showcaseGrooming)
            reaction = bout.sequence
            duration = bout.sequence.duration
            restAtGroomStart = seconds
        }
    }
    // Both ends belong to the actual playing clips, including when a menu action interrupts a turn.
    func change(to next:Pose, for seconds:Double, from initial:MotionFrame?=nil, maximumFrameTime:Double = .infinity,
                invitation: InvitedWalk? = nil, showcaseGrooming: Bool = false) {
        let end:MotionFrame
        switch next {
        case .walking,.hop: end=MotionFrame(art.cel("walk",0),direction>0)
        case .sleepBack: end=MotionFrame(art.cel("turn",5))
        case .sleepSide: end=MotionFrame(art.cel("side",2))
        case .sleepLoaf: end=MotionFrame(art.cel("loaf",2))
        default: end=neutralFrame(for:next)
        }
        let start=initial ?? MotionFrame(frame())
        if next == .walking {walkStart=0}
        let route=motions.path(from:start,to:end)
        if route.count==1 {set(next,seconds,invitation:invitation,showcaseGrooming:showcaseGrooming);return}
        let sequence=Reaction(library:motions,path:route,maximumFrameTime:maximumFrameTime)
        set(.changing,sequence.duration)
        reaction=sequence
        arrival=(next,seconds,invitation,showcaseGrooming)
    }
    private func randomRest() {
        let roll=Int.random(in:0..<100)
        let traits=art.temperament
        let side=traits.backSleepWeight+traits.sideSleepWeight, loaf=traits.backSleepWeight+traits.sideSleepWeight+traits.loafSleepWeight
        if roll<traits.backSleepWeight {beginBackSleep()}
        else if roll<side {change(to:.sleepSide,for:traits.sleepTime)}
        else if roll<loaf {change(to:.sleepLoaf,for:traits.sleepTime)}
        else if let model = art.behaviorModel, let current = pose.observedActivity, let prior = priorActivity,
                let next = model.next(after: prior, current: current, seconds: age,
                                      allowed: art.clips["grooming"] == nil ? [.lie,.sit,.move] : [.lie,.sit,.move,.groom],
                                      draw: Double.random(in: 0..<1)) {
            switch next {
            case .lie: change(to: [Pose.prone, .loaf, .side].randomElement()!, for: traits.restTime)
            case .sit: change(to: .sitting, for: .random(in: 2...6))
            case .groom: change(to: .grooming, for: traits.restTime)
            case .move: startWalk()
            case .stand: break // No standing cel in the allowed set.
            }
        }
        else if roll<loaf+traits.quietRestWeight {change(to:[Pose.prone,.loaf,.side].randomElement()!,for:traits.restTime)}
        else {startWalk()}
    }
    func restNow() {
        guard isGrounded else { return }
        change(to: .prone, for: art.temperament.restTime)
        render()
    }
    private func beginBackSleep() {
        change(to:.sleepBack,for:art.temperament.sleepTime)
    }
    func groomNow(showcase: Bool = true) {
        guard isGrounded, art.clips["grooming"] != nil, pose != .grooming, arrival?.pose != .grooming else { return }
        let rest = pose == .prone ? duration - age : art.temperament.restTime
        change(to: .grooming, for: rest, showcaseGrooming: showcase)
        render()
    }
    func sleepNow() {
        guard isGrounded else{return}
        pressurePoint=nil;petting.cancelDrag();heartAge=nil;blinkAge=nil
        beginBackSleep()
        render()
    }
    var isGrounded:Bool {pose != .carried && pose != .fall && pose != .hop}
    func startWalk(towardDock:Bool=false) {
        guard isGrounded else{return}
        let t=surface.terrain
        let initial=MotionFrame(frame())
        if let d=t.dock, towardDock || Int.random(in:0..<4) != 0 {
            if x < d.minX {direction=1}
            else if x>d.maxX {direction = -1}
            else {direction=x<d.midX ? -1:1}
        } else {direction=Bool.random() ? -1:1}
        // A manually requested walk lasts through the nearest reachable platform crossing.
        let destination:CGFloat
        if let d=t.dock {destination=direction > 0 ? (x<d.minX ? d.minX:d.maxX) : (x>d.maxX ? d.maxX:d.minX)}
        else {destination=x}
        let walkTime=towardDock ? min(120,max(6,Double(abs(destination-x)/(unit*art.gait.speed))+5.0)) : .random(in:5...11)
        change(to:.walking,for:walkTime,from:initial)
        render()
    }
    private func advanceState() {
        if (pose == .look || pose == .backLook), let saved = interruptedRest {
            let elapsed = age
            set(saved.pose, saved.duration)
            age = min(saved.duration, saved.age + elapsed)
            nextBlink = saved.blink; nextGroom = saved.groom; nextTwitch = saved.twitch
            return
        }
        switch pose {
        case .changing:
            if let arrival {set(arrival.pose,arrival.duration,invitation:arrival.invitation,showcaseGrooming:arrival.showcaseGrooming)}
        case .grooming:
            set(.prone, max(1, restAtGroomStart - age))
            nextGroom = .random(in: 180...360)
        case .sitting: randomRest()
        case .walking: change(to:.sitting,for:1.4)
        case .look: set(restShape,restShape.asleep ? art.temperament.sleepTime : (restShape == .sitting || restShape == .walking ? 4.2:art.temperament.restTime))
        case .backLook: set(.sleepBack,art.temperament.sleepTime)
        case .hop:
            if let j=journey {x=j.hop.endX;y=j.hop.endY;walkStart=j.exitStride}
            journey=nil
            set(.walking,.random(in:2.4...5.2))
        case .fall:
            y=surface.terrain.support(x,radius)
            change(to:.sitting,for:1.1)
        case .carried: break
        case .sleepBack:
            if Int.random(in:0..<3) == 0 {beginLook(hold:1.6)}
            else {change(to:.prone,for:art.temperament.restTime)}
        case .sleepSide,.sleepLoaf: beginLook(hold:2.0)
        case .loaf,.side,.prone: randomRest()
        }
    }
    func press(at point:CGPoint,clickCount:Int=1) {
        guard let draw=view.drawing else {return}
        let local=CGPoint(x:point.x-draw.frame.minX,y:point.y-draw.frame.minY)
        guard let area=draw.touchArea(at:local) else {return}
        interruptInvitation()
        pendingGentleEncounter = false
        pressurePoint=point;lastDrag=point;draggedPress=false
        pickupBand=panel.frame.insetBy(dx:-max(6,unit*0.07),dy:0)
        if isGrounded, let response=petting.press(area,threshold:art.temperament.irritationThreshold,clickCount:clickCount) {
            respond(response,at:point,area:area)
        }
        disturbance = min(1, disturbance + (area == .sensitive ? 0.48 : 0.18))
        render()
    }
    func drag(to p:CGPoint) {
        guard let down=pressurePoint else{return}
        let previous=lastDrag ?? down
        lastDrag=p
        if !draggedPress && hypot(p.x-down.x,p.y-down.y)>=4 {
            draggedPress=true;pendingGentleEncounter=false;petting.cancelDrag()
        }
        if pose != .carried {
            let first=art.cel("carry",0)
            let liftHeight=max(down.y+max(6,unit*0.045), y + first.gripHeight*first.scale*unit)
            guard p.y>=liftHeight, p.y>previous.y else {return}
            let crossing=clamp((liftHeight-previous.y)/(p.y-previous.y),0,1)
            let atX=previous.x+(p.x-previous.x)*crossing
            guard pickupBand.minX...pickupBand.maxX ~= atX else {return}
            journey=nil;set(.carried,.infinity);petting.cancelDrag()
        }
        carriedPointer=p
        if !screen.frame.contains(p) {refreshScreen(at:p)}
        followHand()
        render()
    }
    private func followHand() {
        guard pose == .carried,let p=carriedPointer else{return}
        let cel=frame().0, k=cel.scale*unit
        x=p.x
        y=p.y-cel.gripHeight*k
        let t=surface.terrain
        let ground=t.support(x,radius)
        // If the hand lowers past touchdown, return to a supported pose while still held.
        if y < ground-1 {
            x=t.landingX(near:x,radius:radius);y=t.support(x,radius)
            released=MotionFrame(frame());fallStart=y;set(.fall,0.32);carriedPointer=nil
            pickupBand=CGRect(x:x-unit/2,y:y,width:unit,height:unit)
        }
    }
    func release(at point:CGPoint) {
        guard let down=pressurePoint else{return}
        pressurePoint=nil;lastDrag=nil;carriedPointer=nil
        if pose == .carried {
            x=surface.terrain.landingX(near:x,radius:radius)
            let target=surface.terrain.support(x,radius)
            released=MotionFrame(frame())
            fallStart=max(y,target);y=fallStart
            set(.fall,clamp(sqrt(max(0,fallStart-target)/800),0.18,1.2));render()
        } else if let response=petting.release(), isGrounded {
            respond(response,at:down);render()
        } else if pendingGentleEncounter && !draggedPress {
            attention?.recordGentleEncounter()
        }
        pendingGentleEncounter = false
    }

    private func respond(_ response:TouchResponse,at point:CGPoint,area:TouchArea? = nil) {
        let initial=MotionFrame(frame())
        if response == .leave {
            pressurePoint=nil;lastDrag=nil;heartAge=nil;blinkAge=nil
            let sleepy=pose.asleep || pose == .backLook || (pose == .look && restShape.asleep)
            let terrain=surface.terrain
            direction=point.x<x ? 1:-1
            let ahead=terrain.bound(x+direction*unit*0.8,radius:radius)
            if abs(ahead-x)<unit*0.3 {direction = -direction}
            walkStart=0
            change(to:.walking,for:2.6,from:initial,maximumFrameTime:sleepy ? 0.20:0.11)
            return
        }
        if response == .notice, pose == .prone, attention != nil {
            if area == .head || area == .back { considerAttention(to: point, touched: true) }
            return
        }
        if pose.asleep || [.prone, .side, .loaf].contains(pose) {
            interruptedRest = (pose, age, duration, nextBlink, nextGroom, nextTwitch)
        } else if pose == .grooming {
            interruptedRest = (.prone, 0, max(1, restAtGroomStart - age),
                               .random(in: 4...13), .random(in: 180...360), .infinity)
        } else if response == .enjoy && (pose == .look || pose == .backLook) {
            interruptedRest?.age += age
        }
        if response == .enjoy {
            let wasProne = pose == .prone
            enjoy(from:initial)
            pendingGentleEncounter = wasProne
            return
        }
        switch pose {
        case .sleepBack:
            play(.backLook,from:initial,toward:MotionFrame(art.cel("back",2)),home:initial,hold:wakeHold,frameTime:0.055)
        case .side,.loaf,.sleepSide,.sleepLoaf:
            restShape=pose
            let key=(pose == .side || pose == .sleepSide) ? "side":"loaf"
            let peak=pose.asleep ? 0:1
            let home=MotionFrame(art.cel(key,pose.asleep ? 2:0))
            play(.look,from:initial,toward:MotionFrame(art.cel(key,peak)),home:home,hold:pose.asleep ? wakeHold:0.24,frameTime:0.07)
        case .grooming:
            restShape = .prone
            let home = neutralFrame(for: .prone)
            play(.look, from: initial, toward: home, home: home, hold: 0.55, frameTime: 0.07)
        case .prone where response == .notice:
            restShape = .prone
            play(.look,from:initial,toward:MotionFrame(art.cel("settle",7)),home:initial,hold:0.23,frameTime:0.07)
        case .sitting,.prone:
            blinkAge=0
            duration=max(duration,age+0.65)
        default: break
        }
    }
    private func enjoy(from initial:MotionFrame) {
        let rest=pose == .look ? restShape:pose
        let peak,home:MotionFrame
        let action:Pose
        switch rest {
        case .sleepBack,.backLook:
            action = .backLook
            peak=MotionFrame(art.cel("back",2));home=MotionFrame(art.cel("turn",5))
        case .side,.sleepSide,.loaf,.sleepLoaf:
            action = .look;restShape=rest
            let key=(rest == .side || rest == .sleepSide) ? "side":"loaf"
            peak=MotionFrame(art.cel(key,2));home=MotionFrame(art.cel(key,rest.asleep ? 2:0))
        default:
            action = .look
            // Stop a walking cat in its current facing before its slow blink.
            if rest == .walking {
                restShape = .walking;peak=MotionFrame(art.cel("settle",0),initial.mirrored)
                home=MotionFrame(art.cel("walk",0),initial.mirrored)
            } else {
                restShape = (rest == .prone || rest == .grooming) ? .prone:.sitting
                home=neutralFrame(for:restShape);peak=home
            }
        }
        let waking=rest == .sleepSide || rest == .sleepLoaf
        let awake=waking ? MotionFrame(art.cel(rest == .sleepSide ? "side":"loaf",0)):nil
        let sequence=Reaction(library:motions,from:initial,toward:peak,returningTo:home,
                              hold:action == .backLook ? wakeHold:0.55,frameTime:0.06,
                              awakeAfter:awake.map {($0,wakeHold)})
        set(action,sequence.duration)
        reaction=sequence;blinkAge=nil
        enjoymentAt=sequence.peakTime
    }
    private func neutralFrame(for posture:Pose)->MotionFrame {
        switch posture {
        case .side: return MotionFrame(art.cel("side",0))
        case .loaf: return MotionFrame(art.cel("loaf",0))
        case .prone, .grooming: return MotionFrame(art.cel("settle",8))
        default: return MotionFrame(art.cel("settle",0))
        }
    }
    private func play(_ action:Pose,from initial:MotionFrame,toward peak:MotionFrame,home:MotionFrame,hold:Double,frameTime:Double=0.105) {
        let sequence=Reaction(library:motions,from:initial,toward:peak,returningTo:home,hold:hold,frameTime:frameTime)
        set(action,sequence.duration)
        reaction=sequence
    }
    private func beginLook(hold:Double) {
        let initial=MotionFrame(frame())
        if pose == .sleepBack {
            play(.backLook,from:initial,toward:MotionFrame(art.cel("back",2)),
                 home:initial,hold:hold)
        } else {
            restShape=pose == .sleepSide ? .side:.loaf
            let awake=neutralFrame(for:restShape)
            play(.look,from:initial,toward:awake,home:awake,hold:hold)
        }
    }
    private func tick() {
        let now=ProcessInfo.processInfo.systemUptime
        let dt=min(0.10,max(0,now-lastTime));lastTime=now
        if now>=inspectAt {refreshScreen(at:nil);inspectAt=now+(pose == .walking || pose == .hop || pose == .carried ? 0.25:0.8)}
        if pressurePoint != nil && NSEvent.pressedMouseButtons & 1 == 0 {release(at:NSEvent.mouseLocation)}
        step(dt, pointer: NSEvent.mouseLocation, pointerButtonDown: NSEvent.pressedMouseButtons != 0)
        render()
    }
    private var facePoint: CGPoint {
        guard let draw = view.drawing, let eyes = draw.cel.eyeCenters, eyes.count == 2 else {
            return CGPoint(x: x, y: y + unit * 0.35)
        }
        let center = CGPoint(x: (eyes[0].x + eyes[1].x) / 2,
                             y: CGFloat(draw.image.height) - (eyes[0].y + eyes[1].y) / 2).applying(draw.transform)
        return CGPoint(x: draw.frame.minX + center.x, y: draw.frame.minY + center.y)
    }
    private func directionToPointer(_ point: CGPoint) -> CGPoint {
        let head = facePoint
        return CGPoint(x: clamp((point.x - head.x) / (unit * 0.38), -1, 1),
                       y: clamp((point.y - head.y) / (unit * 0.38), -1, 1))
    }
    private func considerAttention(to point: CGPoint, touched: Bool) {
        guard let attention else { return }
        let head = facePoint
        let distance = hypot(point.x - head.x, point.y - head.y) / unit
        let decision = attention.decide(touch: touched, disturbance: disturbance,
                                        restDrive: art.behaviorModel?.restDrive(after: age) ?? 0.8,
                                        elapsed: age, nearness: clamp(1 - distance / 1.6, 0, 1),
                                        approachSpeed: touched ? 0 : approach.closingSpeed,
                                        draw: attentionDraw())
        if decision.looks {
            attentionRemaining = decision.hold
            gazeTarget = directionToPointer(point)
            if art.eyeResponseModel != nil {
                if eyeMovement == nil && socialBlinkCooldown <= 0 {
                    scheduleEyeMovement(.neutral, window: decision.hold)
                }
            } else if touched && hypot(gazeTarget.x, gazeTarget.y) < 0.25 { blinkAge = 0 }
        }
    }
    var canReceiveSlowBlink: Bool {
        pose == .prone && art.eyeResponseModel != nil && pressurePoint == nil && socialBlinkCooldown <= 0 &&
            eyeMovement?.lid(at: age) == nil
    }
    func offerSlowBlink() {
        guard canReceiveSlowBlink else { return }
        // An explicit social cue gets one opportunity, even if the sampled
        // movement falls outside the window and Dada keeps resting.
        scheduleEyeMovement(.slowBlink, window: 8)
        socialBlinkCooldown = 8
    }
    private func scheduleEyeMovement(_ condition: EyeResponseModel.Condition, window: Double) {
        eyeMovement = art.eyeResponseModel?.firstMovement(condition, at: age, window: window,
                                                          timeDraw: attentionDraw(), kindDraw: attentionDraw())
    }
    private func stepAttention(_ dt: Double, pointer: CGPoint?) {
        disturbance *= exp(-dt / 4)
        guard pose == .prone, attention != nil else { return }
        if let point = pointer, pressurePoint == nil {
            let head = facePoint
            let distance = hypot(point.x - head.x, point.y - head.y) / unit
            let entered = approach.observe(distance: distance, dt: dt)
            if entered && !isAttending { considerAttention(to: point, touched: false) }
            if isAttending && distance < 1.6 { gazeTarget = directionToPointer(point) }
        }
        attentionRemaining = max(0, attentionRemaining - dt)
        if !isAttending { gazeTarget = .zero }
        guard gaze != gazeTarget else { return }
        let fraction = 1 - exp(-dt * (isAttending ? 14 : 9))
        gaze.x += (gazeTarget.x - gaze.x) * fraction
        gaze.y += (gazeTarget.y - gaze.y) * fraction
        if hypot(gazeTarget.x - gaze.x, gazeTarget.y - gaze.y) < 0.012 { gaze = gazeTarget }
    }
    private func plannedInvitation(toward target: CGFloat, heading: CGFloat, from start: MotionFrame) -> InvitedWalk? {
        let terrain = surface.terrain
        let onDock = y > terrain.floor + 1
        func limit(_ sign: CGFloat) -> CGFloat {
            let edge = terrain.turnX(from: x, delta: sign * terrain.screen.width, radius: radius, onDock: onDock)
            return (edge - x) / unit
        }
        let bounds = limit(-1)...limit(1)
        let walking = MotionFrame(art.cel("walk", 0), heading > 0)
        // Shifting weight to stand up or lie down also moves the body. Reserve
        // every support change, including one that reverses before the last cel.
        func travel(_ route: [MotionFrame]) -> (end: CGFloat, low: CGFloat, high: CGFloat) {
            var end: CGFloat = 0, low: CGFloat = 0, high: CGFloat = 0
            for (a, b) in zip(route, route.dropFirst()) {
                end += motions.step(from: a, to: b)
                low = min(low, end)
                high = max(high, end)
            }
            return (end, low, high)
        }
        let rise = travel(motions.path(from: start, to: walking))
        guard bounds.contains(rise.low), bounds.contains(rise.high) else { return nil }
        let settle = travel(motions.path(from: walking, to: neutralFrame(for: .prone)))
        let room = heading > 0 ? bounds.upperBound - rise.end - settle.high
                               : rise.end + settle.low - bounds.lowerBound
        let requested = heading * ((target - x) / unit - rise.end)
        let gait = ApproachGait(cycle: art.gait, maximumDistance: min(room, requested), endingAt: 0)
        let stop = rise.end + heading * gait.plannedDistance
        guard !gait.isFinished, bounds.contains(stop + settle.low), bounds.contains(stop + settle.high) else { return nil }
        let pace = art.gait.speed * clamp(0.72 + 0.16 * gait.plannedDistance, 0.72, 1.08)
        return InvitedWalk(gait: gait, pace: pace, restRemaining: remainingPoseTime)
    }
    private func interruptInvitation() {
        invitationGesture = InvitationGesture()
        if let remaining = invitedWalk?.restRemaining ?? arrival?.invitation?.restRemaining {
            change(to: .prone, for: remaining)
        }
    }
    private func considerInvitation(_ dt: Double, pointer: CGPoint?, buttonDown: Bool) {
        guard pose == .prone, let invitation, let point = pointer, !buttonDown, pressurePoint == nil,
              surface.terrain.screen.contains(point) else {
            invitationGesture = InvitationGesture()
            return
        }
        let head = facePoint
        let offset = CGPoint(x: (point.x - head.x) / unit, y: (point.y - head.y) / unit)
        guard let cue = invitationGesture.observe(relative: offset, dt: dt),
              invitation.accepts(cue, restDrive: art.behaviorModel?.restDrive(after: age) ?? 0.8,
                                 disturbance: disturbance, familiarity: attention?.familiarEncounters ?? 0,
                                 draw: attentionDraw()) else { return }
        // Stop with the walking face short of the pointer. The front-facing rest
        // and the two walking orientations have different head-to-anchor offsets.
        let heading: CGFloat = cue.offset.x < 0 ? -1 : 1
        let walkingCel = art.cel("walk", 0)
        guard let layout = walkingCel.touchLayout else { return }
        let walkingHead = walkingCel.projected(CGPoint(x: layout.head.x * walkingCel.sourceSize.width,
                                                      y: layout.head.y * walkingCel.sourceSize.height))
        let headReach = abs(walkingCel.anchorX - walkingHead.x) * walkingCel.scale
        let goal = point.x - heading * (headReach + 0.10) * unit
        let start = MotionFrame(frame())
        guard let plan = plannedInvitation(toward: goal, heading: heading, from: start) else {
            attentionRemaining = 0.8
            gazeTarget = directionToPointer(point)
            return
        }
        direction = heading
        change(to: .walking, for: .infinity, from: start, invitation: plan)
    }
    private func advanceInvitedWalk(_ dt: Double, walk: InvitedWalk) {
        var next = walk
        let delta = next.gait.advance(dt, speed: next.pace) * unit * direction
        let terrain = surface.terrain
        let safe = terrain.turnX(from: x, delta: delta, radius: radius, onDock: y > terrain.floor + 1)
        guard abs(safe - (x + delta)) < 0.001 else {
            interruptInvitation()
            return
        }
        x = safe
        invitedWalk = next
        if next.gait.isFinished { change(to: .prone, for: next.restRemaining) }
    }
    func step(_ dt:Double, pointer: CGPoint? = nil, pointerButtonDown: Bool = false) {
        socialBlinkCooldown = max(0, socialBlinkCooldown - dt)
        stepAttention(dt, pointer: pointer)
        considerInvitation(dt, pointer: pointer, buttonDown: pointerButtonDown)
        if let elapsed=heartAge {heartAge=elapsed+dt < 0.78 ? elapsed+dt:nil}
        if let elapsed=blinkAge {blinkAge=elapsed+dt < 0.54 ? elapsed+dt:nil}
        if let response=petting.advance(dt), let down=pressurePoint, isGrounded {respond(response,at:down)}
        if draggedPress && pressurePoint != nil && isGrounded {return}
        let previousAge=age
        age += dt
        if age>nextTwitch+0.38 {nextTwitch=age + .random(in:14...38)}
        let t=surface.terrain
        if let reaction {
            let dx=(reaction.travel(at:age)-reaction.travel(at:previousAge))*unit
            if dx != 0 {x=t.turnX(from:x,delta:dx,radius:radius,onDock:y>t.floor+1)}
        }
        switch pose {
        case .prone:
            if let movement = eyeMovement, age >= movement.onset + movement.duration { eyeMovement = nil }
            if age >= nextBlink + 0.27 { nextBlink = age + .random(in: 4...15) }
            if age >= nextGroom, age < duration, pressurePoint == nil, !isAttending, eyeMovement == nil { groomNow(showcase: false) }
        case .carried: followHand()
        case .walking:
            if let walk = invitedWalk {
                advanceInvitedWalk(dt, walk: walk)
                break
            }
            let previous=art.gait.sample(time:previousAge,speed:walkRate,startingAt:walkStart)
            let current=art.gait.sample(time:age,speed:walkRate,startingAt:walkStart)
            let d=(current.distance-previous.distance)*unit
            guard d>0 else {break}
            let next=t.bound(x+direction*d,radius:radius)
            if let j=t.crossing(from:x,to:next,direction:direction,radius:radius,onDock:y>t.floor+3) {
                let dock=t.dock!
                let edge=(direction>0) == j.descending ? dock.maxX:dock.minX
                let crossing=DockMotion(hop:j,edge:edge,unit:unit,art:art,entryStride:previous.index)
                set(.hop,crossing.duration)
                journey=crossing
            } else {
                let supported=t.landingX(near:next,radius:radius)
                if abs(supported-x)<0.0001 {change(to:.sitting,for:1.3)}
                else {x=supported;y=t.support(x,radius)}
            }
        case .hop:
            if let j=journey {
                let p=j.position(age/duration)
                x=p.x
                y=p.y
            }
        case .fall:
            let target=t.support(x,radius), f=min(1,age/duration)
            y=max(target,fallStart+(target-fallStart)*f*f)
        default:break
        }
        if age>=duration {advanceState()}
    }
    func frame()->(Cel,Bool) {
        if let reaction {return reaction.frame(at:age)}
        let i:Int, key:String
        let flip:Bool
        switch pose {
        case .sitting: (key,i)=("settle",0);flip=false
        case .changing, .grooming: preconditionFailure("缺少过渡帧")
        case .prone: (key,i)=("settle",8);flip=false
        case .side,.loaf:
            key=pose == .side ? "side":"loaf";i=age.truncatingRemainder(dividingBy:5.3)>5.0 ? 1:0;flip=false
        case .sleepSide,.sleepLoaf:
            (key,i)=(pose == .sleepSide ? "side":"loaf",2);flip=false
        case .sleepBack: (key,i)=("turn",5);flip=false
        case .backLook: (key,i)=("back",2);flip=false
        case .look: (key,i)=(restShape == .side ? "side":"loaf",age<0.15 ? 1:0);flip=false
        case .walking:
            key="walk"
            i=invitedWalk?.gait.frameIndex ?? art.gait.sample(time:age,speed:walkRate,startingAt:walkStart).index
            flip=direction>0
        case .hop:
            return (journey!.frame(age/duration),direction>0)
        case .fall:
            let t=age/duration
            if t<0.09, let released {return (released.cel,released.mirrored)}
            (key,i)=("release",min(3,Int(t*4)));flip=false
        case .carried:(key,i)=("carry",[0,1,2,1][Int(age/0.3)%4]);flip=false

        }
        return (art.cel(key,i),flip)
    }
    func render() {
        let (cel,flip)=frame()
        let k=unit*cel.scale
        let sleeping = pose.asleep || pose == .prone ? SleepPhase(age: age, twitchStart: nextTwitch, awake: pose == .prone) : nil
        let grounded=isGrounded || pose == .hop || (pose != .carried && y<=surface.terrain.support(x,radius)+0.001)
        if let onset=enjoymentAt,age>=onset {
            let placement=SpriteDrawing(cel:cel,grounded:grounded,mirror:flip,feet:CGPoint(x:x,y:y),k:k,stretch:1,backing:screen.backingScaleFactor,screenFloor:surface.terrain.floor)
            if let head=placement.headTop {
                heartOrigin=CGPoint(x:placement.frame.minX+head.x,y:placement.frame.minY+head.y)
                heartAge=0
                if cel.eyeCenters != nil {blinkAge=0}
            }
            enjoymentAt=nil
        }
        let lean=heartAge.map {1-0.024*pow(sin(.pi*min(1,$0/0.58)),2)} ?? 1
        let draw=SpriteDrawing(cel:cel,grounded:grounded,mirror:flip,feet:CGPoint(x:x,y:y),
                               k:k,stretch:lean,backing:screen.backingScaleFactor,
                               headroom:heartAge == nil ? 0:clamp(unit*0.105,8,31)*2.65,screenFloor:surface.terrain.floor,sleepPhase:sleeping,gaze:gaze)
        let rect=draw.frame
        let origin=CGPoint(x:heartOrigin.x-rect.minX,y:heartOrigin.y-rect.minY)
        let heart=heartAge.flatMap { draw.heart(progress:$0/0.78,unit:unit,origin:origin) }
        let idleBlink = age - nextBlink
        let spontaneousLid: Int? = (0..<0.27).contains(idleBlink) && art.eyelids.count == 2
            ? (idleBlink < 0.07 || idleBlink > 0.18 ? 0 : 1) : nil
        let lid=blinkAge.flatMap { elapsed -> Int? in
            guard cel.eyeCenters != nil, art.eyelids.count==2 else {return nil}
            return elapsed<0.07 || elapsed>0.44 ? 0:1
        }
        ?? eyeMovement?.lid(at: age) ?? spontaneousLid
        let redraw=view.drawing?.gaze != draw.gaze || view.drawing?.sleepPhase != sleeping || heart != view.heart || lid != shownLid || view.drawing?.cel !== cel || view.drawing?.transform != draw.transform ||
                   view.drawing?.grounded != grounded || rect.size != panel.frame.size
        view.heart=heart;view.eyelids=lid.map {art.eyelids[$0]};shownLid=lid
        view.drawing=draw
        if rect != panel.frame {panel.setFrame(rect,display:false)}
        if redraw {view.needsDisplay=true}
        let p=NSEvent.mouseLocation
        let local=CGPoint(x:p.x-rect.minX,y:p.y-rect.minY)
        let ignore=pressurePoint == nil && !draw.contains(local)
        if panel.ignoresMouseEvents != ignore {panel.ignoresMouseEvents=ignore}
    }
}
