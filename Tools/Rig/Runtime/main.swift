import AppKit
if CommandLine.arguments.contains("--check-rig") {
    do {try verifyRig();exit(0)} catch {fputs("骨骼检查失败：\(error)\n",stderr);exit(1)}
}
let checkingDesktop=CommandLine.arguments.contains("--check")
if checkingDesktop {
    var displays:UInt32=0
    guard CGGetOnlineDisplayList(0,nil,&displays) == .success,displays>0 else {
        fputs("桌面检查需要可访问的显示器和 Dock。离屏骨骼检查可使用 --check-rig。\n",stderr)
        exit(1)
    }
}
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
if checkingDesktop {
    do {try verifyApp();exit(0)} catch {fputs("检查失败：\(error)\n",stderr);exit(1)}
}
let delegate=AppDelegate()
app.delegate=delegate
app.run()
