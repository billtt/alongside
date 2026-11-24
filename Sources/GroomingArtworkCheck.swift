import AppKit

// Sample the opaque outline of the actual level-view drawing in body units.
// A moving tongue cannot change the upper outline over the ears and crown.
func verifyGroomingArtwork(_ art: PetArt) throws {
    guard let recoveries = art.clips["groomingRecovery"] else { return }
    let keys: [(String, GroomingBout.Key)] = [
        ("lick", .lick), ("chest", .chest), ("flank", .flank), ("toes", .toes)
    ]
    func contour(_ cel: Cel, over band: ClosedRange<CGFloat>, top: Bool) throws -> [CGFloat] {
        let image = cel.groundedImage, ink = NSBitmapImageRep(cgImage: image)
        return try (0..<41).map { index in
            let u = band.lowerBound + (band.upperBound - band.lowerBound) * CGFloat(index) / 40
            let column = Int((cel.anchorX + u / cel.scale).rounded())
            guard (0..<image.width).contains(column) else { throw ArtError.invalid("理毛轮廓采样超出绘稿") }
            for offset in 0..<image.height {
                let row = top ? offset : image.height - 1 - offset
                if (ink.colorAt(x: column, y: row)?.alphaComponent ?? 0) >= 0.72 {
                    return (CGFloat(image.height - row) - cel.supportOffset) * cel.scale
                }
            }
            throw ArtError.invalid("理毛绘稿缺少承重或头顶轮廓")
        }
    }
    func difference(_ a: [CGFloat], _ b: [CGFloat]) -> CGFloat {
        zip(a, b).reduce(CGFloat.zero) { $0 + abs($1.0 - $1.1) } / CGFloat(a.count)
    }
    for (i, item) in keys.enumerated() {
        let (name, key) = item
        guard let between = art.clips["wash-" + name + "-recover"], between.count >= 2,
              recoveries.indices.contains(i) else { throw ArtError.invalid("缺少舔舐中间绘稿 " + name) }
        let contact = art.cel("grooming", key.rawValue - 1)
        let stroke = [contact] + between + [recoveries[i]]
        let skull = try contour(contact, over: -0.42 ... -0.08, top: true)
        let withdrawn = try contour(recoveries[i], over: -0.42 ... -0.08, top: true)
        guard difference(skull, withdrawn) > 0.015 else { throw ArtError.invalid("舔舐时头颈活动太小 " + name) }
        for band: ClosedRange<CGFloat> in [-0.46 ... -0.34, 0.17 ... 0.32] {
            let resting = try contour(contact, over: band, top: false)
            for frame in stroke.dropFirst() {
                let bearing = try contour(frame, over: band, top: false)
                guard difference(resting, bearing) < 0.013 else { throw ArtError.invalid("舔舐时支撑爪或后胯漂移 " + name) }
            }
        }
    }
}
