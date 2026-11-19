import AppKit

enum Pose: Equatable {
    case changing, sitting, prone, side, loaf, sleepSide, sleepBack, sleepLoaf
    case look, backLook, walking, hop, fall, carried
    var asleep:Bool { self == .sleepSide || self == .sleepBack || self == .sleepLoaf }
}
final class PetController {
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
    private var arrival:(pose:Pose, duration:Double)?
    private var restShape:Pose = .prone

    init(art:PetArt,screen:NSScreen) {
        self.art=art;self.screen=screen;motions=MotionLibrary(art)
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
        scale=clamp(new,0.55,2)
        if persist {UserDefaults.standard.set(Double(scale),forKey:"PetScale")}
        if pose == .hop || arrival?.pose == .hop {journey=nil;set(.walking,3)}
        if pose == .carried {followHand()}
        else {x=surface.terrain.landingX(near:x,radius:radius);reconcileHeight()}
        render()
    }
    private func set(_ p:Pose,_ seconds:Double) {
        arrival=nil;enjoymentAt=nil
        if p != .walking {walkStart=0}
        if p != .hop {journey=nil}
        reaction=nil
        if p == .carried || p == .fall || p == .hop {heartAge=nil;blinkAge=nil}
        nextTwitch=(p == .sleepSide || p == .sleepLoaf) ? .random(in:12...30):.infinity
        pose=p;duration=seconds;age=0
    }
    // Both ends belong to the actual playing clips, including when a menu action interrupts a turn.
    func change(to next:Pose, for seconds:Double, from initial:MotionFrame?=nil, maximumFrameTime:Double = .infinity) {
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
        if route.count==1 {set(next,seconds);return}
        let sequence=Reaction(library:motions,path:route,maximumFrameTime:maximumFrameTime)
        set(.changing,sequence.duration)
        reaction=sequence
        arrival=(next,seconds)
    }
    private func randomRest() {
        let roll=Int.random(in:0..<100)
        let traits=art.temperament
        let side=traits.backSleepWeight+traits.sideSleepWeight, loaf=traits.backSleepWeight+traits.sideSleepWeight+traits.loafSleepWeight
        if roll<traits.backSleepWeight {beginBackSleep()}
        else if roll<side {change(to:.sleepSide,for:traits.sleepTime)}
        else if roll<loaf {change(to:.sleepLoaf,for:traits.sleepTime)}
        else if roll<loaf+traits.quietRestWeight {change(to:[Pose.prone,.loaf,.side].randomElement()!,for:traits.restTime)}
        else {startWalk()}
    }
    private func beginBackSleep() {
        change(to:.sleepBack,for:art.temperament.sleepTime)
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
        switch pose {
        case .changing:
            if let arrival {set(arrival.pose,arrival.duration)}
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
        pressurePoint=point;lastDrag=point;draggedPress=false
        pickupBand=panel.frame.insetBy(dx:-max(6,unit*0.07),dy:0)
        if isGrounded, let response=petting.press(area,threshold:art.temperament.irritationThreshold,clickCount:clickCount) {
            respond(response,at:point)
        }
        render()
    }
    func drag(to p:CGPoint) {
        guard let down=pressurePoint else{return}
        let previous=lastDrag ?? down
        lastDrag=p
        if !draggedPress && hypot(p.x-down.x,p.y-down.y)>=4 {
            draggedPress=true;petting.cancelDrag()
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
        }
    }

    private func respond(_ response:TouchResponse,at point:CGPoint) {
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
        if response == .enjoy {enjoy(from:initial);return}
        switch pose {
        case .sleepBack:
            play(.backLook,from:initial,toward:MotionFrame(art.cel("back",2)),home:initial,hold:wakeHold,frameTime:0.055)
        case .side,.loaf,.sleepSide,.sleepLoaf:
            restShape=pose
            let key=(pose == .side || pose == .sleepSide) ? "side":"loaf"
            let peak=pose.asleep ? 0:1
            let home=MotionFrame(art.cel(key,pose.asleep ? 2:0))
            play(.look,from:initial,toward:MotionFrame(art.cel(key,peak)),home:home,hold:pose.asleep ? wakeHold:0.24,frameTime:0.07)
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
                restShape = rest == .prone ? .prone:.sitting
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
        case .prone: return MotionFrame(art.cel("settle",8))
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
        step(dt)
        render()
    }
    func step(_ dt:Double) {
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
        case .carried: followHand()
        case .walking:
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
        case .changing: preconditionFailure("缺少过渡帧")
        case .prone: (key,i)=("settle",8);flip=false
        case .side,.loaf:
            key=pose == .side ? "side":"loaf";i=age.truncatingRemainder(dividingBy:5.3)>5.0 ? 1:0;flip=false
        case .sleepSide,.sleepLoaf:
            (key,i)=(pose == .sleepSide ? "side":"loaf",2);flip=false
        case .sleepBack: (key,i)=("turn",5);flip=false
        case .backLook: (key,i)=("back",2);flip=false
        case .look: (key,i)=(restShape == .side ? "side":"loaf",age<0.15 ? 1:0);flip=false
        case .walking:(key,i)=("walk",art.gait.sample(time:age,speed:walkRate,startingAt:walkStart).index);flip=direction>0
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
        let sleeping=pose.asleep ? SleepPhase(age:age,twitchStart:nextTwitch):nil
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
                               headroom:heartAge == nil ? 0:clamp(unit*0.105,8,31)*2.65,screenFloor:surface.terrain.floor,sleepPhase:sleeping)
        let rect=draw.frame
        let origin=CGPoint(x:heartOrigin.x-rect.minX,y:heartOrigin.y-rect.minY)
        let heart=heartAge.flatMap { draw.heart(progress:$0/0.78,unit:unit,origin:origin) }
        let lid=blinkAge.flatMap { elapsed -> Int? in
            guard cel.eyeCenters != nil, art.eyelids.count==2 else {return nil}
            return elapsed<0.07 || elapsed>0.44 ? 0:1
        }
        let redraw=view.drawing?.sleepPhase != sleeping || heart != view.heart || lid != shownLid || view.drawing?.cel !== cel || view.drawing?.transform != draw.transform ||
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
