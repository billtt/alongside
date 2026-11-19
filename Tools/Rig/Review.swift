// Render native skeletal output offscreen for comparison with the source paintings.
// swiftc -O Tools/Rig/Runtime/{Artwork,Skeleton,Projection,Pet,Reaction,DockMotion}.swift Sources/{Dock,Terrain}.swift Tools/Rig/Review.swift -o /tmp/alongside-review
import AppKit
import ImageIO
import UniformTypeIdentifiers

@main struct RigReview {
  static func main() throws {
    let keysOnly = CommandLine.arguments.count == 4 && CommandLine.arguments[3] == "--keys"
    guard CommandLine.arguments.count == 3 || keysOnly else {
      throw ArtError.invalid("Review <pet directory> <output directory>")
    }
    let source = URL(fileURLWithPath: CommandLine.arguments[1])
    let out = URL(fileURLWithPath: CommandLine.arguments[2])
    if CommandLine.arguments[2] == "--bake-dock" {
      let art = try PetArt(root: source, measuringDescent: true)
      let data = try JSONEncoder().encode(DockMotion.measureDescent(art))
      try data.write(to: source.appendingPathComponent("Rig/descent.json"), options: .atomic)
      return
    }
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let art = try PetArt(root: source, measuringDescent: keysOnly, calibratingViews: keysOnly)
    func save(_ cel: Cel, _ name: String) throws {
      let url = out.appendingPathComponent(name + ".png")
      guard
        let dest = CGImageDestinationCreateWithURL(
          url as CFURL, UTType.png.identifier as CFString, 1, nil)
      else { throw ArtError.invalid(name) }
      CGImageDestinationAddImage(dest, cel.image, nil)
      guard CGImageDestinationFinalize(dest) else { throw ArtError.invalid(name) }
    }
    if keysOnly {
      for (key, clip) in art.clips {
        for (i, cel) in clip.enumerated() { try save(cel, "\(key)-\(i)") }
      }
      return
    }
    let walk = art.clips["walk"]!
    let library = MotionLibrary(art)
    var timeline = [[String: Any]]()
    func record(
      _ segment: String, _ elapsed: Double, _ old: MotionFrame, _ new: MotionFrame,
      _ lift: CGFloat = 0, grounded: Bool = true
    ) throws {
      let n = String(format: "sample-%04d", timeline.count)
      try save(new.cel, n)
      var file: String?
      for (key, clip) in art.clips {
        if let i = clip.firstIndex(where: { $0 === old.cel }) {
          file = "\(key)-\(i)"
          break
        }
      }
      timeline.append([
        "oldMirror": old.mirrored, "newMirror": new.mirrored, "sample": n, "segment": segment,
        "time": elapsed, "lift": lift, "old": file!,
        "scale": new.cel.scale, "anchor": new.cel.anchorX, "grounded": grounded,
        "height": grounded ? new.cel.groundedImage.height : new.cel.image.height,
      ])
    }
    for i in 0..<35 {
      let t = Double(i) / 30
      let phase = t / 0.19
      let index = Int(phase) % walk.count
      let a = MotionFrame(walk[index])
      try record("walk", t, a, MotionFrame(art.walking(at: t)))
    }
    for (name, start, peak, action, hold) in [
      ("reach", art.cel("settle", 8), art.cel("pawRest", 0), Pose.paw, 0.2),
      ("high", art.cel("settle", 0), art.cel("pawAim", 2), Pose.paw, 0.2),
      ("turn", art.cel("turn", 5), art.cel("back", 2), Pose.backLook, 1.7),
    ] {
      let a = MotionFrame(start)
      let b = MotionFrame(peak)
      let r = Reaction(
        library: library, from: a, toward: b, returningTo: a, action: action, hold: hold)
      for i in 0...Int(ceil(r.duration * 30)) {
        let t = Double(i) / 30
        try record(name, t, MotionFrame(r.frame(at: t)), r.sample(at: t))
      }
    }
    let home = MotionFrame(art.cel("settle", 0))
    let reverse = Reaction(path: library.path(from: home, to: MotionFrame(home.cel, true)))
    for i in 0...Int(ceil(reverse.duration * 30)) {
      let t = Double(i) / 30
      try record("mirror", t, MotionFrame(reverse.frame(at: t)), reverse.sample(at: t))
    }
    let initial = Reaction(
      library: library, from: home, toward: MotionFrame(art.cel("pawAim", 2)),
      returningTo: home, action: .paw)
    let cut = 0.33
    var redirected = Reaction(
      path: library.path(
        from: MotionFrame(initial.frame(at: cut)), to: MotionFrame(art.cel("settle", 8))))
    redirected.initialDisplay = initial.sample(at: cut)
    for i in 0...Int(ceil((cut + redirected.duration) * 30)) {
      let t = Double(i) / 30
      if t < cut {
        try record("interrupt", t, MotionFrame(initial.frame(at: t)), initial.sample(at: t))
      } else {
        try record(
          "interrupt", t, MotionFrame(redirected.frame(at: t - cut)), redirected.sample(at: t - cut)
        )
      }
    }
    let standing = Reaction(
      path: library.path(
        from: MotionFrame(art.cel("settle", 8)), to: MotionFrame(art.cel("turn", 5))))
    for i in 0...Int(ceil(standing.duration * 30)) {
      let t = Double(i) / 30
      try record("turnBody", t, MotionFrame(standing.frame(at: t)), standing.sample(at: t))
    }
    for down in [false, true] {
      let hop = Hop(
        startX: down ? 140 : -140, endX: down ? -140 : 140, startY: down ? 46 : 0,
        endY: down ? 0 : 46, clearance: 23)
      let motion = DockMotion(hop: hop, edge: 0, unit: 175, art: art)
      for i in 0...Int(ceil(motion.duration * 30)) {
        let time = Double(i) / 30
        let fraction = min(1, time / motion.duration)
        try record(
          down ? "descend" : "jump", time, MotionFrame(motion.frame(fraction)),
          MotionFrame(motion.sample(fraction)), motion.position(fraction).y / 175,
          grounded: down || motion.position(fraction).y == 0)
      }
    }
    try JSONSerialization.data(withJSONObject: timeline).write(
      to: out.appendingPathComponent("samples.json"))
    for (key, clip) in art.clips {
      for (i, cel) in clip.enumerated() {
        try save(cel, "\(key)-\(i)")
        if i + 1 < clip.count { try save(cel.toward(clip[i + 1], 0.5), "\(key)-\(i)-mid") }
      }
    }
  }
}
