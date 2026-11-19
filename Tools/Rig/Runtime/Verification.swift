import AppKit

private func verifyGroundInk(_ art:PetArt) throws {
    for (name,frames) in art.clips where name != "carry" {
        for (index,cel) in frames.enumerated() where name != "leap" || index != 1 {
            try autoreleasepool {
                for (size,backing) in [(97.0,1.0),(178.0,2.0),(356.0,2.0)] {
                    let draw=SpriteDrawing(cel:cel,grounded:true,mirror:backing==2,feet:CGPoint(x:500,y:79),
                                           k:size*cel.scale,stretch:1.009,backing:backing)
                    let w=Int(ceil(draw.frame.width*backing))
                    guard let ctx=CGContext(data:nil,width:w,height:1,bitsPerComponent:8,bytesPerRow:w*4,
                                            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),
                          let data=ctx.data else {throw ArtError.invalid("接触线采样")}
                    ctx.scaleBy(x:backing,y:backing)
                    draw.paint(in:ctx)
                    let row=data.assumingMemoryBound(to:UInt8.self)
                    guard draw.frame.minY==79, (0..<w).filter({row[$0*4+3]>=160}).count>=max(1,w/65) else {
                        throw ArtError.invalid("底部缺少实体像素 \(name)-\(index) 尺寸 \(size)")
                    }
                }
            }
        }
    }
}

// Exercises the packaged program, real assets and the screen's actual terrain without taking over the pointer.
func verifyApp() throws {
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
    try verifyGroundInk(art)
    let pet=PetController(art:art,screen:screen)
    func lift(to point:CGPoint) throws {
        pet.render()
        pet.press(at:CGPoint(x:pet.x,y:pet.y+16))
        let grip=art.cel("carry",0)
        pet.drag(to:CGPoint(x:pet.x,y:pet.y+grip.gripHeight*grip.scale*pet.unit+5))
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
    let click=CGPoint(x:pet.x-10,y:pet.y+20)
    let asleep=MotionFrame(pet.frame())
    pet.touch(at:click,now:100)
    try require(pet.pose == .backLook && MotionFrame(pet.frame())==asleep,"点醒从原睡姿起步")
    for _ in 0..<7 {pet.step(1/30)}
    let waking=MotionFrame(pet.frame())
    try require(waking != asleep && waking.cel !== art.cel("back",2),"转头中间画面")
    pet.touch(at:click,now:100.3)
    try require(pet.pose == .paw && MotionFrame(pet.frame())==waking,"回头途中接伸爪")
    for _ in 0..<9 {pet.step(1/30)}
    let current=MotionFrame(pet.frame())
    pet.touch(at:click,now:100.6)
    pet.touch(at:click,now:100.9)
    try require(pet.pose == .paw && MotionFrame(pet.frame())==current,"连点不截断动作")
    var played=[Pose.paw]
    for _ in 0..<600 where pet.pose.striking {
        pet.step(1/30)
        if pet.pose != played.last {played.append(pet.pose)}
    }
    try require(played == [.paw,.swat,.nip,.prone],"依次伸爪、拍爪、轻咬，再趴回去")
    pet.startWalk(towardDock:true)
    try waitFor(pet,.walking)
    try require(pet.pose == .walking,"慢走")
    pet.touch(at:click,now:104);try require(pet.pose == .paw,"走路时被点停")
    let ground=pet.surface.terrain
    try require(ground.floor==ground.screen.minY,"屏幕底边")
    if let d=ground.dock {try require(ground.support(d.midX,pet.radius)==d.maxY,"Dock 上沿")}
    let high=CGPoint(x:ground.screen.midX,y:ground.screen.midY)
    let before=pet.pose
    pet.press(at:click);pet.step(2)
    pet.drag(to:CGPoint(x:click.x+8,y:click.y));pet.drag(to:CGPoint(x:click.x,y:click.y-8))
    pet.drag(to:CGPoint(x:click.x,y:click.y+10))
    try require(pet.pose==before,"长按、横拖、下拖和轻微上移仍然着地")
    pet.release(at:click);try require(pet.pose==before,"取消拖动不触发抓咬")
    try lift(to:high)
    for _ in 0..<12 {
        pet.step(0.12);pet.render()
        guard let drawn=pet.view.drawing else {throw ArtError.invalid("悬提画面")}
        let grip=CGPoint(x:drawn.cel.anchorX,y:drawn.cel.gripHeight).applying(drawn.transform)
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
                else {try require(pet.y+0.01>=ground.support(pet.x,pet.radius),"穿过 Dock")}
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
    try verifyTerrain(art)
    let frame=art.cel("settle",0),h=frame.groundedImage.height
    try require(!frame.contains(.zero,height:h) && frame.contains(CGPoint(x:frame.image.width/2,y:h/2),height:h),"透明像素点击穿透")
    let gestures=PetController(art:art,screen:screen)
    var time=1000.0
    for (count,action,key) in [(1,Pose.paw,"paw"),(3,.swat,"swat"),(4,.nip,"nip")] {
        for (offset,clip,index) in [(CGPoint(x:-0.08,y:0.08),key+"Aim",0),
                                    (CGPoint(x:0.07,y:0.47),key+"Aim",1),
                                    (CGPoint(x:0.10,y:0.86),key+"Aim",2),
                                    (CGPoint(x:-0.48,y:0.55),key,1),
                                    (CGPoint(x:0.48,y:0.55),key,1)] {
            let target=CGPoint(x:gestures.x+offset.x*gestures.unit,y:gestures.y+offset.y*gestures.unit)
            let start=MotionFrame(gestures.frame())
            let expected=art.cel(clip,index)
            for i in 0..<count {gestures.touch(at:target,now:time+Double(i)*0.12)}
            time+=10
            try require(MotionFrame(gestures.frame())==start,"按下时保留当时的姿势")
            var before=Set<MotionFrame>(),after=Set<MotionFrame>(),atPeak=0
            for _ in 0..<600 where gestures.pose.striking {
                gestures.render()
                guard let draw=gestures.view.drawing else {throw ArtError.invalid("互动画面")}
                try require(draw.cel.pose.parents == frame.pose.parents &&
                            abs(abs(draw.transform.a)-draw.transform.d)<0.0001, "互动骨骼等比显示")
                if gestures.pose==action {
                    if draw.cel === expected {
                        atPeak+=1
                        guard let tip=draw.cel.contact else {throw ArtError.invalid("缺少互动位置")}
                        let p=tip.applying(draw.transform)
                        try require(draw.contains(p),"接触部位有角色像素")
                        if clip==key {try require((p.x+draw.frame.minX-gestures.x)*offset.x>0,"伸向点击侧")}
                    } else if atPeak==0 {before.insert(MotionFrame(gestures.frame()))}
                    else {after.insert(MotionFrame(gestures.frame()))}
                }
                gestures.step(1/30)
            }
            try require(before.count>=5 && atPeak>=3 && after.count>=5,"起势、停留和收势：\(clip)-\(index)")
            try require(gestures.pose == .sitting && MotionFrame(gestures.frame())==start,"收回原坐姿")
        }
    }
    for track in art.transitions {
        let start=MotionFrame(track.frames.first!),end=MotionFrame(track.frames.last!,track.turnsAround)
        let route=gestures.motions.path(from:start,to:end)
        try require(route.count==track.frames.count,"过渡经过整条手绘帧序列")
    }
    for key in ["loaf","side"] {
        let closed=MotionFrame(art.cel(key,2)),open=MotionFrame(art.cel(key,0))
        let wake=Reaction(library:gestures.motions,from:closed,toward:open,returningTo:open,action:.look)
        let visible=Set((0..<Int(ceil(wake.duration*30))).map { MotionFrame(wake.frame(at:Double($0)/30)) })
        try require(visible.count==3 && MotionFrame(wake.frame(at:wake.duration))==open,"卧姿逐帧睁眼")
    }
    // A walking click keeps the current stride and reaches the sitting pose before striking.
    gestures.startWalk(towardDock:true)
    try waitFor(gestures,.walking)
    let stride=MotionFrame(gestures.frame())
    let point=CGPoint(x:gestures.x,y:gestures.y+gestures.unit*0.4)
    gestures.touch(at:point,now:time+10)
    try require(gestures.pose == .paw && MotionFrame(gestures.frame())==stride,"由走路当前帧停步")
    var stopped=false
    for _ in 0..<300 where gestures.pose.striking {
        if gestures.frame().0 === art.cel("motion-walk-sit",2) {stopped=true}
        gestures.step(1/30)
    }
    try require(stopped && gestures.pose == .sitting,"走路后落座伸爪")
    gestures.sleepNow()
    try waitFor(gestures,.sleepBack)
    let target=CGPoint(x:gestures.x-gestures.unit*0.1,y:gestures.y+gestures.unit*0.15)
    gestures.touch(at:target,now:time+20)
    gestures.touch(at:target,now:time+20.3)
    var reachedLow=false
    for _ in 0..<300 where gestures.pose.striking {
        if gestures.frame().0 === art.cel("pawRest",0) {reachedLow=true}
        gestures.step(1/30)
    }
    try require(reachedLow && gestures.pose == .prone && gestures.frame().0 === art.cel("settle",8),"卧姿朝近身目标伸爪后趴回去")
    let prone=MotionFrame(gestures.frame())
    let flank=CGPoint(x:gestures.x+0.36*gestures.unit,y:gestures.y+0.25*gestures.unit)
    for i in 0..<4 {gestures.touch(at:flank,now:time+30+0.12*Double(i))}
    var flankPeaks=Set<MotionFrame>()
    for _ in 0..<500 where gestures.pose.striking {
        let here=MotionFrame(gestures.frame())
        try require(here.mirrored==prone.mirrored,"卧姿连点保持朝向")
        flankPeaks.insert(here)
        gestures.step(1/30)
    }
    for action in ["paw","swat","nip"] {
        try require(flankPeaks.contains(MotionFrame(art.cel(action+"Rest",1))),"点后侧触发卧姿动作 "+action)
        for flip in [false,true] {
            for base in [art.cel("settle",8),art.cel("side",0),art.cel("loaf",0)] {
                let home=MotionFrame(base,flip)
                for x:CGFloat in [-0.48,0.0,0.48] {
                    for y:CGFloat in [0.08,0.58] {
                        let peak=gestures.motions.target(action:action,offset:CGPoint(x:x,y:y),unit:1,from:home,resting:true)
                        let path=gestures.motions.path(from:home,to:peak)+gestures.motions.path(from:peak,to:home)
                        try require(art.clips[action+"Rest"]!.contains(where:{$0 === peak.cel}) &&
                                    path.allSatisfy{$0.mirrored==flip && $0.cel !== art.cel("settle",0)},
                                    "两侧、高低点击均留在卧姿")
                    }
                }
            }
        }
    }
    try require(gestures.pose == .prone && MotionFrame(gestures.frame())==prone,"后侧回应收回原卧姿")
    gestures.sleepNow()
    try waitFor(gestures,.sleepBack)
    // Check the visible silhouette through touchdown, the state change and the following idle cycle.
    for now in [time+50,time+80] {
        gestures.render()
        let asleep=MotionFrame(gestures.frame()),bounds=gestures.panel.frame
        gestures.touch(at:target,now:now)
        var lifted=false,lastTop=bounds.maxY
        for _ in 0..<200 where gestures.pose == .backLook {
            gestures.render()
            let current=gestures.panel.frame
            try require(current.minY==bounds.minY,"回头时保持贴地")
            if lifted {try require(current.maxY<=lastTop,"低头过程中没有向上弹起")}
            if gestures.frame().0 === art.cel("back",2) {lifted=true}
            lastTop=current.maxY
            gestures.step(1/30)
        }
        try require(lifted && lastTop==bounds.maxY,"回头后落回原来的高度")
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
            try require(turning.count==14 && elapsed>3.5,"撑身、前后爪换步、下蹲和收爪均有停留")
        }
    }
    print("Verified",art.clips.values.reduce(0){$0+$1.count},"cels,",art.transitions.count,"motion tracks; anticipation, contact holds, recovery, burst input, ground ink, grip and Dock")
}

private func verifyTerrain(_ art:PetArt) throws {
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
                    let k=(size-2)/0.725*cel.scale, width=cel.pose.size.width*k
                    let extent=max(cel.anchorX*k,width-cel.anchorX*k)
                    let exposed=extent-abs(near-edge)+82*0.35
                    try require(exposed<=width*0.10,"镜像和原方向的 Dock 外露不超过一成 "+clip)
                }
            }
            for j in [up,down] {
                let k=(size-2)/0.725
                let motion=DockMotion(hop:j,edge:edge,unit:k,art:art)
                var previous=j.startY, seen=Set<ObjectIdentifier>()
                for i in 0...300 {
                    try autoreleasepool {
                        let t=CGFloat(i)/300, p=motion.position(t), cel=motion.sample(t)
                        seen.insert(ObjectIdentifier(motion.frame(t)))
                        if j.descending {
                            try require(p.y<=previous+0.001 && p.y>=j.endY,"下跳始终朝地面")
                            let sign:CGFloat=j.endX<j.startX ? 1:-1
                            let column=max(0,Int(floor(cel.anchorX+(edge-p.x)*sign/(k*cel.scale))))
                            if column<Int(cel.pose.size.width) {
                                try require(p.y+cel.trailingClearance[column]*k*cel.scale+0.01>=j.startY,"下跳腿部穿过 Dock")
                            }
                        }
                        previous=p.y
                    }
                }
                try require(seen.count>=9 && motion.frame(0) === art.cel("walk",0) &&
                            motion.frame(1) === art.cel("walk",0),"起步、探身和落地逐帧衔接")
                try require(abs(previous-j.endY)<0.01 && abs(t.support(j.endX,size)-j.endY)<0.01,"碰撞平台")
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
}


private func require(_ ok:Bool,_ what:String)throws {if !ok {throw ArtError.invalid(what)}}

// Compare the visible ink at the same desktop anchor, including the external
// mirror and grounded crop. This catches a view swap even when FK is continuous.
private func inkDifference(_ a:MotionFrame,_ b:MotionFrame)->Double {
    func ink(_ sample:MotionFrame)->[UInt8] {
        let width=160,height=146,cel=sample.cel
        var pixels=[UInt8](repeating:255,count:width*height)
        pixels.withUnsafeMutableBytes { raw in
            let ctx=CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,
                              bytesPerRow:width,space:CGColorSpaceCreateDeviceGray(),
                              bitmapInfo:CGImageAlphaInfo.none.rawValue)!
            ctx.translateBy(x:80,y:4)
            ctx.scaleBy(x:(sample.mirrored ? -1:1)*86*cel.scale,y:86*cel.scale)
            let image=cel.groundedImage
            ctx.draw(image,in:CGRect(x:-cel.anchorX,y:0,width:CGFloat(image.width),height:CGFloat(image.height)))
        }
        return pixels
    }
    let x=ink(a),y=ink(b)
    var error=0,total=0
    for i in x.indices {error+=abs(Int(x[i])-Int(y[i]));total+=255-Int(x[i])}
    return Double(error)/Double(max(1,total))
}

private func verifyContinuity(_ art:PetArt)throws {
    var checked=Set<[MotionFrame]>()
    func edge(_ a:MotionFrame,_ b:MotionFrame,_ name:String)throws {
        guard checked.insert([a,b]).inserted else{return}
        try autoreleasepool {
            let error=inkDifference(a.toward(b,0.49999),a.toward(b,0.50001))
            try require(error<0.055,"跨视角出现单帧跳变 "+name)
            if a.mirrored != b.mirrored {
                try require(inkDifference(a.toward(b,0.99999),b)<0.035,"转身末尾朝向或锚点跳变")
            }
        }
    }
    for (name,clip) in art.clips {
        for (a,b) in zip(clip,clip.dropFirst()) {try edge(MotionFrame(a),MotionFrame(b),name)}
    }
    for t in art.transitions {
        for i in 1..<t.frames.count {
            try edge(MotionFrame(t.frames[i-1]),MotionFrame(t.frames[i],t.turnsAround && i==t.frames.count-1),"切换")
        }
    }
    let left=MotionFrame(art.cel("settle",0)),right=MotionFrame(art.cel("pawAim",2),true)
    let interrupted=left.toward(right,0.43)
    try require(inkDifference(interrupted,interrupted.toward(MotionFrame(art.cel("settle",8)),0.00001))<0.025,"打断时保留实际画面")
    let stride=art.cel("walk",1)
    guard let paw=stride.pose.names.firstIndex(of:"paw") else {throw ArtError.invalid("缺少支撑爪")}
    // Near forepaw is in stance between phases 0.54 and 1.0.
    let t0=0.62*1.14
    func planted(_ t:Double)->CGFloat {art.walking(at:t).pose.world[paw].x-CGFloat(t)*art.temperament.walkSpeed}
    for i in 1...9 {try require(abs(planted(t0+Double(i)/30)-planted(t0))<0.003,"支撑爪在桌面滑动")}
    try require(inkDifference(MotionFrame(art.walking(at:1.14-0.00001)),MotionFrame(art.walking(at:0)))<0.025,"步态循环接缝")
    print("Verified",checked.count,"rendered pose boundaries, mirror, interruption and planted gait")
}

// Runs without WindowServer and reads the same packaged rig used by the pet.
func verifyRig() throws {
    guard let root=Bundle.main.resourceURL else {throw ArtError.invalid("缺少角色资源")}
    let art=try PetArt(root:root.appendingPathComponent("Pets/Dada"))
    try verifyGroundInk(art)
    let library=MotionLibrary(art)
    let home=MotionFrame(art.cel("settle",8)),stride=art.cel("walk",0)
    var checked=Set<ObjectIdentifier>()
    for clip in art.clips.values {
        for cel in clip where checked.insert(ObjectIdentifier(cel)).inserted {
            let height=cel.groundedImage.height
            if let tip=cel.contact {try require(cel.contains(tip,height:height),"接触点缺少实体像素")}
            try require(cel.pose.parents == stride.pose.parents && cel.pose.skin.pieces.count>1,"全身骨架和分件")
        }
        for (a,b) in zip(clip,clip.dropFirst()) {
            let middle=a.toward(b,0.5)
            try require(middle.pose.world.allSatisfy{$0.x.isFinite && $0.y.isFinite && $0.length>0},"关节插值")
        }
    }
    let walk=art.clips["walk"]!
    try require(walk.allSatisfy{$0.pose.skin === stride.pose.skin},"六个步态共用侧面分件")
    let mid=stride.toward(walk[1],0.5)
    try require(mid.pose.world.indices.contains{abs(mid.pose.world[$0].angle-stride.pose.world[$0].angle)>0.02},"步态中段关节转动")
    // Rotate the tail alone and verify the four foot chains stay in place.
    let original=stride.pose
    guard let tail=original.names.firstIndex(of:"tail"),let tip=original.names.firstIndex(of:"tip") else {throw ArtError.invalid("缺少尾链")}
    var joints=original.joints
    let j=joints[tail]
    joints[tail]=Joint(j.x,j.y,j.angle+0.6,j.length,j.thickness)
    let posed=original.withJoints(joints)
    for i in joints.indices where i != tail && i != tip {
        let a=original.world[i],b=posed.world[i]
        try require(hypot(a.x-b.x,a.y-b.y)<0.00001 && abs(a.angle-b.angle)<0.00001,"摆尾带动其他部位")
    }
    for key in ["pawRest","swatRest","nipRest"] {
        let peak=MotionFrame(art.cel(key,0))
        let action:Pose=key=="pawRest" ? .paw:key=="swatRest" ? .swat:.nip
        let r=Reaction(library:library,from:home,toward:peak,returningTo:home,action:action)
        try require(r.sample(at:0)==home && r.sample(at:r.duration)==home,"互动回到趴姿")
        try require((0..<Int(r.duration*60)).contains{r.sample(at:Double($0)/60)==peak},"互动接触停留")
    }
    try verifyContinuity(art)
    try verifyTerrain(art)
    print("Verified",checked.count,"skeletal keys,",art.clips.count,"clips,",art.transitions.count,"transitions, foot support, contacts, tail isolation and Dock traversal")
}
