import AppKit

private func verifyGroundInk(_ art:PetArt) throws {
    let view=PetView()
    for (name,frames) in art.clips where name != "carry" {
        for (index,cel) in frames.enumerated() where name != "leap" || index != 1 {
            for (size,backing) in [(97.0,1.0),(178.0,2.0),(356.0,2.0)] {
                let draw=SpriteDrawing(cel:cel,grounded:true,mirror:backing==2,feet:CGPoint(x:500,y:79),
                                       k:size*cel.scale,stretch:1.009,backing:backing)
                let w=Int(ceil(draw.frame.width*backing))
                guard let ctx=CGContext(data:nil,width:w,height:1,bitsPerComponent:8,bytesPerRow:w*4,
                                        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),
                      let data=ctx.data else {throw ArtError.invalid("接触线采样")}
                ctx.scaleBy(x:backing,y:backing)
                ctx.translateBy(x:0,y:draw.frame.minY-79)
                view.frame=CGRect(origin:.zero,size:draw.frame.size);view.drawing=draw
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current=NSGraphicsContext(cgContext:ctx,flipped:false)
                view.draw(view.bounds)
                NSGraphicsContext.restoreGraphicsState()
                let row=data.assumingMemoryBound(to:UInt8.self)
                guard draw.frame.minY<=79, (0..<w).filter({row[$0*4+3]>=160}).count>=max(1,w/65) else {
                    throw ArtError.invalid("底部缺少实体像素 \(name)-\(index) 尺寸 \(size)")
                }
            }
        }
    }
}

// Exercises the packaged program, real assets and the screen's actual terrain without taking over the pointer.
func verifyApp() throws {
    func require(_ ok:Bool,_ what:String)throws {if !ok {throw ArtError.invalid(what)}}
    func waitFor(_ pet:PetController,_ target:Pose) throws {
        for _ in 0..<450 {
            if pet.pose==target {return}
            pet.step(1/30)
        }
        throw ArtError.invalid("未完成过渡至 "+String(describing:target))
    }
    let dockDetector=DockDetector()
    guard let resources=Bundle.main.resourceURL,
          let screen=NSScreen.screens.first(where:{dockDetector.read($0).terrain.dock != nil}) ?? NSScreen.main
    else {throw ArtError.invalid("需要桌面会话")}
    let art=try PetArt(root:resources.appendingPathComponent("Pets/Dada"))
    try verifyPetting(art)
    try verifyGroundInk(art)
    let pet=PetController(art:art,screen:screen)
    func pointOn(_ pet:PetController,_ area:TouchArea) throws -> CGPoint {
        pet.render()
        guard let draw=pet.view.drawing else {throw ArtError.invalid("缺少角色画面")}
        // Use an opaque point inside the requested region, as real mouse-downs do.
        for fy in 1..<20 {
            for fx in 1..<20 {
                let pixel=CGPoint(x:CGFloat(fx*draw.image.width)/20,y:CGFloat(fy*draw.image.height)/20)
                let p=pixel.applying(draw.transform)
                if draw.touchArea(at:p)==area || (draw.cel.touchLayout == nil && draw.contains(p)) {return CGPoint(x:draw.frame.minX+p.x,y:draw.frame.minY+p.y)}
            }
        }
        throw ArtError.invalid("找不到触摸区域")
    }
    func lift(to point:CGPoint) throws {
        pet.render()
        let down=try pointOn(pet,.head)
        pet.press(at:down)
        let grip=art.cel("carry",0)
        pet.drag(to:CGPoint(x:pet.x,y:max(down.y+pet.unit*0.1,pet.y+grip.gripHeight*grip.scale*pet.unit)+5))
        try require(pet.pose == .carried,"后颈到达鼠标后拎起")
        pet.drag(to:point)
    }
    print("Displays",NSScreen.screens.count)
    for s in NSScreen.screens {
        let sf=pet.detector.read(s);print("Display",s.frame,"Dock",sf.terrain.dock as Any,sf.source)
    }
    print("Unit",pet.unit,"start",pet.x,pet.y,"level",pet.panel.level.rawValue)
    try require(pet.panel.level.rawValue>NSWindow.Level.floating.rawValue && !pet.panel.canBecomeKey,"宠物窗口层级")
    try require(!pet.panel.isOpaque && !pet.panel.hasShadow,"透明窗口")
    pet.sleepNow();try waitFor(pet,.sleepBack);try require(pet.pose == .sleepBack,"背睡")
    let click=try pointOn(pet,.back)
    let asleep=MotionFrame(pet.frame())
    pet.press(at:click)
    try require(pet.pose == .backLook && pet.view.heart == nil && MotionFrame(pet.frame())==asleep,"按下即回应")
    pet.release(at:click);pet.step(0.12);pet.render()
    let waking=MotionFrame(pet.frame())
    let second=try pointOn(pet,.head)
    pet.press(at:second,clickCount:2);pet.release(at:second)
    try require(waking != asleep && MotionFrame(pet.frame())==waking && pet.pose == .backLook,"双击合并为同一次回头")
    for _ in 0..<10 {pet.step(1/30);pet.render()}
    try require(pet.view.heart != nil && pet.view.eyelids != nil,"背睡双击在回头眯眼时冒爱心")
    try waitFor(pet,.sleepBack)
    pet.startWalk(towardDock:true)
    try waitFor(pet,.walking)
    let ground=pet.surface.terrain
    try require(ground.floor==ground.screen.minY,"屏幕底边")
    if let d=ground.dock {try require(ground.support(d.midX,pet.radius)==d.maxY,"Dock 上沿")}
    let high=CGPoint(x:ground.screen.midX,y:ground.screen.midY)
    let down=try pointOn(pet,.back)
    pet.press(at:down);pet.drag(to:CGPoint(x:down.x+9,y:down.y))
    pet.step(1.5);pet.release(at:down)
    try require(pet.pose == .walking,"横拖取消长按计时，保留步态")
    try lift(to:high)
    for _ in 0..<12 {
        pet.step(0.12);pet.render()
        let cel=pet.frame().0
        guard let drawn=pet.view.drawing else {throw ArtError.invalid("悬提画面")}
        let grip=CGPoint(x:cel.anchorX,y:cel.gripHeight).applying(drawn.transform)
        try require(hypot(grip.x+drawn.frame.minX-high.x,grip.y+drawn.frame.minY-high.y)<0.01,"每帧后颈对准鼠标")
    }
    try require(pet.pose == .carried && pet.y>ground.floor+20,"拎起")
    pet.release(at:high);try require(pet.pose == .fall,"松手")
    for _ in 0..<44 {pet.step(1/30)}
    try require(abs(pet.y-ground.support(pet.x,pet.radius))<1,"落回有效平台")
    for sz in [0.55,1.0,2.0] {
        pet.resize(sz,persist:false);pet.render()
        try require(ground.screen.contains(pet.panel.frame),"尺寸改变时仍在屏内")
    }
    pet.resize(1,persist:false)
    // Drop the cat at the actual corners, then let it change silhouette in place.
    if let dock=ground.dock {
        for scale in [0.55,1.0,2.0] {
            pet.resize(scale,persist:false)
            guard ground.dockStandingRange(radius:pet.radius) != nil else {continue}
            for edge in [dock.minX,dock.maxX] {
                let drop=CGPoint(x:edge,y:ground.screen.midY)
                try lift(to:drop);pet.release(at:drop)
                for _ in 0..<40 {pet.step(1/30)}
                pet.sleepNow()
                for _ in 0..<400 where pet.pose != .sleepBack {
                    pet.step(1/30);pet.render()
                    let body=pet.panel.frame
                    let corner=dock.height*0.35
                    let exposed=max(0,dock.minX+corner-body.minX,body.maxX-(dock.maxX-corner))
                    try require(pet.y==dock.maxY && exposed<=body.width*0.10+1,"Dock 边缘换姿势时身体仍有支撑")
                }
                try require(pet.pose == .sleepBack,"在 Dock 两端背睡")
            }
        }
        pet.resize(1,persist:false)
    }
    // Verify actual autonomous walking both off and back onto the real Dock when it is visible.
    if let d=ground.dock, d.minX-ground.screen.minX>2*pet.radius+3 {
        for startingX in [d.minX+pet.radius*0.4,d.minX-pet.radius-8] {
            let drop=CGPoint(x:startingX,y:ground.screen.midY)
            try lift(to:drop);pet.release(at:drop)
            for _ in 0..<42 {pet.step(1/30)}
            pet.startWalk(towardDock:true)
            var tookOff=false,landed=false
            for _ in 0..<1800 {
                pet.step(1/60)
                if pet.pose == .hop {tookOff=true}
                if tookOff && pet.pose == .walking {landed=true;break}
                if pet.pose == .hop && startingX>d.minX {try require(pet.y<=d.maxY && pet.y>=ground.floor,"下跳高度")}
                else if pet.pose != .hop {try require(pet.y+0.01>=ground.support(pet.x,pet.radius),"穿过 Dock")}
            }
            try require(tookOff && landed,"真实 Dock 跳跃")
        }
    }
    if let other=NSScreen.screens.first(where:{$0.frame != screen.frame}) {
        let point=CGPoint(x:other.frame.midX,y:other.frame.midY)
        try lift(to:point);pet.release(at:point)
        for _ in 0..<50 {pet.step(1/30)}
        pet.render()
        try require(pet.screen.frame==other.frame && other.frame.contains(pet.panel.frame),"跨屏拖放")
        try require(abs(pet.y-pet.surface.terrain.support(pet.x,pet.radius))<1,"副屏落点")
    }
    try verifyLocomotion(art)
    let frame=art.cel("settle",0),h=frame.groundedImage.height
    try require(!frame.contains(.zero,height:h) && frame.contains(CGPoint(x:frame.image.width/2,y:h/2),height:h),"透明像素点击穿透")
    let gestures=PetController(art:art,screen:screen)
    let head=try pointOn(gestures,.head)
    gestures.press(at:head)
    try require(gestures.pose == .sitting && gestures.view.heart == nil,"坐姿原地眯眼")
    gestures.release(at:head);gestures.step(0.10)
    gestures.press(at:head,clickCount:2);gestures.release(at:head)
    try require(gestures.view.heart != nil && gestures.view.eyelids != nil,"坐姿双击时爱心和眯眼同时出现")
    gestures.step(0.10)
    gestures.press(at:head);gestures.release(at:head)
    try require(gestures.pose == .changing && gestures.view.heart == nil,"连点后起身避开")
    try waitFor(gestures,.walking)
    let fleeX=gestures.x
    for _ in 0..<15 {gestures.step(1/30)}
    try require(gestures.x != fleeX || gestures.pose == .hop || gestures.pose == .changing,"走开时有实际位移或台阶过渡")
    for track in art.transitions {
        let start=MotionFrame(track.frames.first!),end=MotionFrame(track.frames.last!,track.turnsAround)
        try require(gestures.motions.path(from:start,to:end).count==track.frames.count,"过渡经过整条手绘帧序列")
    }
    gestures.sleepNow();try waitFor(gestures,.sleepBack)
    gestures.step(4)
    func boundsOfInk(_ draw:SpriteDrawing)->CGRect {
        CGRect(x:0,y:0,width:draw.image.width,height:draw.image.height).applying(draw.transform)
            .offsetBy(dx:draw.frame.minX,dy:draw.frame.minY)
    }
    // Check the visible silhouette through touchdown, the state change and the following idle cycle.
    for _ in 0..<2 {
        gestures.render()
        let asleep=MotionFrame(gestures.frame()),bounds=gestures.panel.frame
        let head=try pointOn(gestures,.head)
        gestures.press(at:head);gestures.release(at:head)
        let original=boundsOfInk(gestures.view.drawing!)
        var lifted=false,lastTop=original.maxY
        for _ in 0..<200 where gestures.pose == .backLook {
            gestures.render()
            let current=boundsOfInk(gestures.view.drawing!)
            let drawing=gestures.view.drawing!
            let support=CGPoint(x:0,y:drawing.cel.supportOffset).applying(drawing.transform).y+drawing.frame.minY
            try require(abs(support-gestures.y)<0.001,"回头时身体承重线保持贴地")
            if lifted {try require(current.maxY<=lastTop+0.001,"低头过程中没有向上弹起")}
            if gestures.frame().0 === art.cel("back",2) {lifted=true}
            lastTop=current.maxY
            gestures.step(1/30)
        }
        try require(lifted && abs(lastTop-original.maxY)<0.001,"回头后落回原来的高度")
        for _ in 0..<405 {
            gestures.render()
            try require(gestures.pose == .sleepBack && MotionFrame(gestures.frame())==asleep &&
                        gestures.panel.frame==bounds,"背睡休息沿用最低帧和原落点")
            gestures.step(1/30)
        }
    }
    // Walk the same routes the autonomous timer uses. The first and last cels are
    // shared with the surrounding clips, also when a transition is interrupted.
    for target:Pose in [.prone,.sleepLoaf,.side,.sleepSide,.loaf,.sleepBack,.prone] {
        let first=MotionFrame(gestures.frame())
        gestures.change(to:target,for:5)
        try require(MotionFrame(gestures.frame())==first,"换姿保留起始帧")
        var previous=first, visited=[first], elapsed=0.0
        while gestures.pose == .changing && elapsed<12 {
            previous=MotionFrame(gestures.frame())
            gestures.step(1/60);elapsed+=1/60
            let current=MotionFrame(gestures.frame())
            if current != visited.last {visited.append(current)}
        }
        try require(gestures.pose==target && previous==MotionFrame(gestures.frame()),"终止帧接入静止姿势")
        if target == .sleepBack || first.cel === art.cel("turn",5) {
            let turning=visited.filter { f in art.clips["standTurn"]!.contains(where:{$0 === f.cel}) }
            try require(turning.count==14 && elapsed>2.2,"撑身、前后爪换步、下蹲和收爪均有停留")
        }
    }
    for (nap,key) in [(Pose.sleepLoaf,"loaf"),(.sleepSide,"side"),(.sleepBack,"back")] {
        let cat=PetController(art:art,screen:screen)
        cat.change(to:nap,for:art.temperament.sleepTime)
        try waitFor(cat,nap)
        cat.step(600);cat.render()
        try require(cat.pose==nap,"十分钟后仍在同一睡姿")
        let p=try pointOn(cat,.head)
        cat.press(at:p);cat.release(at:p)
        for _ in 0..<9 {cat.step(1/30)}
        let peak=art.cel(key,key=="back" ? 2:0)
        try require(cat.frame().0 === peak,"睁眼或回头及时响应")
        for _ in 0..<90 {cat.step(1/30)}
        try require(cat.frame().0 === peak,"唤醒三秒后仍在看")
        let p1=try pointOn(cat,.head)
        cat.press(at:p1);cat.release(at:p1);cat.step(0.10)
        let p2=try pointOn(cat,.head)
        cat.press(at:p2,clickCount:2);cat.release(at:p2)
        for _ in 0..<32 {cat.step(1/30);cat.render()}
        try require(cat.frame().0 === peak,"双击享受之后继续睁眼")
        for count in 1...3 {
            let p=try pointOn(cat,.head)
            cat.press(at:p,clickCount:count);cat.release(at:p);cat.step(0.09)
        }
        try require(cat.pose == .changing,"打扰睡眠后起身")
        try waitFor(cat,.walking)
    }
    print("Verified",art.clips.values.reduce(0){$0+$1.count},"cels,",art.transitions.count,"motion tracks; petting, recovery, burst input, ground ink, grip and Dock")
}

func verifyPetting(_ art: PetArt) throws {
    func check(_ ok: Bool, _ label: String) throws {
        if !ok {throw ArtError.invalid(label)}
    }
    let threshold=art.temperament.irritationThreshold
    var taps=PettingInput()
    try check(taps.press(.head,threshold:threshold) == .notice,"头部按下即回应")
    try check(taps.release() == nil,"松开不追加动作")
    for i in 2...threshold {
        _=taps.advance(0.14)
        try check(taps.press(.back,threshold:threshold,clickCount:i) == (i==2 && i<threshold ? .enjoy:nil),"仅舒适区域双击有爱心")
        try check(taps.release() == (i == threshold ? .leave:nil),"连续打扰只离开一次")
    }
    for _ in 0..<40 {
        _=taps.advance(0.15)
        try check(taps.press(.head,threshold:threshold) == nil && taps.release() == nil,"持续打扰不积压动作")
    }
    _=taps.advance(4)
    try check(taps.press(.back,threshold:threshold) == .notice,"安静后可以再次抚摸")
    try check(taps.advance(1.24) == nil && taps.advance(0.02) == .leave && taps.release() == nil,"长按只触发一次躲避")
    taps=PettingInput()
    try check(taps.press(.sensitive,threshold:threshold) == nil && taps.release() == .leave,"轻碰敏感部位即避开")
    taps=PettingInput()
    _=taps.press(.sensitive,threshold:threshold);taps.cancelDrag()
    try check(taps.advance(2) == nil && taps.release() == nil,"拖动取消抚摸和长按")

    // Landmarks sampled in the displayed artwork exercise the hit map in both directions.
    let probes:[(String,Int,[(CGFloat,CGFloat,TouchArea)])]=[
        ("settle",0,[(0.33,0.22,.head),(0.58,0.44,.back),(0.38,0.87,.sensitive)]),
        ("settle",8,[(0.25,0.31,.head),(0.62,0.40,.back),(0.28,0.90,.sensitive)]),
        ("loaf",0,[(0.3,0.30,.head),(0.67,0.42,.back),(0.46,0.90,.sensitive)]),
        ("side",0,[(0.17,0.69,.head),(0.54,0.24,.back),(0.46,0.82,.sensitive)]),
        ("walk",0,[(0.13,0.26,.head),(0.54,0.25,.back)]),
        ("turn",5,[(0.37,0.2,.head),(0.60,0.42,.back),(0.65,0.90,.neutral)]),
        ("back",2,[(0.53,0.24,.head),(0.39,0.54,.back)])]
    for (key,i,points) in probes {
        let cel=art.cel(key,i)
        for mirror in [false,true] {
            for unit:CGFloat in [65,160,340] {
                let draw=SpriteDrawing(cel:cel,grounded:true,mirror:mirror,feet:CGPoint(x:210,y:80),
                                       k:cel.scale*unit,stretch:1.009,backing:2,headroom:clamp(unit*0.105,8,31)*2.65)
                for (x,y,area) in points {
                    let p=CGPoint(x:x*CGFloat(cel.image.width),y:CGFloat(draw.image.height)-y*CGFloat(cel.image.height)).applying(draw.transform)
                    try check(draw.touchArea(at:p)==area,"点击区域 \(key) \(i) \(area)")
                }
                guard let heart=draw.heart(progress:0.9,unit:unit) else {throw ArtError.invalid("头顶位置")}
                try check(heart.center.y+heart.size/2<=draw.frame.height && draw.touchArea(at:heart.center)==nil,"爱心可见、可穿透 \(key) \(unit)")
            }
        }
    }
    try check(art.eyelids.count==2 && art.cel("settle",0).eyeCenters?.count==2 && art.cel("settle",8).eyeCenters?.count==2,"坐卧眯眼原画")
    let rest=MotionFrame(art.cel("turn",5)), glance=MotionFrame(art.cel("back",2))
    let sequence=Reaction(library:MotionLibrary(art),from:rest,toward:glance,returningTo:rest,hold:4.5,frameTime:0.055)
    try check(MotionFrame(sequence.frame(at:0))==rest && MotionFrame(sequence.frame(at:0.06)) != rest &&
              MotionFrame(sequence.frame(at:0.30))==glance && MotionFrame(sequence.frame(at:sequence.duration))==rest &&
              MotionFrame(sequence.frame(at:4))==glance,"背睡回头保持清醒再收势")
    try check((art.temperament.restDuration?.first ?? 0)>=600 && art.temperament.sleepDuration[0]>=600,"安静休息时长")
    for key in ["loaf","side","turn"] {
        let cel=art.cel(key,key=="turn" ? 5:2)
        guard let sleep=cel.sleeping else {throw ArtError.invalid("睡姿微动 "+key)}
        let inhale=SleepPhase(age:1.85,twitchStart:.infinity)
        let shifted=sleep.image(at:inhale)
        let row=shifted.bytesPerRow, h=shifted.height
        let a=NSBitmapImageRep(cgImage:sleep.image(at:SleepPhase(age:0,twitchStart:.infinity)))
        let b=NSBitmapImageRep(cgImage:shifted)
        try check(row>0 && a.bytesPerRow==b.bytesPerRow,"相同画幅")
        let rgb0=a.bitmapData!, rgb1=b.bitmapData!, stride=a.bytesPerRow
        try check(memcmp(rgb0,rgb1,stride*h) != 0 && memcmp(rgb0+(h-8)*stride,rgb1+(h-8)*stride,8*stride)==0,"呼吸时胸背起伏、承重轮廓不动 "+key)
        if key != "turn" {
            let t=SleepPhase(age:1.85,twitchStart:1.77)
            let c=NSBitmapImageRep(cgImage:sleep.image(at:t))
            try check(memcmp(rgb1,c.bitmapData!,stride*h) != 0,"可见胡须有独立微动 "+key)
        }
    }
    print("已验证抚摸区域、镜像和缩放、双击、长按、连续点击、拖动取消、爱心和背睡回头。")
}


func verifyLocomotion(_ art:PetArt) throws {
    func require(_ ok:Bool,_ message:String)throws {if !ok {throw ArtError.invalid(message)}}
    // Sample the front and rear independently; checking a single bottom-most
    // row lets a cat pass while its entire haunch floats above the platform.
    let supportBands:[(String,[Int],[(ClosedRange<CGFloat>,Int)])]=[
        ("loaf", [0,1,2], [(0.46...0.60, 2), (0.79...0.84, 3), (0.87...0.91, 4)]),
        ("side", [0,1,2], [(0.16...0.24, 3), (0.78...0.85, 3)]),
        ("settle", Array(0...8), [(0.02...0.52, 3), (0.79...0.86, 3)]),
        ("back", [0,1,2], [(0.32...0.43, 2), (0.72...0.81, 3)])
    ]
    for (clip,indices,bands) in supportBands {
        for i in indices {
            let cel=art.cel(clip,i), image=cel.groundedImage
            let ink=NSBitmapImageRep(cgImage:image)
            let plane=Int((CGFloat(image.height)-cel.supportOffset).rounded(.down))-1
            for (band,tolerance) in bands {
                let columns=Int(band.lowerBound*CGFloat(image.width))...Int(band.upperBound*CGFloat(image.width))
                let touching=columns.filter { x in
                    (0...tolerance).contains { y in (ink.colorAt(x:x,y:plane-y)?.alphaComponent ?? 0)>=0.72 }
                }
                try require(touching.count>=3,"平视承重区域离地 \(clip)-\(i) \(band)")
            }
        }
    }
    // The exposed belly must cover the line continuously between the paws
    // and tail. An isolated toe in each half of the drawing used to pass.
    let bodyContacts:[(String,Int,ClosedRange<CGFloat>,CGFloat,CGFloat)]=[
        ("settle",8,0.40...0.73,0.28,0.85), ("settle",0,0.55...0.73,0.39,0.85),
        ("loaf",2,0.61...0.86,0.44,0.50), ("side",2,0.60...0.78,0.49,0.935),
        ("back",2,0.21...0.35,0.44,0.65), ("motion-prone-turn",3,0.28...0.60,0.16,0.85)
    ]
    for (clip,i,body,paw,tail) in bodyContacts {
        let cel=art.cel(clip,i), im=cel.groundedImage, ink=NSBitmapImageRep(cgImage:im)
        let plane=CGFloat(im.height)-cel.supportOffset
        let row=Int(plane.rounded(.down))-1
        func opaque(_ x:Int,_ y:Int)->Bool {(ink.colorAt(x:x,y:y)?.alphaComponent ?? 0)>0.60}
        let band=Int(body.lowerBound*CGFloat(im.width))...Int(body.upperBound*CGFloat(im.width))
        try require(band.allSatisfy {opaque($0,row)}, "腹部与台面间有缝隙 \(clip)-\(i)")
        let depth=max(2,Int(0.006/cel.scale))
        for at in [paw,tail] {
            try require(opaque(Int(at*CGFloat(im.width)),row+depth), "近侧轮廓未盖住台沿 \(clip)-\(i) \(at)")
        }
        for mirror in [false,true] {
            for unit:CGFloat in [65,162,340] {
                let feet=CGPoint(x:250,y:70), k=unit*cel.scale
                let dock=SpriteDrawing(cel:cel,grounded:true,mirror:mirror,feet:feet,k:k,stretch:1,backing:2)
                let floor=SpriteDrawing(cel:cel,grounded:true,mirror:mirror,feet:feet,k:k,stretch:1,backing:2,screenFloor:feet.y)
                let pixel=CGPoint(x:paw*CGFloat(im.width),y:CGFloat(im.height-row-depth)-0.5)
                try require(dock.frame.minY<feet.y && dock.contains(pixel.applying(dock.transform)) &&
                            floor.frame.minY==feet.y && !floor.contains(pixel.applying(floor.transform)),"台沿外伸、屏幕底边与点击位置")
            }
        }
    }
    let library=MotionLibrary(art)
    for track in art.transitions {
        guard let pairs=track.paws else {continue}
        for mirror in [false,true] {
            let route=track.frames.map {MotionFrame($0,mirror)}
            for (i,toes) in pairs.enumerated() {
                let a=route[i],b=route[i+1], dx=library.step(from:a,to:b)
                func foot(_ cel:Cel,_ u:CGFloat)->CGFloat {
                    (CGFloat(cel.image.width)*u-cel.anchorX)*cel.scale*(mirror ? -1:1)
                }
                try require(abs(foot(a.cel,toes[0])-foot(b.cel,toes[1])-dx)<0.00001 &&
                            abs(dx+library.step(from:b,to:a))<0.00001,"转身正反播放支撑爪停在同一点")
            }
            for (i,toes) in pairs.enumerated() {
                for (index,u) in [(i,toes[0]),(i+1,toes[1])] {
                    let cel=route[index].cel, im=cel.groundedImage
                    let mask=NSBitmapImageRep(cgImage:im)
                    let x=Int(u*CGFloat(im.width)),r=max(2,Int(CGFloat(im.width)*0.017))
                    let y=min(im.height-1,Int(CGFloat(im.height)-cel.supportOffset)-1)
                    let count=(x-r...x+r).filter {(mask.colorAt(x:$0,y:y)?.alphaComponent ?? 0)>0.6}.count
                    try require(count>=3,"转身承重爪离开台面：第 \(index) 帧")
                }
            }
            let sequence=Reaction(library:library,path:route)
            try require(abs(sequence.travel(at:sequence.duration))>0.12,"换步时重心离开起点")
        }
    }
    let gait=art.gait, speed=art.gait.speed
    // Independently measured contacts on consecutive drawings, in source pixels.
    let contacts=[(23.0,39.0),(39,62),(62,132),(301,326),(326,355),(136,209)]
    for rate in [speed,1.85*speed] {
        for sign:CGFloat in [-1,1] {
            let interval=gait.length/(rate*6)
            for (i,pair) in contacts.enumerated() {
                let a=art.cel("walk",i), next=(i+1)%6, b=art.cel("walk",next)
                let before=gait.sample(time:(Double(i)+0.99)*interval,speed:rate)
                let after=gait.sample(time:(Double(i)+1.01)*interval,speed:rate)
                let x0=sign*(before.distance-(pair.0-a.anchorX)*a.scale)
                let x1=sign*(after.distance-(pair.1-b.anchorX)*b.scale)
                try require(before.index==i && after.index==next && abs(x1-x0)<0.006,"换步时承重爪停在同一地面位置")
            }
        }
    }
    // Sweep through both approach directions and sizes even when the host has an auto-hidden Dock.
    for dir:CGFloat in [-1,1] {
        for size:CGFloat in [42,95,175] {
            let t=Terrain(screen:CGRect(x:-200,y:-90,width:1900,height:900),dock:CGRect(x:340,y:-90,width:620,height:82))
            let edge=dir>0 ? 340.0:960.0
            let near=t.landingX(near:edge,radius:size)
            let far=t.landingX(near:edge-dir*size*0.9,radius:size)
            try require(dir*(near-edge)>0 && !t.overlaps(far,size),"Dock 两端有实际支撑")
            let x=edge-dir*(size+1)
            guard let up=t.crossing(from:x,to:x+dir*2,direction:dir,radius:size,onDock:false),
                  let down=t.crossing(from:near+dir,to:near-dir,direction:-dir,radius:size,onDock:true) else {throw ArtError.invalid("边缘检测")}
            try require(near==up.endX && t.landingX(near:down.startX,radius:size)==down.startX,"起跳、跳上和拖放共用落脚范围")
            for (clip,frames) in art.clips where !["carry","leap","release","hopUp","stepDown"].contains(clip) {
                for cel in frames {
                    let k=(size-2)/0.78*cel.scale, width=CGFloat(cel.groundedImage.width)*k
                    let extent=max(cel.anchorX*k,width-cel.anchorX*k)
                    let exposed=extent-abs(near-edge)+82*0.35
                    try require(exposed<=width*0.10,"镜像和原方向的 Dock 外露不超过一成 "+clip)
                }
            }
            for j in [up,down] {
                let k=(size-2)/0.78
                let motion=DockMotion(hop:j,edge:edge,unit:k,art:art)
                var previous=j.startY, seen=Set<ObjectIdentifier>()
                for i in 0...300 {
                    let t=CGFloat(i)/300, p=motion.position(t), cel=motion.frame(t)
                    seen.insert(ObjectIdentifier(cel))
                    if j.descending {
                        try require(p.y<=previous+0.001 && p.y>=j.endY,"下跳始终朝地面")
                        let sign:CGFloat=j.endX<j.startX ? 1:-1
                        let column=max(0,Int(floor(cel.anchorX+(edge-p.x)*sign/(k*cel.scale))))
                        if column<cel.image.width {
                            try require(p.y+cel.trailingClearance[column]*k*cel.scale+0.01>=j.startY,"下跳腿部穿过 Dock")
                        }
                    }
                    if !j.descending {
                        let sign:CGFloat=j.endX>j.startX ? 1:-1
                        let col=min(cel.image.width-1,Int(ceil(cel.anchorX+(p.x-edge)*sign/(k*cel.scale))))
                        if col>=0 {try require(p.y+cel.leadingClearance[col]*k*cel.scale+0.01>=j.endY,"上台阶前爪穿过边缘")}
                        try require(p.y>=previous-0.001 && p.y<=j.endY+0.001,"上台贴着台沿，无额外抛高")
                    }
                    previous=p.y
                }
                try require(seen.count>=9 && motion.frame(0) === art.cel("walk",0) &&
                            motion.frame(1) === art.cel("walk",motion.exitStride),"起步、探身和落地逐帧衔接")
                try require(abs(previous-j.endY)<0.01 && abs(t.support(j.endX,size)-j.endY)<0.01,"碰撞平台 dir=\(dir) size=\(size) down=\(j.descending) end=\(previous),\(j.endY)")
            }
        }
    }
    let narrow=Terrain(screen:CGRect(x:-150,y:0,width:1100,height:800),dock:CGRect(x:340,y:0,width:120,height:75))
    try require(narrow.dockStandingRange(radius:110)==nil && !narrow.overlaps(narrow.landingX(near:400,radius:110),110),"Dock 太窄时落在旁边的地面")
    try require(narrow.crossing(from:229,to:231,direction:1,radius:110,onDock:false)==nil,"窄 Dock 不起跳上台")
    let compact=Terrain(screen:CGRect(x:0,y:0,width:900,height:580),dock:CGRect(x:430,y:0,width:60,height:85))
    let fitted=compact.fittingRadius(235)
    try require(!compact.overlaps(compact.landingX(near:458,radius:fitted),fitted),"狭窄屏幕保留受支撑的落点")
    let pinned=Terrain(screen:CGRect(x:0,y:0,width:1200,height:800),dock:CGRect(x:30,y:0,width:820,height:80))
    let stop=pinned.landingX(near:30,radius:120)
    try require(pinned.crossing(from:stop,to:stop-1,direction:-1,radius:120,onDock:true)==nil &&
                pinned.landingX(near:stop-1,radius:120)==stop,"屏幕边缘无处跳下时停在平台上")
    print("已校对平视姿势前后接地、行走支撑爪、避让步频、左右两侧上下台阶和不同显示尺寸。")
}
