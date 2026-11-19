import AppKit

final class AppDelegate:NSObject,NSApplicationDelegate,NSWindowDelegate {
    private var pet:PetController?
    private var status:NSStatusItem?
    private var settings:NSPanel?
    private var slider:NSSlider?
    private var percent:NSTextField?
    func applicationDidFinishLaunching(_ notification:Notification) {
        do {
            guard let screen=NSScreen.main ?? NSScreen.screens.first,let resources=Bundle.main.resourceURL else {
                throw ArtError.invalid("无法连接显示器")
            }
            let art=try PetArt(root:resources.appendingPathComponent("Pets/Dada"))
            let cat=PetController(art:art,screen:screen);pet=cat
            let menu=NSMenu()
            func item(_ text:String,_ action:Selector,_ key:String="") {
                let entry=menu.addItem(withTitle:text,action:action,keyEquivalent:key);entry.target=self
            }
            item("走一走",#selector(walk));item("睡一会儿",#selector(sleepCat))
            if art.clips["grooming"] != nil { item("洗洗脸", #selector(groom)) }
            menu.addItem(.separator())
            item("大小设置…",#selector(showSettings),",");item("退出 Alongside",#selector(quit),"q")
            let status=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
            if let btn=status.button {
                let img=NSImage(systemSymbolName:"pawprint.fill",accessibilityDescription:"Alongside · 达达")
                img?.isTemplate=true;btn.image=img;btn.toolTip="Alongside · 达达"
            }
            self.status=status;status.menu=menu;cat.controls=menu
            cat.start()
        } catch {
            let alert=NSAlert();alert.messageText="Alongside 无法启动";alert.informativeText=String(describing:error)
            alert.runModal();NSApp.terminate(nil)
        }
    }
    @objc private func walk(){pet?.startWalk(towardDock:true)}
    @objc private func groom(){pet?.groomNow()}
    @objc private func sleepCat(){pet?.sleepNow()}
    @objc private func quit(){NSApp.terminate(nil)}
    @objc private func changeSize(_ sender:NSSlider) {pet?.resize(sender.doubleValue);updateSize()}
    @objc private func resetSize(){pet?.resize(1);updateSize()}
    private func updateSize(){
        guard let pet else{return};slider?.doubleValue=pet.scale
        percent?.stringValue="\(Int((pet.scale*100).rounded()))%"
    }
    @objc private func showSettings() {
        if settings==nil {
            let p=NSPanel(contentRect:NSRect(x:0,y:0,width:328,height:146),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            p.title="Alongside · 达达";p.isReleasedWhenClosed=false;p.hidesOnDeactivate=false
            let label=NSTextField(labelWithString:"显示大小")
            label.font = .systemFont(ofSize:14,weight:.medium);label.frame=NSRect(x:22,y:96,width:160,height:24)
            let value=NSTextField(labelWithString:"");value.alignment = .right
            value.font = .monospacedDigitSystemFont(ofSize:13,weight:.regular);value.frame=NSRect(x:235,y:97,width:68,height:22)
            let control=NSSlider(value:1,minValue:0.55,maxValue:2,target:self,action:#selector(changeSize(_:)))
            control.frame=NSRect(x:20,y:64,width:288,height:26);control.isContinuous=true
            control.setAccessibilityLabel("达达的显示大小")
            let reset=NSButton(title:"恢复默认",target:self,action:#selector(resetSize));reset.bezelStyle = .rounded
            reset.frame=NSRect(x:215,y:16,width:94,height:30)
            for v in [label,value,control,reset] as [NSView] {p.contentView?.addSubview(v)}
            p.center();settings=p;slider=control;percent=value
        }
        updateSize();NSApp.activate(ignoringOtherApps:true);settings?.makeKeyAndOrderFront(nil)
    }
}
