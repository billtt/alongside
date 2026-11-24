import AppKit
let checkMotion=CommandLine.arguments.contains("--check-motion")
if CommandLine.arguments.contains("--check-petting") || checkMotion {
    do {
        let root=Bundle.main.resourceURL!.appendingPathComponent("Pets/Dada")
        let art=try PetArt(root:root)
        if checkMotion {try verifyLocomotion(art)} else {try verifyPetting(art)}
        exit(0)
    } catch {fputs("离屏检查失败：\(error)\n",stderr);exit(1)}
}
let checkingDesktop=CommandLine.arguments.contains("--check")
let checkingAttention=CommandLine.arguments.contains("--check-attention")
let checkingInvitation=CommandLine.arguments.contains("--check-invitation")
if checkingDesktop || checkingAttention || checkingInvitation {
    var displays:UInt32=0
    guard CGGetOnlineDisplayList(0,nil,&displays) == .success,displays>0 else {
        fputs("桌面检查需要可访问的显示器和 Dock。\n",stderr)
        exit(1)
    }
}
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
if checkingAttention || checkingInvitation {
    do {
        guard let screen = NSScreen.main, let root = Bundle.main.resourceURL else { throw ArtError.invalid("需要桌面会话") }
        let art = try PetArt(root: root.appendingPathComponent("Pets/Dada"))
        if checkingInvitation { try verifyInvitation(art, screen: screen) }
        else { try verifyAttention(art, screen: screen) }
        exit(0)
    } catch { fputs("互动检查失败：\(error)\n", stderr); exit(1) }
}
if checkingDesktop {
    do {try verifyApp();exit(0)} catch {fputs("检查失败：\(error)\n",stderr);exit(1)}
}
let delegate=AppDelegate()
app.delegate=delegate
app.run()
