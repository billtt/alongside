import AppKit

enum Pose: Equatable {
    case changing, sitting, prone, side, loaf, sleepSide, sleepBack, sleepLoaf
    case look, backLook, walking, hop, fall, carried, paw, swat, nip
    var asleep:Bool { self == .sleepSide || self == .sleepBack || self == .sleepLoaf }
    var striking:Bool { self == .paw || self == .swat || self == .nip }
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
    var unit:CGFloat {(radius-2)/0.725}
    // All cels, including the extended swiping paw, fit this footprint.
    var radius:CGFloat {
        let terrain=surface.terrain
        let size=min(base*scale,terrain.screen.width*0.36,terrain.screen.height*0.51)
        return terrain.fittingRadius(size*0.725+2)
    }
    private var age:Double=0, duration:Double=0
    private var direction:CGFloat = -1
    private var journey:DockMotion?, fallStart:CGFloat=0
    private var pickupStart:MotionFrame?
    private let pickupDuration=0.18
    private var released:MotionFrame?
    private var pressurePoint:CGPoint?, lastDrag:CGPoint?, carriedPointer:CGPoint?
    private var draggedPress=false
    private var pickupBand=CGRect.zero
    private var reaction:Reaction?
    private var queuedTouches:[(action:Pose,point:CGPoint)] = []
    private var afterReaction:Pose = .sitting
    private var lastClick = -100.0, clickCount=0
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
        arrival=nil
        if p != .hop {journey=nil}
        if p != .carried {pickupStart=nil}
        reaction=nil
        queuedTouches.removeAll()
        pose=p;duration=seconds;age=0
    }
    // Both ends belong to the actual playing clips, including when a menu action interrupts a turn.
    func change(to next:Pose, for seconds:Double, from initial:MotionFrame?=nil, visual:MotionFrame?=nil) {
        let end:MotionFrame
        switch next {
        case .walking,.hop: end=MotionFrame(art.cel("walk",0),direction>0)
        case .sleepBack: end=MotionFrame(art.cel("turn",5))
        case .sleepSide: end=MotionFrame(art.cel("side",2))
        case .sleepLoaf: end=MotionFrame(art.cel("loaf",2))
        default: end=neutralFrame(for:next)
        }
        let start=initial ?? MotionFrame(frame())
        let route=motions.path(from:start,to:end)
        let current=visual ?? displayFrame()
        if route.count==1 && current==end {set(next,seconds);return}
        var sequence=Reaction(path:route.count==1 ? [start,end]:route)
        sequence.initialDisplay=current
        set(.changing,sequence.duration)
        reaction=sequence
        arrival=(next,seconds)
    }
    private func randomRest() {
        let roll=Int.random(in:0..<100)
        let traits=art.temperament
        let side=traits.backSleepWeight+traits.sideSleepWeight, loaf=traits.backSleepWeight+traits.sideSleepWeight+traits.loafSleepWeight
        if roll<traits.backSleepWeight {beginBackSleep()}
        else if roll<side {change(to:.sleepSide,for:.random(in:25...74))}
        else if roll<loaf {change(to:.sleepLoaf,for:.random(in:22...55))}
        else if roll<loaf+traits.quietRestWeight {change(to:Bool.random() ? .loaf:.side,for:.random(in:7...18))}
        else {startWalk()}
    }
    private func beginBackSleep() {
        change(to:.sleepBack,for:art.temperament.sleepTime)
    }
    func sleepNow() {
        guard isGrounded else{return}
        pressurePoint=nil
        beginBackSleep()
        render()
    }
    var isGrounded:Bool {pose != .carried && pose != .fall && pose != .hop}
    func startWalk(towardDock:Bool=false) {
        guard isGrounded else{return}
        let t=surface.terrain
        let initial=MotionFrame(frame()),visual=displayFrame()
        if let d=t.dock, towardDock || Int.random(in:0..<4) != 0 {
            if x < d.minX {direction=1}
            else if x>d.maxX {direction = -1}
            else {direction=x<d.midX ? -1:1}
        } else {direction=Bool.random() ? -1:1}
        // A manually requested walk lasts through the nearest reachable platform crossing.
        let destination:CGFloat
        if let d=t.dock {destination=direction > 0 ? (x<d.minX ? d.minX:d.maxX) : (x>d.maxX ? d.maxX:d.minX)}
        else {destination=x}
        let walkTime=towardDock ? min(120,max(6,Double(abs(destination-x)/(unit*art.temperament.walkSpeed))+5.0)) : .random(in:5...11)
        change(to:.walking,for:walkTime,from:initial,visual:visual)
        render()
    }
    private func advanceState() {
        switch pose {
        case .changing:
            if let arrival {set(arrival.pose,arrival.duration)}
        case .sitting: change(to:.prone,for:.random(in:4...9))
        case .walking: change(to:.sitting,for:1.4)
        case .look: set(restShape,4.2)
        case .backLook: set(.sleepBack,.random(in:20...55))
        case .paw,.swat,.nip:
            let waiting=queuedTouches
            set(afterReaction,afterReaction == .sitting ? 1.9:4.2)
            if let next=waiting.first {
                startReaction(next.action,at:next.point)
                queuedTouches=Array(waiting.dropFirst())
            }
        case .hop:
            if let j=journey {x=j.hop.endX;y=j.hop.endY}
            journey=nil
            set(.walking,.random(in:2.4...5.2))
        case .fall:
            y=surface.terrain.support(x,radius)
            change(to:.sitting,for:1.1)
        case .carried: break
        case .sleepBack:
            if Int.random(in:0..<3) == 0 {beginLook(hold:1.6)}
            else {change(to:.prone,for:4.0)}
        case .sleepSide,.sleepLoaf: beginLook(hold:2.0)
        case .loaf,.side,.prone: randomRest()
        }
    }
    func press(at point:CGPoint) {
        pressurePoint=point;lastDrag=point;draggedPress=false
        pickupBand=panel.frame.insetBy(dx:-max(6,unit*0.07),dy:0)
    }
    func drag(to p:CGPoint) {
        guard let down=pressurePoint else{return}
        let previous=lastDrag ?? down
        lastDrag=p
        if hypot(p.x-down.x,p.y-down.y)>=4 {draggedPress=true}
        if pose != .carried {
            let first=art.cel("carry",0)
            let liftHeight=max(down.y+max(6,unit*0.045), y + first.gripHeight*first.scale*unit)
            guard p.y>=liftHeight, p.y>previous.y else {return}
            let crossing=clamp((liftHeight-previous.y)/(p.y-previous.y),0,1)
            let atX=previous.x+(p.x-previous.x)*crossing
            guard pickupBand.minX...pickupBand.maxX ~= atX else {return}
            let visible=displayFrame()
            let from=visible.cel,k=from.scale*unit
            let anchor=from.anchorX+(atX-x)/k*(visible.mirrored ? -1:1)
            pickupStart=MotionFrame(Cel(pose:from.pose.reanchored(at:anchor,grip:(liftHeight-y)/k)),visible.mirrored)
            journey=nil;set(.carried,.infinity);clickCount=0
        }
        carriedPointer=p
        if !screen.frame.contains(p) {refreshScreen(at:p)}
        followHand()
        render()
    }
    private func followHand() {
        guard pose == .carried,let p=carriedPointer else{return}
        let cel=displayFrame().cel, k=cel.scale*unit
        x=p.x
        y=p.y-cel.gripHeight*k
        let t=surface.terrain
        let ground=t.support(x,radius)
        // If the hand lowers past touchdown, return to a supported pose while still held.
        if y < ground-1 {
            x=t.landingX(near:x,radius:radius);y=t.support(x,radius)
            released=displayFrame();fallStart=y;set(.fall,0.32);carriedPointer=nil
            pickupBand=CGRect(x:x-unit/2,y:y,width:unit,height:unit)
        }
    }
    func release(at point:CGPoint) {
        guard let down=pressurePoint else{return}
        pressurePoint=nil;lastDrag=nil;carriedPointer=nil
        if pose == .carried {
            x=surface.terrain.landingX(near:x,radius:radius)
            let target=surface.terrain.support(x,radius)
            released=displayFrame()
            fallStart=max(y,target);y=fallStart
            set(.fall,clamp(sqrt(max(0,fallStart-target)/800),0.18,1.2));render()
        } else if !draggedPress {touch(at:down)}
    }
    func touch(at point:CGPoint,now:Double=ProcessInfo.processInfo.systemUptime) {
        guard isGrounded else{return}
        clickCount=now-lastClick<1.8 ? clickCount+1:1;lastClick=now
        if clickCount<art.temperament.irritationThreshold && pose.asleep {
            beginLook(hold:2.1)
        } else {
            let action:Pose=clickCount<art.temperament.irritationThreshold ? .paw : (clickCount.isMultiple(of:2) ? .nip:.swat)
            if pose.striking {
                if action != .paw {queuedTouches.removeAll {$0.action == .paw}}
                if let index=queuedTouches.firstIndex(where:{$0.action==action}) {
                    queuedTouches[index].point=point
                } else if queuedTouches.count<2 {
                    queuedTouches.append((action,point))
                }
            } else {
                startReaction(action,at:point)
            }
        }
        render()
    }
    private func neutralFrame(for posture:Pose)->MotionFrame {
        switch posture {
        case .side: return MotionFrame(art.cel("side",0))
        case .loaf: return MotionFrame(art.cel("loaf",0))
        case .prone: return MotionFrame(art.cel("settle",8))
        default: return MotionFrame(art.cel("settle",0))
        }
    }
    private func play(_ action:Pose,from initial:MotionFrame,toward peak:MotionFrame,home:MotionFrame,hold:Double?=nil) {
        var sequence=Reaction(library:motions,from:initial,toward:peak,returningTo:home,action:action,hold:hold)
        sequence.initialDisplay=displayFrame()
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
    private func startReaction(_ action:Pose,at point:CGPoint) {
        let initial=MotionFrame(frame())
        switch pose {
        case .side,.loaf,.prone: afterReaction=pose
        case .sleepSide: afterReaction = .side
        case .sleepLoaf: afterReaction = .loaf
        case .look: afterReaction=restShape
        case .backLook,.sleepBack: afterReaction = .prone
        case .changing:
            afterReaction=motions.path(from:initial,to:neutralFrame(for:.sitting)).count<=5 ? .sitting:.prone
        default: afterReaction = .sitting
        }
        let key=action == .paw ? "paw" : (action == .swat ? "swat":"nip")
        let peak=motions.target(action:key,offset:CGPoint(x:point.x-x,y:point.y-y),unit:unit,
                                from:initial,resting:afterReaction != .sitting)
        play(action,from:initial,toward:peak,home:neutralFrame(for:afterReaction))
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
        if pressurePoint != nil && isGrounded {return}
        age += dt
        let t=surface.terrain
        switch pose {
        case .carried: followHand()
        case .walking:
            let next=t.bound(x+direction*unit*art.temperament.walkSpeed*dt,radius:radius)
            if let j=t.crossing(from:x,to:next,direction:direction,radius:radius,onDock:y>t.floor+3) {
                let edge=direction>0 ? t.dock!.maxX:t.dock!.minX
                let crossing=DockMotion(hop:j,edge:edge,unit:unit,art:art)
                change(to:.hop,for:crossing.duration)
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
                y=j.hop.descending ? p.y:max(p.y,t.support(x,radius))
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
        case .walking:(key,i)=("walk",Int(age/0.19)%6);flip=direction>0
        case .hop:
            return (journey!.frame(age/duration),direction>0)
        case .fall:
            let t=age/duration
            if t<0.09, let released {return (art.cel("release",0),released.mirrored)}
            (key,i)=("release",min(3,Int(t*4)));flip=false
        case .carried:(key,i)=("carry",[0,1,2,1][Int(max(0,age-pickupDuration)/0.3)%4]);flip=false
        case .paw,.swat,.nip:
            switch afterReaction {
            case .prone: (key,i)=("settle",8)
            case .side: (key,i)=("side",0)
            case .loaf: (key,i)=("loaf",0)
            default: (key,i)=("settle",0)
            }
            flip=false
        }
        return (art.cel(key,i),flip)
    }
    func displayFrame()->MotionFrame {
        if let reaction {return reaction.sample(at:age)}
        func cycle(_ key:String,_ indices:[Int],_ period:Double,_ flip:Bool,_ time:Double)->MotionFrame {
            let phase=time/period, i=Int(phase)%indices.count
            return MotionFrame(art.cel(key,indices[i]),flip).toward(
                MotionFrame(art.cel(key,indices[(i+1)%indices.count]),flip),phase-phase.rounded(.down))
        }
        switch pose {
        case .sleepSide,.sleepLoaf:
            let rest=art.cel(pose == .sleepSide ? "side":"loaf",2)
            return MotionFrame(rest.restingBreath(sin(age*2*Double.pi/4.7)))
        case .walking:return MotionFrame(art.walking(at:age),direction>0)
        case .carried:
            if let pickupStart, age<pickupDuration {
                return pickupStart.toward(MotionFrame(art.cel("carry",0)),age/pickupDuration)
            }
            return cycle("carry",[0,1,2,1],0.3,false,max(0,age-pickupDuration))
        case .hop:
            if let j=journey {return MotionFrame(j.sample(age/duration),direction>0)}
        case .fall:
            let t=clamp(age/duration,0,1)
            if t<0.25,let released {
                return released.toward(MotionFrame(art.cel("release",1)),t*4)
            }
            let f=min(t*4,3),i=Int(f)
            return MotionFrame(art.cel("release",i).toward(art.cel("release",min(i+1,3)),f-Double(i)))
        case .loaf,.side:
            let k=pose == .loaf ? "loaf":"side"
            let phase=age.truncatingRemainder(dividingBy:5.3)
            let blink=clamp(min((phase-4.92)/0.13,(5.3-phase)/0.12),0,1)
            return MotionFrame(art.cel(k,0).toward(art.cel(k,1),blink))
        default:break
        }
        return MotionFrame(frame())
    }

    func render() {
        let visual=displayFrame(),cel=visual.cel,flip=visual.mirrored
        let k=unit*cel.scale
        let grounded=isGrounded || (pose == .hop && journey?.hop.descending == true) || (pose != .carried && y<=surface.terrain.support(x,radius)+0.001)
        let draw=SpriteDrawing(cel:cel,grounded:grounded,mirror:flip,feet:CGPoint(x:x,y:y),
                               k:k,stretch:1,backing:screen.backingScaleFactor)
        let rect=draw.frame
        let redraw=view.drawing?.cel !== cel || view.drawing?.transform != draw.transform ||
                   view.drawing?.grounded != grounded || rect.size != panel.frame.size
        view.drawing=draw
        if rect != panel.frame {panel.setFrame(rect,display:false)}
        if redraw {view.needsDisplay=true}
        let p=NSEvent.mouseLocation
        let local=CGPoint(x:p.x-rect.minX,y:p.y-rect.minY)
        let ignore=pressurePoint == nil && !draw.contains(local)
        if panel.ignoresMouseEvents != ignore {panel.ignoresMouseEvents=ignore}
    }
}
