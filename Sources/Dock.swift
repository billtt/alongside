import AppKit
import ApplicationServices

struct DockSurface {
    var terrain: Terrain
    var source: String
}

final class DockDetector {
    // Optional local macOS SPI. Resolve at runtime so a future OS can fall back gracefully.
    // Signature reference: https://gist.github.com/w0lfschild/90db263867f469738c01e9e2d937f874
    private typealias GetDockRect = @convention(c) (UnsafeMutablePointer<CGRect>) -> Void
    private let nativeRect: GetDockRect? = {
        guard let lib = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let symbol = dlsym(lib, "CoreDockGetRect") else { return nil }
        return unsafeBitCast(symbol, to: GetDockRect.self)
    }()
    // AX queries are confined to the Dock, and are used only when permission already exists.
    private func axFrame(_ element: AXUIElement) -> CGRect? {
        func attr(_ key: CFString) -> AXValue? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element,key,&v) == .success, let v,
                  CFGetTypeID(v)==AXValueGetTypeID() else {return nil}
            return (v as! AXValue)
        }
        guard let p=attr(kAXPositionAttribute as CFString), let s=attr(kAXSizeAttribute as CFString) else {return nil}
        var pt=CGPoint.zero, sz=CGSize.zero
        guard AXValueGetValue(p,.cgPoint,&pt), AXValueGetValue(s,.cgSize,&sz) else {return nil}
        return CGRect(origin:pt,size:sz)
    }
    private func lists() -> [CGRect] {
        guard AXIsProcessTrusted(), let app=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock").first else {return []}
        let root=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root,0.12)
        var v:CFTypeRef?
        guard AXUIElementCopyAttributeValue(root,kAXChildrenAttribute as CFString,&v) == .success,
              let children=v as? [AXUIElement] else {return []}
        return children.compactMap { child in
            var role:CFTypeRef?
            guard AXUIElementCopyAttributeValue(child,kAXRoleAttribute as CFString,&role) == .success,
                  role as? String == (kAXListRole as String) else {return nil}
            return axFrame(child)
        }
    }
    func read(_ s:NSScreen) -> DockSurface {
        let screen=s.frame, reserved=max(0,s.visibleFrame.minY-screen.minY)
        let empty=DockSurface(terrain:Terrain(screen:screen,dock:nil),source:"无底部 Dock")
        let prefs=UserDefaults.standard.persistentDomain(forName:"com.apple.dock") ?? [:]
        if (prefs["orientation"] as? String ?? "bottom") != "bottom" {
            let edge = CGRect(x:s.visibleFrame.minX,y:screen.minY,width:s.visibleFrame.width,height:screen.height)
            return DockSurface(terrain:Terrain(screen:edge,dock:nil),source:"侧边 Dock")
        }
        let originTop=NSScreen.screens.first?.frame.maxY ?? screen.maxY
        func local(_ quartz:CGRect)->CGRect {CGRect(x:quartz.minX,y:originTop-quartz.maxY,width:quartz.width,height:quartz.height)}
        let hidden=prefs["autohide"] as? Bool ?? false
        func usable(_ rect:CGRect)->Bool {
            rect.width>50 && rect.height>6 && rect.height<screen.height*0.35 &&
            abs(rect.minY-screen.minY)<10 && screen.contains(CGPoint(x:rect.midX,y:rect.midY))
        }
        func make(_ rect:CGRect,_ src:String)->DockSurface {
            let h=rect.maxY-screen.minY
            let box=CGRect(x:rect.minX,y:screen.minY,width:rect.width,height:h).intersection(screen)
            return DockSurface(terrain:Terrain(screen:screen,dock:box),source:src)
        }
        if let nativeRect {
            var q=CGRect.zero
            nativeRect(&q)
            let r=local(q)
            if usable(r) {
                let visible = r.intersection(screen)
                if hidden && visible.height < 5 {return empty}
                return make(r,"系统 Dock 边界")
            }
            if !r.isEmpty && reserved<5 && (r.maxY<=screen.minY+4 || !r.intersects(screen)) {return empty}
        }
        // The background Dock window is bounded on some macOS releases, full-display on others.
        let dockPID=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock").first?.processIdentifier
        let info=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        for row in info where (row[kCGWindowOwnerPID as String] as? Int32) == dockPID &&
            row[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.dockWindow)) {
            guard let b=row[kCGWindowBounds as String] as? NSDictionary,
                  let rect=CGRect(dictionaryRepresentation:b) else {continue}
            let r=local(rect)
            if usable(r) {return make(r,"Dock 窗口")}
        }
        for item in lists() {
            let r=local(item)
            if usable(r) {return make(r.insetBy(dx:-3,dy:0),"Dock 辅助功能边界")}
        }
        // Hidden Docks reserve no usable height. Catch a revealed auto-hidden Dock on the pointer's screen.
        let mouse=NSEvent.mouseLocation
        let tile=(prefs["tilesize"] as? NSNumber)?.doubleValue ?? 48
        let h=reserved>5 ? reserved : tile + 17
        if reserved<=5 && !(hidden && screen.contains(mouse) && mouse.y-screen.minY<h) {return empty}
        let apps=prefs["persistent-apps"] as? [[String:Any]] ?? []
        let other=prefs["persistent-others"] as? [Any] ?? []
        let recent=(prefs["show-recents"] as? Bool ?? true) ? (prefs["recent-apps"] as? [[String:Any]] ?? []) : []
        func url(_ item:[String:Any])->String? {
            let data=item["tile-data"] as? [String:Any]
            return (data?["file-data"] as? [String:Any])?["_CFURLString"] as? String
        }
        let listed=Set((apps+recent).compactMap(url).compactMap{URL(string:$0)?.standardizedFileURL.path})
        let running=NSWorkspace.shared.runningApplications.filter{$0.activationPolicy == .regular && $0.bundleIdentifier != "com.apple.finder" && !listed.contains($0.bundleURL?.standardizedFileURL.path ?? "")}
        let count=apps.count+recent.count+other.count+running.count+2 // Finder and Trash
        let pitch=min(tile+8,max(22,h-8))
        let width=min(screen.width,CGFloat(count)*pitch + 20)
        let pin=prefs["pinning"] as? String
        let left=pin=="start" ? screen.minX : pin=="end" ? screen.maxX-width : screen.midX-width/2
        if reserved<=5 && (mouse.x<left || mouse.x>left+width) {return empty}
        return make(CGRect(x:left,y:screen.minY,width:width,height:h),"Dock 布局估算")
    }
}
