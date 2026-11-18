import AppKit
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
if CommandLine.arguments.contains("--check") {
    do {try verifyApp();exit(0)} catch {fputs("检查失败：\(error)\n",stderr);exit(1)}
}
let delegate=AppDelegate()
app.delegate=delegate
app.run()
