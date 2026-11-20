import AppKit

// Compile with Sources/*.swift except main.swift. Uses the production projection,
// scale, anchors and sequence; no optical-flow interpolation or cross-fades.
@main struct GroomingReview {
    struct Random: RandomNumberGenerator {
        var state: UInt64 = 17
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }
    static func main() throws {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let art = try PetArt(root: root), motions = MotionLibrary(art)
        let descriptor = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("pet.json"))) as! [String: Any]
        let specs = descriptor["clips"] as! [String: [[String: Any]]]
        var names: [ObjectIdentifier: String] = [:]
        var cels: [String: Cel] = [:]
        for (key, frames) in art.clips {
            for (i, cel) in frames.enumerated() {
                let name = URL(fileURLWithPath: specs[key]![i]["file"] as! String).deletingPathExtension().lastPathComponent
                names[ObjectIdentifier(cel)] = name
                if key.hasPrefix("wash-") || key.hasPrefix("grooming") || (key == "settle" && i == 8) { cels[name] = cel }
            }
        }
        func save(_ cel: Cel, name: String) throws {
            let w = 480, h = 380
            let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            cg.setFillColor(CGColor(red: 0.93, green: 0.91, blue: 0.86, alpha: 1))
            cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let feet = CGPoint(x: 265, y: 36)
            cg.setStrokeColor(CGColor(red: 0.7, green: 0.4, blue: 0.2, alpha: 1)); cg.setLineWidth(1)
            cg.move(to: CGPoint(x: 0,y: feet.y)); cg.addLine(to: CGPoint(x: CGFloat(w),y: feet.y)); cg.strokePath()
            let drawing = SpriteDrawing(cel: cel, grounded: true, mirror: false, feet: feet,
                                        k: 356*cel.scale, stretch: 1, backing: 1)
            cg.translateBy(x: drawing.frame.minX, y: drawing.frame.minY)
            cg.concatenate(drawing.transform); cg.interpolationQuality = .high
            cg.draw(drawing.image, in: CGRect(x: 0,y: 0,width: drawing.image.width,height: drawing.image.height))
            let image = NSBitmapImageRep(cgImage: cg.makeImage()!)
            try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name+".png"))
        }
        for (name, cel) in cels { try save(cel, name: name) }
        if art.clips["groomingRecovery"] != nil {
            var random = Random()
            let sequence = GroomingBout(art: art, motions: motions, using: &random).sequence
            var frames: [[String: Any]] = []
            for time in stride(from: 0.0, through: sequence.duration, by: 1/30) {
                let cel = sequence.frame(at: time).0
                frames.append(["time": time, "file": names[ObjectIdentifier(cel)]!+".png"])
            }
            frames.append(["time": sequence.duration, "file": "settle-8.png"])
            try JSONSerialization.data(withJSONObject: frames, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("timeline.json"))
            print("Rendered \(cels.count) cels, \(frames.count) samples, \(sequence.duration) seconds")
        }
    }
}
