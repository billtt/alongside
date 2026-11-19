import CoreGraphics
import Foundation
import ImageIO

private struct RigFile: Decodable {
  struct Bone: Decodable {
    let name: String
    let parent: Int
  }
  struct Piece: Decodable {
    let bone: Int
    let origin, crop: [Int]
  }
  struct Skin: Decodable {
    let atlas: String
    let size: [Int]
    let bind: [[CGFloat]]
    let parts: [Piece]
  }
  struct Key: Decodable {
    let size: [Int]
    let skin: String
    let bones: [[CGFloat]]
    let mirrored: Bool
  }
  let bones: [Bone]
  let skins: [String: Skin]
  let poses: [String: Key]
}

private func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
private func angleDelta(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
  atan2(sin(b - a), cos(b - a))
}

// The local axes are the segment's length and thickness. Children inherit the
// joint frame. Their scales are independent so shortening a forearm in
// perspective need not flatten the toes or change the size of the head.
struct Joint {
  let x, y, angle, length, thickness: CGFloat

  init(_ x: CGFloat, _ y: CGFloat, _ angle: CGFloat, _ length: CGFloat, _ thickness: CGFloat) {
    self.x = x
    self.y = y
    self.angle = angle
    self.length = length
    self.thickness = thickness
  }
  init?(_ v: [CGFloat]) {
    guard v.count == 5, v.allSatisfy({ $0.isFinite }), v[3] > 0, v[4] > 0 else { return nil }
    self.init(v[0], v[1], v[2], v[3], v[4])
  }
  var matrix: CGAffineTransform {
    let c = cos(angle)
    let s = sin(angle)
    return .init(a: c * length, b: s * length, c: -s * thickness, d: c * thickness, tx: x, ty: y)
  }
  func relative(to parent: Joint) -> Joint {
    let p = CGPoint(x: x, y: y).applying(parent.matrix.inverted())
    return Joint(p.x, p.y, angleDelta(parent.angle, angle), length, thickness)
  }
  func placed(on parent: Joint) -> Joint {
    let p = CGPoint(x: x, y: y).applying(parent.matrix)
    return Joint(p.x, p.y, angle + parent.angle, length, thickness)
  }
  func toward(_ other: Joint, _ t: CGFloat) -> Joint {
    Joint(
      mix(x, other.x, t), mix(y, other.y, t), angle + angleDelta(angle, other.angle) * t,
      mix(length, other.length, t), mix(thickness, other.thickness, t))
  }
}

final class RigSkin {
  struct Attachment {
    let bone: Int
    let image: CGImage
    let toBone: CGAffineTransform
  }
  let size: CGSize
  let bindAngles: [CGFloat]
  private struct Region {
    let bone: Int
    let crop: CGRect
    let toBone: CGAffineTransform
  }
  private final class Textures {
    let pieces: [Attachment]
    init(_ value: [Attachment]) { pieces = value }
  }
  private static let textures: NSCache<NSObject, Textures> = {
    let cache = NSCache<NSObject, Textures>()
    cache.totalCostLimit = 32 * 1024 * 1024
    return cache
  }()
  private let regions: [Region]
  private let source: CGImageSource
  private let cacheKey = NSObject()
  var pieces: [Attachment] {
    if let saved = Self.textures.object(forKey: cacheKey) { return saved.pieces }
    // Crop from one decoded bitmap. Lazy crops of a PNG can each decompress
    // the entire atlas during a draw, particularly on the first pose of a turn.
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let bitmap = CGContext(
      data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let atlas = bitmap.makeImage()!
    let images = regions.map { region in
      Attachment(bone: region.bone, image: atlas.cropping(to: region.crop)!, toBone: region.toBone)
    }
    Self.textures.setObject(
      Textures(images), forKey: cacheKey, cost: atlas.width * atlas.height * 4)
    return images
  }
  fileprivate init(_ spec: RigFile.Skin, root: URL, count: Int) throws {
    let bind = spec.bind.compactMap(Joint.init)
    guard bind.count == count, !spec.parts.isEmpty,
      let source = CGImageSourceCreateWithURL(
        root.appendingPathComponent(spec.atlas) as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary),
      let atlas = CGImageSourceCreateImageAtIndex(
        source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { throw ArtError.invalid(spec.atlas) }
    guard spec.size.count == 2, spec.size.allSatisfy({ $0 > 0 }) else {
      throw ArtError.invalid(spec.atlas)
    }
    size = CGSize(width: spec.size[0], height: spec.size[1])
    bindAngles = bind.map(\.angle)
    self.source = source
    regions = try spec.parts.map { part in
      let r = part.crop
      let p = part.origin
      guard bind.indices.contains(part.bone), r.count == 4, p.count == 2, r[2] > 0, r[3] > 0,
        r[0] >= 0, r[1] >= 0, r[0] + r[2] <= atlas.width, r[1] + r[3] <= atlas.height
      else { throw ArtError.invalid("无效的骨骼附件 " + spec.atlas) }
      // Quartz images have their origin at the bottom left. Bind drawing
      // coordinates use the top-left convention of the original paintings.
      let m = CGAffineTransform(
        a: 1, b: 0, c: 0, d: -1, tx: CGFloat(p[0]), ty: CGFloat(p[1] + r[3]))
      return Region(
        bone: part.bone, crop: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]),
        toBone: m.concatenating(bind[part.bone].matrix.inverted()))
    }
  }
}

struct SkeletalPose {
  let names: [String]
  let parents: [Int]
  let skin: RigSkin
  var joints: [Joint]
  var reversed: Bool
  let size: CGSize
  let scale: CGFloat
  var anchor, grip: CGFloat

  var registration: ProjectionAtlas? = nil
  var key = ""
  var reflected = false
  var projection: ProjectionSample? = nil

  func facingOpposite() -> Self {
    var copy = self
    copy.reversed.toggle()
    copy.reflected.toggle()
    return copy
  }

  var world: [Joint] {
    var out = [Joint]()
    out.reserveCapacity(joints.count)
    for (i, local) in joints.enumerated() {
      let parent = parents[i]
      out.append(parent < 0 ? local : local.placed(on: out[parent]))
    }
    return out
  }

  func withJoints(_ value: [Joint]) -> SkeletalPose {
    var copy = self
    copy.joints = value
    return copy
  }

  func reanchored(at visibleX: CGFloat, grip height: CGFloat) -> Self {
    var copy = self
    copy.anchor = reversed ? size.width - visibleX : visibleX
    copy.grip = height
    let root = joints[0]
    copy.joints[0] = Joint(
      root.x + (anchor - copy.anchor) * scale, root.y, root.angle, root.length, root.thickness)
    return copy
  }

  func toward(_ b: SkeletalPose, _ t: CGFloat) -> SkeletalPose {
    let k = mix(scale, b.scale, t)
    func pixels(_ a: CGFloat, _ end: CGFloat) -> CGFloat { mix(a * scale, end * b.scale, t) / k }
    let canvas = CGSize(
      width: pixels(size.width, b.size.width).rounded(),
      height: pixels(size.height, b.size.height).rounded())
    let simple =
      skin === b.skin && reversed == b.reversed && projection == nil && b.projection == nil
    let local = simple ? zip(joints, b.joints).map { $0.toward($1, t) } : joints
    let displayedAnchor = pixels(
      reversed ? size.width - anchor : anchor,
      b.reversed ? b.size.width - b.anchor : b.anchor)
    var result = SkeletalPose(
      names: names, parents: parents, skin: skin, joints: local, reversed: reversed,
      size: canvas, scale: k, anchor: reversed ? canvas.width - displayedAnchor : displayedAnchor,
      grip: pixels(grip, b.grip))
    result.registration = registration
    result.reflected = reflected
    return result
  }

  func paint(in ctx: CGContext) {
    if let projection {
      projection.draw(in: ctx, size: size)
      return
    }
    let bones = world
    ctx.saveGState()
    ctx.translateBy(x: reversed ? size.width - anchor : anchor, y: 0)
    ctx.scaleBy(x: (reversed ? -1 : 1) / scale, y: -1 / scale)
    ctx.interpolationQuality = .high
    // A changing projection can scale the two canvas axes differently.
    // Keep the transformed normal of each bone so adjacent pieces share
    // exactly the same projection at their seam.
    let ax = size.width / skin.size.width
    let ay = size.height / skin.size.height
    let transforms = bones.enumerated().map { i, bone -> CGAffineTransform in
      let angle = skin.bindAngles[i]
      let c = cos(angle)
      let s = sin(angle)
      let denom = hypot(ax * c, ay * s) * hypot(ax * s, ay * c)
      let skew = c * s * (ay * ay - ax * ax) / denom
      let normal = ax * ay / denom
      var m = bone.matrix
      m.c = bone.thickness * (cos(bone.angle) * skew - sin(bone.angle) * normal)
      m.d = bone.thickness * (sin(bone.angle) * skew + cos(bone.angle) * normal)
      // The skull and toes stay rigid. Remove shear from the combined joint
      // and crop transforms while retaining their projected area and position.
      if names[i] == "head" || names[i].lowercased().hasSuffix("paw") {
        let a = m.a
        let b = m.b
        let c = m.c
        let d = m.d
        let angle = atan2(b - c, a + d)
        let length = sqrt(abs(a * d - b * c))
        m.a = cos(angle) * length
        m.b = sin(angle) * length
        m.c = -sin(angle) * length
        m.d = cos(angle) * length
      }
      return m
    }
    for attachment in skin.pieces {
      ctx.saveGState()
      ctx.concatenate(attachment.toBone.concatenating(transforms[attachment.bone]))
      let im = attachment.image
      ctx.draw(im, in: CGRect(x: 0, y: 0, width: im.width, height: im.height))
      ctx.restoreGState()
    }
    ctx.restoreGState()
  }
}

final class Skeleton {
  private let registration: ProjectionAtlas?
  private let names: [String]
  private let spec: RigFile
  private let parents: [Int]
  private let skins: [String: RigSkin]
  init(root: URL, calibrating: Bool = false) throws {
    let data = try JSONDecoder().decode(
      RigFile.self, from: Data(contentsOf: root.appendingPathComponent("rig.json")))
    let tree = data.bones.map(\.parent)
    guard !tree.isEmpty, tree[0] == -1,
      tree.indices.dropFirst().allSatisfy({ tree[$0] >= 0 && tree[$0] < $0 })
    else { throw ArtError.invalid("骨骼父子关系") }
    registration = calibrating ? nil : try ProjectionAtlas(root: root)
    names = data.bones.map(\.name)
    parents = tree
    spec = data
    skins = try data.skins.mapValues { try RigSkin($0, root: root, count: tree.count) }
  }
  func pose(_ name: String, scale: CGFloat, anchor: CGFloat, gripFromTop: CGFloat?) throws
    -> SkeletalPose
  {
    guard let key = spec.poses[name], let skin = skins[key.skin], key.size.count == 2,
      key.size.allSatisfy({ (1...4096).contains($0) }), scale > 0
    else { throw ArtError.invalid(name) }
    let w = CGFloat(key.size[0])
    let h = CGFloat(key.size[1])
    let world = key.bones.compactMap(Joint.init).map {
      Joint(
        ($0.x - (key.mirrored ? w - anchor : anchor)) * scale, ($0.y - h) * scale, $0.angle,
        $0.length * scale, $0.thickness * scale)
    }
    guard world.count == parents.count else { throw ArtError.invalid(name) }
    let local = world.indices.map {
      parents[$0] < 0 ? world[$0] : world[$0].relative(to: world[parents[$0]])
    }
    var pose = SkeletalPose(
      names: names, parents: parents, skin: skin, joints: local, reversed: key.mirrored,
      size: CGSize(width: w, height: h), scale: scale, anchor: key.mirrored ? w - anchor : anchor,
      grip: h - (gripFromTop ?? h * 0.04))
    pose.registration = registration
    pose.key = name
    return pose
  }
}
